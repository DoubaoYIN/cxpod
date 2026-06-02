import Foundation

struct BalanceInfo {
    let provider: String
    let remaining: Double
    let total: Double
    let used: Double
    let planName: String
}

enum GatewayType: String, Codable {
    case sub2api
    case newapi
    case zenmux
    case unknown
}

final class BalanceService {
    static let shared = BalanceService()

    private static let minimumFetchInterval: TimeInterval = 60
    private static let shortFailureCooldown: TimeInterval = 60 * 60
    private static let longFailureCooldown: TimeInterval = 6 * 60 * 60

    var onUpdate: ((String, BalanceInfo) -> Void)?

    private let session = URLSession(configuration: {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 5
        return c
    }())

    private let stateQueue = DispatchQueue(label: "cxpod.balance-service.state")
    private var detectedTypes: [String: GatewayType] = [:]
    private var probing: Set<String> = []
    private var cache: [String: BalanceInfo] = [:]
    private var lastFetchedAt: [String: Date] = [:]
    private var cooldownUntil: [String: Date] = [:]

    func fetchBalance(provider: String, force: Bool = false, completion: @escaping (BalanceInfo?) -> Void) {
        guard let config = readProviderConfig(provider),
              !config.apiKey.isEmpty else {
            completion(cached(provider)); return
        }
        if !force, let cached = cached(provider) {
            completion(cached)
            return
        }
        if !beginFetch(provider: provider, respectCooldown: false) {
            completion(cached(provider))
            return
        }

        let deliver: (BalanceInfo?) -> Void = { [weak self] info in
            if let info {
                self?.store(info)
            }
            completion(info)
        }
        if let cached = cachedType(for: provider), cached != .unknown {
            fetchWith(type: cached, provider: provider, config: config, completion: deliver)
            return
        }
        probe(provider: provider, config: config, completion: deliver)
    }

    func cached(_ provider: String) -> BalanceInfo? {
        stateQueue.sync { cache[provider] }
    }

    func refreshKnown(providers: [String]) {
        for provider in Array(Set(providers)).sorted() {
            refreshKnown(provider: provider) { _ in }
        }
    }

    func refreshKnown(provider: String, completion: @escaping (BalanceInfo?) -> Void) {
        guard let config = readProviderConfig(provider),
              !config.apiKey.isEmpty else {
            completion(cached(provider)); return
        }
        guard let type = cachedType(for: provider), type != .unknown else {
            completion(cached(provider)); return
        }
        guard beginFetch(provider: provider, respectCooldown: true) else {
            completion(cached(provider)); return
        }
        fetchWith(type: type, provider: provider, config: config) { [weak self] info in
            if let self, let info {
                self.store(info)
            } else {
                self?.registerFailure(provider: provider, statusCode: nil, body: "")
            }
            completion(info)
        }
    }

    private func probe(provider: String, config: ProviderConfig, completion: @escaping (BalanceInfo?) -> Void) {
        guard beginProbing(provider: provider) else { completion(nil); return }
        let group = DispatchGroup()
        var results: [(GatewayType, Bool)] = []
        let lock = NSLock()
        let checks: [(GatewayType, String)] = [
            (.sub2api, "/v1/usage"),
            (.newapi, "/v1/dashboard/billing/subscription"),
            (.zenmux, "/api/v1/management/subscription/detail"),
        ]
        for (type, path) in checks {
            group.enter()
            let url = config.baseURL.appendingPathComponent(path)
            var req = URLRequest(url: url)
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            session.dataTask(with: req) { _, resp, _ in
                defer { group.leave() }
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
                lock.lock(); results.append((type, true)); lock.unlock()
            }.resume()
        }
        group.notify(queue: .global()) { [weak self] in
            guard let self else { completion(nil); return }
            let detected = results.first?.0 ?? .unknown
            self.finishProbing(provider: provider, detected: detected)
            self.saveDetectedType(provider: provider, type: detected)
            if detected != .unknown {
                self.fetchWith(type: detected, provider: provider, config: config, completion: completion)
            } else {
                completion(nil)
            }
        }
    }

    private func fetchWith(type: GatewayType, provider: String, config: ProviderConfig, completion: @escaping (BalanceInfo?) -> Void) {
        switch type {
        case .sub2api:
            fetchSub2api(provider: provider, baseURL: config.baseURL, key: config.apiKey, completion: completion)
        case .newapi:
            fetchNewapi(provider: provider, baseURL: config.baseURL, key: config.apiKey, completion: completion)
        case .zenmux:
            fetchZenmux(provider: provider, baseURL: config.baseURL, key: config.apiKey, completion: completion)
        case .unknown:
            completion(nil)
        }
    }

    private func fetchSub2api(provider: String, baseURL: URL, key: String, completion: @escaping (BalanceInfo?) -> Void) {
        let url = baseURL.appendingPathComponent("/v1/usage")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: req) { data, resp, _ in
            let http = resp as? HTTPURLResponse
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard let data, let http, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.registerFailure(provider: provider, statusCode: http?.statusCode, body: body)
                completion(nil); return
            }
            let remaining = json["remaining"] as? Double ?? 0
            let planName = json["planName"] as? String ?? ""
            var total = remaining; var used = 0.0
            if let bal = json["balance"] as? Double, bal > 0 { total = bal; used = bal - remaining }
            completion(BalanceInfo(provider: provider, remaining: remaining, total: total, used: used, planName: planName))
        }.resume()
    }

    private func fetchNewapi(provider: String, baseURL: URL, key: String, completion: @escaping (BalanceInfo?) -> Void) {
        let subURL = baseURL.appendingPathComponent("/v1/dashboard/billing/subscription")
        var subReq = URLRequest(url: subURL)
        subReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: subReq) { [weak self] data, resp, _ in
            let http = resp as? HTTPURLResponse
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard let self, let data, let http, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self?.registerFailure(provider: provider, statusCode: http?.statusCode, body: body)
                completion(nil); return
            }
            let hardLimit = json["hard_limit_usd"] as? Double ?? 0
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.timeZone = TimeZone(identifier: "UTC")
            let today = fmt.string(from: Date())
            let start = fmt.string(from: Date(timeIntervalSinceNow: -90 * 86400))
            let usageURL = baseURL.appendingPathComponent("/v1/dashboard/billing/usage")
            var comps = URLComponents(url: usageURL, resolvingAgainstBaseURL: false)!
            comps.queryItems = [.init(name: "start_date", value: start), .init(name: "end_date", value: today)]
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            self.session.dataTask(with: req) { data, resp, _ in
                let http = resp as? HTTPURLResponse
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard let data, let http, http.statusCode == 200,
                      let uj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.registerFailure(provider: provider, statusCode: http?.statusCode, body: body)
                    completion(nil); return
                }
                let used = (uj["total_usage"] as? Double ?? 0) / 100.0
                completion(BalanceInfo(provider: provider, remaining: hardLimit - used, total: hardLimit, used: used, planName: ""))
            }.resume()
        }.resume()
    }

    private func fetchZenmux(provider: String, baseURL: URL, key: String, completion: @escaping (BalanceInfo?) -> Void) {
        let url = baseURL.appendingPathComponent("/api/v1/management/subscription/detail")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: req) { data, resp, _ in
            let http = resp as? HTTPURLResponse
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard let data, let http, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.registerFailure(provider: provider, statusCode: http?.statusCode, body: body)
                completion(nil); return
            }
            var remaining = 0.0; var total = 0.0; var used = 0.0; var planName = ""
            if let plan = json["plan"] as? [String: Any] { planName = plan["tier"] as? String ?? ""; total = plan["monthly_usd"] as? Double ?? 0 }
            if let monthly = json["quota_monthly"] as? [String: Any] {
                used = monthly["used_usd"] as? Double ?? 0
                let limit = monthly["limit_usd"] as? Double ?? total
                remaining = limit - used; if limit > 0 { total = limit }
            }
            completion(BalanceInfo(provider: provider, remaining: remaining, total: total, used: used, planName: planName))
        }.resume()
    }

    private func readProviderConfig(_ name: String) -> ProviderConfig? {
        guard isValidProviderName(name) else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = [
            home.appendingPathComponent(".cxpod/providers", isDirectory: true),
            home.appendingPathComponent("Projects/cxpod/providers", isDirectory: true),
        ]
        for dir in dirs {
            let file = dir.appendingPathComponent("\(name).json")
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let mp = json["model_provider_toml"] as? [String: Any] ?? [:]
            guard let urlStr = mp["base_url"] as? String, !urlStr.isEmpty,
                  let url = URL(string: urlStr) else { continue }
            var apiKey = ""
            if let envKey = mp["env_key"] as? String, !envKey.isEmpty {
                let envFile = home.appendingPathComponent(".cxpod/env")
                apiKey = readEnvValue(file: envFile, key: envKey) ?? ""
            }
            if apiKey.isEmpty, let ak = mp["api_key"] as? String { apiKey = ak }
            if let gw = json["gateway"] as? String, let type = GatewayType(rawValue: gw) {
                setCachedType(type, for: name)
            }
            return ProviderConfig(baseURL: url, apiKey: apiKey)
        }
        return nil
    }

    private func readEnvValue(file: URL, key: String) -> String? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let k = parts[0].trimmingCharacters(in: .whitespaces)
            var v = parts[1].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            if v.hasPrefix("'") && v.hasSuffix("'") { v = String(v.dropFirst().dropLast()) }
            if k == key { return v }
        }
        return nil
    }

    private func cachedType(for provider: String) -> GatewayType? {
        stateQueue.sync { detectedTypes[provider] }
    }
    private func setCachedType(_ type: GatewayType, for provider: String) {
        stateQueue.sync { detectedTypes[provider] = type }
    }

    private func saveDetectedType(provider: String, type: GatewayType) {
        guard type != .unknown, isValidProviderName(provider) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let file = home
            .appendingPathComponent(".cxpod/providers", isDirectory: true)
            .appendingPathComponent("\(provider).json")
        guard let data = try? Data(contentsOf: file),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json["gateway"] = type.rawValue
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private func beginProbing(provider: String) -> Bool {
        stateQueue.sync { guard !probing.contains(provider) else { return false }; probing.insert(provider); return true }
    }
    private func finishProbing(provider: String, detected: GatewayType) {
        stateQueue.sync { probing.remove(provider); detectedTypes[provider] = detected }
    }

    private func beginFetch(provider: String, respectCooldown: Bool) -> Bool {
        stateQueue.sync {
            if let last = lastFetchedAt[provider],
               Date().timeIntervalSince(last) < Self.minimumFetchInterval {
                return false
            }
            if respectCooldown,
               let until = cooldownUntil[provider],
               until > Date() {
                return false
            }
            lastFetchedAt[provider] = Date()
            return true
        }
    }

    private func store(_ info: BalanceInfo) {
        stateQueue.sync {
            cache[info.provider] = info
            if info.remaining <= 0 {
                cooldownUntil[info.provider] = Date().addingTimeInterval(Self.longFailureCooldown)
            } else {
                cooldownUntil[info.provider] = nil
            }
        }
        onUpdate?(info.provider, info)
    }

    private func registerFailure(provider: String, statusCode: Int?, body: String) {
        let cooldown = failureCooldown(statusCode: statusCode, body: body)
        stateQueue.sync {
            cooldownUntil[provider] = Date().addingTimeInterval(cooldown)
        }
    }

    private func failureCooldown(statusCode: Int?, body: String) -> TimeInterval {
        let lower = body.lowercased()
        if lower.contains("insufficient_balance") ||
            lower.contains("余额不足") ||
            lower.contains("quota") ||
            lower.contains("rate_limit") ||
            lower.contains("rate limit") {
            return Self.longFailureCooldown
        }
        switch statusCode {
        case 401?, 403?, 429?:
            return Self.longFailureCooldown
        default:
            return Self.shortFailureCooldown
        }
    }

    struct ProviderConfig {
        let baseURL: URL
        let apiKey: String
    }
}

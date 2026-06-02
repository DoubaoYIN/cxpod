import SwiftUI

final class PopoverViewModel: ObservableObject {
    @Published var providers: [String] = []
    @Published var projects: [ProjectInfo] = []
    @Published var terminals: [String] = []
    @Published var sessions: [SessionInfo] = []
    @Published var selectedProvider: String = ""
    @Published var selectedProject: String = ""
    @Published var selectedTerminal: String = ""
    @Published var balances: [String: BalanceInfo] = [:]
    @Published var codexAppProviders: [String] = []
    @Published var currentCodexAppProvider: String = ""
    @Published var selectedCodexAppProvider: String = ""

    var onLaunch: ((String, String, String) -> Void)?
    var onSwitch: ((SessionInfo, String) -> Void)?
    var onClose: ((SessionInfo) -> Void)?
    var onQuit: (() -> Void)?
    var onShowAddProvider: (() -> Void)?
    var onAddProject: (() -> Void)?
    var onCodexAppSwitch: ((String) -> Void)?
    var onShowCodexSessionOrganizer: (() -> Void)?

    func refresh(providerManager: ProviderManager, projectManager: ProjectManager, sessionManager: SessionManager, refreshRemote: Bool = false) {
        providers = providerManager.availableProviders()
        projects = projectManager.recentProjects()
        terminals = TerminalRegistry.shared.adapters.map { $0.name }
        sessions = sessionManager.sessions
        if selectedProvider.isEmpty || !providers.contains(selectedProvider) {
            selectedProvider = providerManager.currentProvider() ?? providers.first ?? ""
        }
        if selectedProject.isEmpty || !projects.contains(where: { $0.path == selectedProject }) {
            selectedProject = projects.first?.path ?? ""
        }
        if selectedTerminal.isEmpty || !terminals.contains(selectedTerminal) {
            selectedTerminal = terminals.first ?? ""
        }
        // Codex.app provider list = cxpod providers ∪ already-installed in
        // ~/.codex/config.toml ∪ current value (in case it's none of the above).
        let cxpodIds = providerManager.availableProviders()
        let installed = providerManager.installedCodexAppProviders()
        let current = providerManager.currentCodexAppProvider() ?? ""
        var seen = Set<String>(); var combined: [String] = []
        for id in cxpodIds + installed + [current] where !id.isEmpty {
            if !seen.contains(id) { seen.insert(id); combined.append(id) }
        }
        codexAppProviders = combined
        currentCodexAppProvider = current
        if selectedCodexAppProvider.isEmpty || !combined.contains(selectedCodexAppProvider) {
            selectedCodexAppProvider = current.isEmpty ? (combined.first ?? "") : current
        }
        loadCachedBalances()
        if refreshRemote {
            refreshBalances(force: true)
        }
    }

    func loadCachedBalances() {
        for provider in providers {
            if let cached = BalanceService.shared.cached(provider) {
                balances[provider] = cached
            }
        }
    }

    func refreshBalances(force: Bool = false) {
        for provider in providers {
            BalanceService.shared.fetchBalance(provider: provider, force: force) { [weak self] info in
                DispatchQueue.main.async { if let info { self?.balances[provider] = info } }
            }
        }
    }

    func refreshSelectedBalance() {
        guard !selectedProvider.isEmpty else { return }
        BalanceService.shared.fetchBalance(provider: selectedProvider, force: true) { [weak self] info in
            DispatchQueue.main.async {
                guard let self, let info else { return }
                self.balances[self.selectedProvider] = info
            }
        }
    }

}

struct PopoverContentView: View {
    @ObservedObject var vm: PopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            launcherSection
            codexAppSection
            if !vm.sessions.isEmpty { sessionsSection }
            quitSection
        }
        .padding(12)
        .frame(width: 360, alignment: .topLeading)
        .fixedSize()
    }

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var launcherSection: some View {
        sectionCard {
            Text("启动新会话").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            HStack {
                Text("线路").frame(width: 36, alignment: .trailing)
                Picker("", selection: $vm.selectedProvider) {
                    ForEach(vm.providers, id: \.self) { p in
                        if let bal = vm.balances[p] {
                            Text("\(p)  $\(String(format: "%.2f", bal.remaining))").tag(p)
                        } else { Text(p).tag(p) }
                    }
                }.labelsHidden()
                Button(action: { vm.refreshSelectedBalance() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("手动刷新当前线路额度")
                Button(action: { vm.onShowAddProvider?() }) { Image(systemName: "plus.circle") }
                    .buttonStyle(.plain).help("添加线路")
            }
            HStack {
                Text("项目").frame(width: 36, alignment: .trailing)
                Picker("", selection: $vm.selectedProject) {
                    ForEach(vm.projects, id: \.path) { proj in Text(proj.name).tag(proj.path) }
                }.labelsHidden()
                Button(action: { vm.onAddProject?() }) { Image(systemName: "plus.circle") }
                    .buttonStyle(.plain).help("添加项目")
            }
            HStack {
                Text("终端").frame(width: 36, alignment: .trailing)
                Picker("", selection: $vm.selectedTerminal) {
                    ForEach(vm.terminals, id: \.self) { t in Text(t).tag(t) }
                }.labelsHidden()
            }
            HStack {
                Spacer()
                Button("启动") { vm.onLaunch?(vm.selectedProvider, vm.selectedProject, vm.selectedTerminal) }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                Spacer()
            }.padding(.top, 2)
        }.font(.system(size: 13))
    }

    private var codexAppSection: some View {
        sectionCard {
            HStack {
                Text("Codex.app").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                Spacer()
                if !vm.currentCodexAppProvider.isEmpty {
                    Text("当前: \(vm.currentCodexAppProvider)")
                        .font(.system(size: 11)).foregroundColor(.secondary.opacity(0.8))
                }
            }
            HStack {
                Text("线路").frame(width: 36, alignment: .trailing)
                Picker("", selection: $vm.selectedCodexAppProvider) {
                    ForEach(vm.codexAppProviders, id: \.self) { p in Text(p).tag(p) }
                }.labelsHidden()
                Button(action: { vm.onShowAddProvider?() }) { Image(systemName: "plus.circle") }
                    .buttonStyle(.plain).help("添加线路")
            }
            HStack {
                Spacer()
                Button("整理会话") {
                    vm.onShowCodexSessionOrganizer?()
                }
                .controlSize(.regular)
                Button("切换并重启 Codex.app") {
                    let target = vm.selectedCodexAppProvider
                    if !target.isEmpty { vm.onCodexAppSwitch?(target) }
                }
                .buttonStyle(.borderedProminent).controlSize(.regular)
                .disabled(vm.selectedCodexAppProvider.isEmpty
                          || vm.selectedCodexAppProvider == vm.currentCodexAppProvider)
                Spacer()
            }.padding(.top, 2)
        }.font(.system(size: 13))
    }

    private var sessionsSection: some View {
        sectionCard {
            Text("正在运行").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary).padding(.bottom, 2)
            ForEach(vm.sessions, id: \.windowID) { session in
                HStack(spacing: 6) {
                    Circle().fill(providerColor(session.provider)).frame(width: 10, height: 10)
                    Text("#\(session.sessionNumber)").font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundColor(.secondary)
                    Text(session.projectName).font(.system(size: 13)).lineLimit(1)
                    Spacer()
                    Menu {
                        ForEach(vm.providers, id: \.self) { p in
                            Button("切换到 \(p)") { if p != session.provider { vm.onSwitch?(session, p) } }
                        }
                    } label: {
                        Text(session.provider).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06)).clipShape(Capsule())
                    }.menuStyle(.borderlessButton).fixedSize()
                    if let bal = vm.balances[session.provider] {
                        Text(String(format: "$%.0f", bal.remaining))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(bal.remaining < 5 ? .red : .secondary.opacity(0.6))
                    }
                    Button(action: { vm.onClose?(session) }) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary.opacity(0.6))
                    }.buttonStyle(.plain).help("关闭 #\(session.sessionNumber)")
                }.padding(.vertical, 2)
            }
        }
    }

    private var quitSection: some View {
        HStack {
            Spacer()
            Button(action: { vm.onQuit?() }) { Text("退出 CxPod").font(.system(size: 12)).foregroundColor(.secondary) }
                .buttonStyle(.plain)
            Spacer()
        }
    }

    private func providerColor(_ provider: String) -> Color {
        switch provider {
        case "official", "openai": return .green
        case "minimax": return .orange
        case "glm": return .purple
        case "volcengine": return .red
        case "aliyun": return .brown
        case "deepseek": return .cyan
        case "kimi": return .yellow
        default: return .gray
        }
    }
}

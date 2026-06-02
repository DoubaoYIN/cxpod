import SwiftUI

struct AddProviderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTemplate: ProviderTemplate?
    @State private var fieldValues: [String: String] = [:]
    @State private var customName: String = ""
    @State private var customBaseURL: String = ""
    @State private var customEnvKeyName: String = "RELAY_API_KEY"
    @State private var customDefaultModel: String = ""
    @State private var requiresOpenAIAuth: Bool = true
    @State private var apiKeyValue: String = ""
    @State private var envKeyEdited: Bool = false
    @State private var errorMessage: String?
    var onComplete: (() -> Void)?

    private let templates = ProviderTemplate.builtIn
    private let providersDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cxpod/providers", isDirectory: true)
    }()
    private let envFile: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cxpod/env")
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let tpl = selectedTemplate { formSection(tpl) }
            else { templateList }
        }
        .frame(width: 360, height: 440)
    }

    private var header: some View {
        HStack {
            if selectedTemplate != nil {
                Button(action: { selectedTemplate = nil; errorMessage = nil }) {
                    Image(systemName: "chevron.left")
                }.buttonStyle(.plain)
            }
            Text(selectedTemplate?.displayName ?? "添加线路")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }.buttonStyle(.plain)
        }.padding(12)
    }

    private var templateList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(ProviderTemplate.Category.allCases, id: \.rawValue) { cat in
                    let items = templates.filter { $0.category == cat }
                    if !items.isEmpty {
                        Text(cat.rawValue).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary).padding(.top, 4)
                        ForEach(items, id: \.id) { tpl in
                            Button(action: {
                                selectedTemplate = tpl
                                let initialName = tpl.id == "relay" ? "" : tpl.id
                                customName = initialName
                                customBaseURL = tpl.baseURL
                                customDefaultModel = tpl.defaultModel
                                customEnvKeyName = tpl.envKeyName.isEmpty ? defaultEnvKeyName(for: initialName) : tpl.envKeyName
                                requiresOpenAIAuth = tpl.requiresOpenAIAuth
                                apiKeyValue = ""
                                envKeyEdited = false
                                errorMessage = nil
                            }) {
                                HStack {
                                    Text(tpl.badgeEmoji)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tpl.displayName).font(.system(size: 13))
                                        Text(tpl.notes).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundColor(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(12)
        }
    }

    private func formSection(_ tpl: ProviderTemplate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("名称").frame(width: 50, alignment: .trailing).font(.system(size: 12))
                        TextField("provider 名称", text: $customName).textFieldStyle(.roundedBorder).font(.system(size: 12))
                    }
                    if tpl.id == "relay" {
                        HStack {
                            Text("URL").frame(width: 50, alignment: .trailing).font(.system(size: 12))
                            TextField("https://api.example.com", text: $customBaseURL).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        }
                    }
                    HStack {
                        Text("Key").frame(width: 50, alignment: .trailing).font(.system(size: 12))
                        SecureField("API Key", text: $apiKeyValue).textFieldStyle(.roundedBorder).font(.system(size: 12))
                    }
                    HStack {
                        Text("Env").frame(width: 50, alignment: .trailing).font(.system(size: 12))
                        TextField("RELAY_API_KEY", text: envKeyBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    HStack {
                        Text("模型").frame(width: 50, alignment: .trailing).font(.system(size: 12))
                        TextField("默认模型，可选", text: $customDefaultModel).textFieldStyle(.roundedBorder).font(.system(size: 12))
                    }
                    Toggle("需要 OpenAI 鉴权", isOn: $requiresOpenAIAuth)
                        .font(.system(size: 12))
                        .padding(.leading, 54)
                    if let err = errorMessage { Text(err).font(.system(size: 11)).foregroundColor(.red) }
                }.padding(12)
            }
            Spacer()
            HStack {
                Spacer()
                Button("添加") { save(tpl) }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                    .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }.padding(.bottom, 12)
        }
        .onChange(of: customName) { newName in
            guard tpl.id == "relay", !envKeyEdited else { return }
            customEnvKeyName = defaultEnvKeyName(for: newName)
        }
    }

    private func save(_ tpl: ProviderTemplate) {
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard isValidProviderName(name) else {
            errorMessage = "名称只能包含字母、数字、点、下划线、短横线"; return
        }
        let filePath = providersDir.appendingPathComponent(name).appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: filePath.path) {
            errorMessage = "线路 \"\(name)\" 已存在"; return
        }

        let baseURL = tpl.id == "relay" ? customBaseURL : tpl.baseURL
        guard !baseURL.isEmpty else { errorMessage = "请填写 Base URL"; return }

        let envKeyName = customEnvKeyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidEnvKeyName(envKeyName) else {
            errorMessage = "Env 只能包含字母、数字、下划线，且不能以数字开头"; return
        }
        var mp: [String: Any] = ["name": name, "base_url": baseURL, "wire_api": tpl.wireAPI]
        if !envKeyName.isEmpty { mp["env_key"] = envKeyName }
        if requiresOpenAIAuth { mp["requires_openai_auth"] = true }
        var json: [String: Any] = [
            "id": name, "display_name": tpl.displayName == "中转站" ? name : tpl.displayName,
            "badge_emoji": tpl.badgeEmoji, "kind": "relay", "model_provider_toml": mp,
        ]
        let defaultModel = customDefaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !defaultModel.isEmpty { json["default_model"] = defaultModel }

        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: providersDir, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: providersDir.path)
            try data.write(to: filePath)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath.path)
            if !apiKeyValue.isEmpty { appendEnvKey(envKeyName, value: apiKeyValue) }
            onComplete?()
            dismiss()
        } catch {
            errorMessage = "写入失败: \(error.localizedDescription)"
        }
    }

    private func appendEnvKey(_ key: String, value: String) {
        let fm = FileManager.default
        let dir = envFile.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        let line = "\(key)='\(escaped)'\n"
        if fm.fileExists(atPath: envFile.path) {
            if let handle = try? FileHandle(forWritingTo: envFile) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) { handle.write(data) }
                handle.closeFile()
            }
        } else {
            try? line.write(to: envFile, atomically: true, encoding: .utf8)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)
    }

    private var envKeyBinding: Binding<String> {
        Binding(
            get: { customEnvKeyName },
            set: { value in
                customEnvKeyName = value
                envKeyEdited = true
            }
        )
    }
}

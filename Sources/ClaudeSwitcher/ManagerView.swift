import AppKit
import SwiftUI

struct ProfileEditor: View {
    @EnvironmentObject var model: AppModel
    let onDelete: () -> Void

    @State private var draft: Profile
    @State private var modelsText: String
    @State private var fetching = false
    @State private var fetchNote: String?
    @State private var showKey = false
    @State private var authorizationCode = ""
    @StateObject private var login = TokenLogin()

    init(original: Profile, onDelete: @escaping () -> Void) {
        self.onDelete = onDelete
        _draft = State(initialValue: original)
        _modelsText = State(initialValue: original.models.joined(separator: "\n"))
    }

    private var edited: Profile {
        var p = draft
        p.models = modelsText
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return p
    }

    var body: some View {
        Form {
            Section {
                TextField(L("Name", "名称"), text: $draft.name)
                LabeledContent(L("Type", "类型")) {
                    Label(draft.kind.title, systemImage: draft.kind.symbol)
                }
            }

            switch draft.kind {
            case .gateway: gatewaySection
            case .apiKey: apiKeySection
            case .accountToken: tokenSection
            }

            modelsSection


        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 12) {
                ProfileGlyph(kind: draft.kind)
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.name).font(.title2.weight(.semibold))
                    Text(draft.kind.title).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isActive(draft) { StatusPill(text: L("Selected", "已选中"), color: .accentColor) }
            }
            .padding(24)
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if let err = edited.validationError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(L("Save", "保存")) { model.save(edited) }
                    Button(L("Save & Switch", "保存并切换")) { model.save(edited, use: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(edited.validationError != nil || model.busy)
                    Button(L("Use & Open Claude", "使用并打开 Claude")) {
                        model.save(edited, use: true, openAfterSwitch: true)
                    }
                    .disabled(edited.validationError != nil || model.busy)
                }
                Button(L("Delete Profile", "删除配置"), role: .destructive) {
                    if model.confirm(L("Delete \(draft.name)?", "删除「\(draft.name)」？"),
                                     detail: L("This removes it from Claude Desktop too.", "也会从 Claude Desktop 里移除。"),
                                     ok: L("Delete", "删除")) {
                        model.delete(draft)
                        onDelete()
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
        }
        .onChange(of: login.state) { _, state in
            if case .found(let token) = state {
                draft.apiKey = token
                draft.tokenCreatedAt = Date()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .onDisappear { login.stop() }
    }

    private var keyField: some View {
        HStack {
            if showKey {
                TextField("API Key", text: $draft.apiKey)
            } else {
                SecureField("API Key", text: $draft.apiKey)
            }
            Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
        }
        .font(.system(.body, design: .monospaced))
    }

    private var gatewaySection: some View {
        Section {
            TextField("Base URL", text: $draft.baseURL, prompt: Text("https://api.example.com"))
                .font(.system(.body, design: .monospaced))
            Picker(L("Auth header", "认证方式"), selection: $draft.authScheme) {
                ForEach(AuthScheme.allCases) { Text($0.title).tag($0) }
            }
            keyField
        } header: {
            Text(L("Endpoint", "Endpoint"))
        } footer: {
            Text(L("Any Anthropic Messages API compatible endpoint. Use the root URL, without /v1/messages.",
                   "任何兼容 Anthropic Messages API 的地址（中转 / 网关 / 第三方）。填根地址，不要带 /v1/messages。"))
                .foregroundStyle(.secondary)
        }
    }

    private var apiKeySection: some View {
        Section {
            keyField
        } header: {
            Text("Anthropic API")
        } footer: {
            Text(L("A key from console.anthropic.com (sk-ant-api…), billed per token.",
                   "在 console.anthropic.com 创建的 Key（sk-ant-api…），按量计费。"))
                .foregroundStyle(.secondary)
        }
    }

    private var tokenSection: some View {
        Section {
            HStack {
                Button {
                    login.start()
                } label: {
                    Label(L("Sign in with another account…", "登录另一个账号生成 Token…"), systemImage: "person.badge.key")
                }
                .disabled(login.state == .waiting)
                switch login.state {
                case .idle: EmptyView()
                case .waiting:
                    ProgressView().controlSize(.small)
                    Text(L("Waiting for browser authorization…", "等待浏览器授权…")).foregroundStyle(.secondary)
                    Button(L("Cancel", "取消")) { login.stop(); login.state = .idle }.buttonStyle(.borderless)
                case .found:
                    Label(L("Token received", "已获取 Token"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let msg):
                    Text(msg).foregroundStyle(.red).lineLimit(2)
                }
            }
            if login.state == .waiting {
                HStack {
                    SecureField(L("Authorization code, if the browser asks you to paste one", "如果浏览器提供授权码，请粘贴到这里"), text: $authorizationCode)
                    Button(L("Continue", "继续")) {
                        login.submitAuthorizationCode(authorizationCode)
                        authorizationCode = ""
                    }.disabled(authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Button(L("Use terminal login instead…", "改用终端登录…")) { login.start(inTerminal: true) }
                .font(.caption)
            keyField
            if let d = draft.tokenCreatedAt {
                LabeledContent(L("Estimated expiry · not verified", "预计到期 · 未验证")) {
                    Text(Calendar.current.date(byAdding: .year, value: 1, to: d) ?? d, style: .date)
                }
            }
        } header: {
            Text(L("Long-lived token", "长期 Token"))
        } footer: {
            Text(L("Runs Claude Code login in the background. Authorize the intended account in your browser; the token is filled here automatically. Terminal login is available as a fallback. You can also paste an existing token.",
                   "在后台运行 Claude Code 登录，在浏览器中授权目标账号后，Token 会自动填回。终端登录作为备用方式，也可以手动粘贴已有 Token。"))
                .foregroundStyle(.secondary)
        }
    }

    private var modelsSection: some View {
        Section {
            TextEditor(text: $modelsText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90)
            HStack {
                Button {
                    fetchModels()
                } label: {
                    Label(L("Fetch from endpoint", "从接口获取"), systemImage: "arrow.down.circle")
                }
                .disabled(fetching || draft.trimmedKey.isEmpty)
                if fetching { ProgressView().controlSize(.small) }
            }
            if let fetchNote {
                Text(fetchNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text(L("Models", "模型"))
        } footer: {
            Text(draft.kind == .gateway
                 ? L("One model id per line, shown in Claude's model picker. Required.",
                     "每行一个模型 ID，会显示在 Claude 的模型选择里。必填。")
                 : L("Optional. One model id per line; leave empty to use Claude's defaults.",
                     "可选。每行一个模型 ID；留空则用 Claude 默认的模型列表。"))
                .foregroundStyle(.secondary)
        }
    }

    private func fetchModels() {
        fetching = true
        fetchNote = nil
        let p = edited
        Task {
            do {
                let ids = try await ModelFetcher.fetch(for: p)
                if !ids.isEmpty { modelsText = ids.joined(separator: "\n") }
                fetchNote = L("Connected — \(ids.count) models.", "连接成功，共 \(ids.count) 个模型。")
            } catch {
                fetchNote = error.localizedDescription
            }
            fetching = false
        }
    }
}

import AppKit
import SwiftUI

struct ManagerView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section(L("Profiles", "配置")) {
                    ForEach(model.profiles) { p in
                        ProfileRow(profile: p, active: model.isActive(p)).tag(p.id)
                    }
                    .onMove { model.move(from: $0, to: $1) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Menu {
                        ForEach(ProfileKind.allCases) { k in
                            Button { selection = model.addProfile(kind: k).id } label: {
                                Label(k.title, systemImage: k.symbol)
                            }
                        }
                    } label: {
                        Label(L("Add Profile", "添加配置"), systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                }
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 250)
        } detail: {
            if let id = selection, let p = model.profiles.first(where: { $0.id == id }) {
                ProfileEditor(original: p, onDelete: { selection = nil }).id(p.id)
            } else {
                OverviewView()
            }
        }
        .onAppear { model.refresh() }
    }
}

struct ProfileRow: View {
    let profile: Profile
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: profile.kind.symbol).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).lineLimit(1)
                Text(profile.kind.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if active {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if profile.validationError != nil {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

struct OverviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section(L("Claude Desktop is using", "Claude Desktop 当前使用")) {
                HStack {
                    Image(systemName: model.menuIcon).font(.title2)
                    Text(model.activeTitle).font(.title3.weight(.semibold))
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }
                Button(L("Use official account (subscription quota)", "使用官方账号（订阅额度）")) {
                    model.activate(.official)
                }
                .disabled(model.mode == .official || model.busy)
            }
            Section(L("How it works", "说明")) {
                Text(L("""
                • Official account: Claude uses the claude.ai account you signed in with.
                • Profiles: Claude uses an API key, a third-party Anthropic-compatible endpoint, or another account's long-lived token instead.
                • Switching writes Claude Desktop's own settings and restarts Claude.
                """, """
                • 官方账号：Claude 使用你在 App 里登录的 claude.ai 账号和它的订阅额度。
                • 配置：Claude 改用 API Key、第三方兼容 Endpoint，或另一个账号的长期 Token。
                • 切换时会写入 Claude Desktop 自带的设置，并自动重启 Claude。
                """))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(L("Add a profile with the + button at the bottom left.", "点左下角的「添加配置」开始。"))
                    .foregroundStyle(.secondary)
            }
            Section(L("Options", "选项")) {
                Toggle(L("Restart Claude after switching", "切换后自动重启 Claude"), isOn: $model.restartAfterSwitch)
                Toggle(L("Launch at login", "开机自动启动"), isOn: $model.launchAtLogin)
                HStack {
                    Text("Claude Switcher \(Updater.currentVersion)").foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Check for Updates…", "检查更新…")) { model.checkForUpdates() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ProfileEditor: View {
    @EnvironmentObject var model: AppModel
    let onDelete: () -> Void

    @State private var draft: Profile
    @State private var modelsText: String
    @State private var fetching = false
    @State private var fetchNote: String?
    @State private var showKey = false
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

            Section {
                HStack {
                    Button(L("Delete", "删除"), role: .destructive) {
                        if model.confirm(L("Delete \(draft.name)?", "删除「\(draft.name)」？"),
                                         detail: L("This removes it from Claude Desktop too.", "也会从 Claude Desktop 里移除。"),
                                         ok: L("Delete", "删除")) {
                            model.delete(draft)
                            onDelete()
                        }
                    }
                    Spacer()
                    if let err = edited.validationError {
                        Text(err).font(.caption).foregroundStyle(.orange).lineLimit(2)
                    }
                    Button(L("Save", "保存")) { model.save(edited) }
                    Button(model.isActive(draft) ? L("Save", "保存") + " ✓" : L("Save & Use", "保存并使用")) {
                        model.save(edited, use: !model.isActive(draft))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(edited.validationError != nil || model.busy)
                }
            }
        }
        .formStyle(.grouped)
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
                    Text(L("Waiting for Terminal…", "等待终端完成授权…")).foregroundStyle(.secondary)
                    Button(L("Cancel", "取消")) { login.stop(); login.state = .idle }.buttonStyle(.borderless)
                case .found:
                    Label(L("Token received", "已获取 Token"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let msg):
                    Text(msg).foregroundStyle(.red).lineLimit(2)
                }
            }
            keyField
            if let d = draft.tokenCreatedAt {
                LabeledContent(L("Expires around", "大约到期")) {
                    Text(Calendar.current.date(byAdding: .year, value: 1, to: d) ?? d, style: .date)
                }
            }
        } header: {
            Text(L("Long-lived token", "长期 Token"))
        } footer: {
            Text(L("Runs `claude setup-token` in Terminal. Sign in with the other Claude account in the browser; its subscription quota is then used. You can also paste a token here.",
                   "会在终端里运行 `claude setup-token`。在浏览器中用另一个 Claude 账号登录授权，之后就用那个账号的订阅额度。也可以直接粘贴已有 Token。"))
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
                if let fetchNote { Text(fetchNote).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
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

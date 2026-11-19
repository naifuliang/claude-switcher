import AppKit
import SwiftUI

struct StatusPill: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.caption.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(color).background(color.opacity(0.10), in: Capsule())
    }
}

struct ProfileGlyph: View {
    let kind: ProfileKind
    var body: some View {
        Image(systemName: kind.symbol).font(.system(size: 18, weight: .medium))
            .foregroundStyle(Color.accentColor).frame(width: 40, height: 40)
            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
    }
}

struct SurfaceCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct WorkspacePage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 28, weight: .bold))
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.bottom, 2)
                content
            }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ManagerView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: String? = "overview"
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label(L("Overview", "总览"), systemImage: "square.grid.2x2").tag("overview")
                    Label(L("Sessions", "会话"), systemImage: "bubble.left.and.bubble.right").tag("sessions")
                    Label(L("Usage", "额度"), systemImage: "chart.bar").tag("usage")
                    Label(L("Settings", "设置"), systemImage: "slider.horizontal.3").tag("settings")
                }
                Section(L("Accounts & endpoints", "账号与接口")) {
                    ForEach(model.profiles) { p in
                        HStack(spacing: 9) {
                            Image(systemName: p.kind.symbol).foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name).lineLimit(1)
                                Text(p.kind.title).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if model.isActive(p) { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                        }.padding(.vertical, 5).tag(p.id.uuidString)
                    }.onMove { model.move(from: $0, to: $1) }
                }
            }.listStyle(.sidebar)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.title2).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude Switcher").font(.headline)
                        Text(L("Your workspace, connected", "账号与工作，一处管理")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(18)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Menu {
                        ForEach(ProfileKind.allCases) { kind in
                            Button(kind.title) { selection = model.addProfile(kind: kind).id.uuidString }
                        }
                    } label: { Label(L("Add account or endpoint", "添加账号或接口"), systemImage: "plus") }
                    .menuStyle(.borderlessButton)
                    Divider()
                    HStack {
                        Circle().fill(model.claudeRunning ? Color.green : Color.secondary).frame(width: 6, height: 6)
                        Text(model.claudeRunning ? L("Claude is running", "Claude 运行中") : L("Claude is closed", "Claude 未运行")).font(.caption)
                        Spacer()
                    }.foregroundStyle(.secondary)
                }.padding(16)
            }.navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 300)
        } detail: {
            switch selection {
            case "sessions": SessionLibraryView()
            case "usage": UsageView()
            case "settings": SettingsView()
            case .some(let id) where UUID(uuidString: id) != nil:
                if let p = model.profiles.first(where: { $0.id.uuidString == id }) {
                    ProfileEditor(original: p, onDelete: { selection = "overview" }).id(p.id)
                } else { OverviewView() }
            default: OverviewView()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.busy { ProgressView().controlSize(.small) }
                Button { model.refresh() } label: { Label(L("Refresh status", "刷新状态"), systemImage: "arrow.clockwise") }
                Button(L("Open Claude", "打开 Claude")) { model.openClaude() }.disabled(model.busy)
            }
        }.onAppear { model.refresh() }
    }
}

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        WorkspacePage(title: L("Overview", "总览"), subtitle: L("Your accounts, connections and app status in one place.", "账号、连接与运行状态，集中在这里。")) {
            if model.profiles.contains(where: { TokenRepair.candidate($0) != nil }) {
                SurfaceCard {
                    Label(L("A saved token contains extra instruction text", "检测到 Token 混入提示语"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(L("An older version may have appended “Store” to a login token. Back up and repair affected profiles without signing in again.", "旧版本可能将提示语 Store 拼到了登录 Token 后面。可以先备份再修复，无需重新登录。"))
                    Button(L("Back up & repair tokens", "备份并修复 Token")) { model.repairSavedTokens() }.disabled(model.busy)
                }
            }
            SurfaceCard {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("SELECTED CONFIGURATION", "当前选中的配置")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Label(model.activeTitle, systemImage: model.menuIcon).font(.title2.weight(.semibold))
                        Text(L("Selection reflects saved settings. Claude reads changes when it restarts.", "此状态表示已写入的配置；Claude 重启后才会读取更改。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(text: model.busy ? L("Working…", "处理中…") : L("Configured", "已配置"), color: .accentColor)
                }
                Divider()
                HStack {
                    Button(L("Use official account", "切换到官方账号")) { model.activate(.official) }
                        .disabled(model.mode == .official || model.busy)
                    Button(L("Official account & open", "使用官方账号并打开")) { model.activate(.official, openAfterSwitch: true) }
                        .disabled(model.busy)
                    Spacer()
                    Label(model.gatewayEnabled && model.gatewayRunning ? L("Gateway · new requests switch instantly", "网关模式 · 新请求即时切换") : L("Restart required to apply changes", "切换需要重启生效"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("Accounts & endpoints", "账号与接口")).font(.headline)
                    Spacer()
                    Text("\(model.profiles.count)").foregroundStyle(.secondary)
                }
                if model.profiles.isEmpty {
                    SurfaceCard {
                        Label(L("Add your first account", "添加第一个账号"), systemImage: "person.badge.plus").font(.headline)
                        Text(L("Use the add button in the sidebar to get started.", "点击左侧的添加按钮开始。"))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(model.profiles) { p in
                    SurfaceCard {
                        HStack(spacing: 12) {
                            ProfileGlyph(kind: p.kind)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.name).font(.headline).textSelection(.enabled)
                                Text(p.kind.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.isActive(p) { StatusPill(text: L("Selected", "已选中"), color: .accentColor) }
                            if p.validationError != nil { StatusPill(text: L("Incomplete", "待完善"), color: .orange) }
                        }
                        HStack {
                            Button(L("Switch", "切换")) { model.activate(.profile(p)) }
                                .disabled(model.isActive(p) || model.busy || p.validationError != nil)
                            Button(L("Use & Open Claude", "使用并打开 Claude")) { model.activate(.profile(p), openAfterSwitch: true) }
                                .buttonStyle(.borderedProminent).disabled(model.busy || p.validationError != nil)
                            Spacer()
                            Button(L("Check connection", "检查连接")) { model.checkConnection(p) }
                                .disabled(p.trimmedKey.isEmpty || model.checkingConnections.contains(p.id))
                            if model.checkingConnections.contains(p.id) { ProgressView().controlSize(.small) }
                        }
                        if let note = model.connectionNotes[p.id] {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        } else {
                            Text(L("Connection not verified · Usage unavailable", "连接尚未验证 · 额度暂不可读取")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        WorkspacePage(title: L("Settings", "设置"), subtitle: L("Make switching and updates work your way.", "管理切换行为、自动更新与启动方式。")) {
            SurfaceCard {
                Text(L("Switching", "账号切换")).font(.headline)
                Toggle(L("Seamless switching through local gateway", "通过本地网关免重启切换"), isOn: Binding(get: { model.gatewayEnabled }, set: { model.setGatewayEnabled($0) }))
                    .toggleStyle(.switch).disabled(model.busy)
                Text(L("First connection requires a restart and at least one configured model. Later switches affect new requests; existing streams stay on their original account. Model selection is unchanged. Keep this app running. Switching to the official signed-in mode still requires a restart.", "首次连接需要重启，并至少配置一个模型。之后切换只影响新请求，已有生成保持原账号，模型选择不变。请保持本应用运行。切回官方登录模式仍需要重启。"))
                    .font(.caption).foregroundStyle(.secondary)
                if model.gatewayEnabled {
                    StatusPill(text: model.gatewayRunning ? L("Local gateway running", "本地网关运行中") : L("Local gateway unavailable", "本地网关不可用"), color: model.gatewayRunning ? .green : .orange)
                }
                if let error = model.gatewayError { Text(error).font(.caption).foregroundStyle(.orange) }
                Divider()
                Toggle(L("Restart Claude after switching", "切换后自动重启 Claude"), isOn: $model.restartAfterSwitch)
                    .toggleStyle(.switch)
                Text(L("Turning this off saves the new configuration without restarting. It applies at the next launch. Use & Open always restarts when needed.", "关闭后只保存配置，等下次启动 Claude 才生效。「使用并打开」仍会在需要时重启。"))
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle(L("Launch at login", "开机自动启动"), isOn: $model.launchAtLogin).toggleStyle(.switch)
            }
            SurfaceCard {
                HStack {
                    Text(L("Software update", "软件更新")).font(.headline)
                    Spacer()
                    StatusPill(text: "v\(Updater.currentVersion)")
                }
                Toggle(L("Automatically check for updates", "自动检查更新"), isOn: $model.automaticallyCheckUpdates).toggleStyle(.switch)
                Text(L("Checks at launch and every six hours. You choose when to install.", "启动时及每六小时检查，有新版时由你确认安装。"))
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.updateStatus).font(.subheadline)
                        if let date = model.lastUpdateCheck {
                            Text(date, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.checkingForUpdates { ProgressView().controlSize(.small) }
                    Button(L("Check now", "立即检查")) { model.checkForUpdates() }.disabled(model.checkingForUpdates)
                }
            }
            SurfaceCard {
                Label(L("Menu bar", "状态栏"), systemImage: "menubar.rectangle").font(.headline)
                Text(L("Click the menu bar icon to open this window. All controls live here.", "点击状态栏图标即可打开主界面，所有操作都在这里。"))
                    .foregroundStyle(.secondary)
                Button(L("Quit Claude Switcher", "退出 Claude Switcher")) { NSApp.terminate(nil) }
            }
        }
    }
}

struct UsageView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        WorkspacePage(title: L("Usage", "额度"), subtitle: L("Plan limits and API billing are different. Only verified figures belong here.", "订阅额度与 API 账单不同，这里只展示有来源的数据。")) {
            SurfaceCard {
                Label(L("Subscription usage", "订阅用量"), systemImage: "chart.bar.xaxis").font(.headline)
                Text(L("Refresh an account to read its usage and reset times. Checks are limited to once a minute and respect server cooldowns. API and gateway billing is provider-specific. The website uses your browser's signed-in account.", "刷新账号以读取用量和重置时间，每分钟最多查询一次，并遵守服务端冷却时间。API 与网关的账单需向服务商查询。网页显示浏览器登录的账号。"))
                    .foregroundStyle(.secondary)
                Link(L("Open official usage page", "打开官方用量页"), destination: URL(string: "https://claude.ai/settings/usage")!)
            }
            ForEach(model.profiles) { p in
                SurfaceCard {
                    HStack {
                        ProfileGlyph(kind: p.kind)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(p.name).font(.headline)
                            Text(p.kind == .accountToken ? L("Subscription · remaining quota unknown", "订阅账号 · 剩余额度未知") : L("API billing · balance unavailable", "API 计费 · 余额暂不可读"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if p.kind == .accountToken {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Button(L("Refresh usage", "刷新额度")) { model.refreshUsage(p) }
                                    .disabled(p.trimmedKey.isEmpty || model.fetchingUsage.contains(p.id) || (model.usageRetryAt[p.id] ?? .distantPast) > context.date)
                            }
                        }
                        if model.fetchingUsage.contains(p.id) { ProgressView().controlSize(.small) }
                    }
                    if let snapshot = model.usage[p.id] {
                        ForEach(snapshot.windows) { window in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(window.label).font(.subheadline)
                                    Spacer()
                                    Text(String(format: L("%.1f%% used", "已用 %.1f%%"), window.usedPercent))
                                }
                                ProgressView(value: min(window.usedPercent, 100), total: 100)
                                if let date = window.resetsAt {
                                    Text(L("Resets: ", "重置时间：") + date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text(L("Updated: ", "更新于：") + snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.usageErrors[p.id] {
                        Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        if model.usage[p.id] != nil { Text(L("Showing the last successful reading.", "上方保留的是上次成功读取的数据。")).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let retry = model.usageRetryAt[p.id], retry > Date() {
                        Text(L("Next check after ", "可再次查询时间：") + retry.formatted(date: .omitted, time: .standard))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            SurfaceCard {
                Text(L("About resets", "关于重置")).font(.headline)
                Text(L("Quota resets are controlled by the provider. This app cannot reset a subscription allowance. Refreshing usage, clearing a conversation, and switching accounts do not reset the original account's quota.", "额度由服务商按周期重置，本工具不能重置订阅额度。刷新用量、清空会话和切换账号，都不会重置原账号的额度。"))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

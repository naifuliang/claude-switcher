import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var profiles: [Profile] = ProfileStore.load()
    @Published private(set) var mode: ActiveMode = .official
    @Published private(set) var busy = false
    @Published private(set) var claudeRunning = ClaudeDesktop.isRunning
    @Published private(set) var connectionNotes: [UUID: String] = [:]
    @Published private(set) var checkingConnections: Set<UUID> = []
    @Published private(set) var gatewayEnabled = GatewaySettings.load().enabled
    @Published private(set) var gatewayRunning = false
    @Published private(set) var gatewayError: String?
    @Published private(set) var usage: [UUID: UsageSnapshot] = [:]
    @Published private(set) var usageErrors: [UUID: String] = [:]
    @Published private(set) var usageRetryAt: [UUID: Date] = [:]
    @Published private(set) var fetchingUsage: Set<UUID> = []
    @Published private(set) var lastUpdateCheck: Date?
    @Published private(set) var updateStatus = L("Not checked yet", "尚未检查")

    @Published var restartAfterSwitch: Bool = UserDefaults.standard.object(forKey: "restartAfterSwitch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(restartAfterSwitch, forKey: "restartAfterSwitch") }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    @Published var automaticallyCheckUpdates: Bool = UserDefaults.standard.object(forKey: "automaticallyCheckUpdates") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automaticallyCheckUpdates, forKey: "automaticallyCheckUpdates")
            if automaticallyCheckUpdates { checkForUpdates(automatically: true) }
        }
    }
    @Published private(set) var checkingForUpdates = false
    private var updateTimer: Timer?
    private var lastAutomaticCheck: Date?
    private var promptedUpdateTag: String?
    private var timer: Timer?

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.refresh() }
        }
    }

    func startAutomaticUpdates() {
        guard updateTimer == nil else { return }
        checkForUpdates(automatically: true)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in self.checkForUpdates(automatically: true) }
        }
    }

    func refresh() {
        claudeRunning = ClaudeDesktop.isRunning
        let m = ClaudeDesktop.currentMode(profiles: profiles)
        if m != mode { mode = m }
    }

    func isActive(_ p: Profile) -> Bool { mode == .profile(p.id) }

    var activeTitle: String {
        switch mode {
        case .official: return L("Official account", "官方账号")
        case .profile(let id): return profiles.first { $0.id == id }?.name ?? "?"
        case .external(let name): return name
        }
    }

    var menuIcon: String {
        switch mode {
        case .official: return "person.crop.circle"
        case .profile(let id): return profiles.first { $0.id == id }?.kind.symbol ?? "key.horizontal"
        case .external: return "key.horizontal"
        }
    }

    // MARK: - Profiles

    func addProfile(kind: ProfileKind) -> Profile {
        let base: String
        switch kind {
        case .gateway: base = L("Endpoint", "第三方")
        case .apiKey: base = "API"
        case .accountToken: base = L("Account", "账号")
        }
        var n = 1
        while profiles.contains(where: { $0.name == "\(base) \(n)" }) { n += 1 }
        let p = Profile(name: "\(base) \(n)", kind: kind)
        profiles.append(p)
        persist()
        return p
    }

    /// Saves a profile; when `use` is set, also switches Claude to it.
    func save(_ p: Profile, use: Bool = false, openAfterSwitch: Bool = false) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
        persist()
        if use {
            activate(.profile(p), openAfterSwitch: openAfterSwitch)
        } else if p.validationError == nil {
            do {
                try ClaudeDesktop.sync(p, profiles: profiles)
                if isActive(p) && ClaudeDesktop.isRunning {
                    if confirm(L("Restart Claude now so the change takes effect?", "现在重启 Claude 让修改生效吗？"),
                               detail: L("Running conversations in Claude will be interrupted.", "Claude 里正在进行的对话会被中断。"),
                               ok: L("Restart", "重启")) {
                        activate(.profile(p), skipConfirm: true)
                    }
                }
            } catch { showError(error) }
        }
        refresh()
    }

    func delete(_ p: Profile) {
        do { try ClaudeDesktop.remove(p, profiles: profiles) } catch { showError(error) }
        profiles.removeAll { $0.id == p.id }
        persist()
        refresh()
    }

    func move(from: IndexSet, to: Int) {
        profiles.move(fromOffsets: from, toOffset: to)
        persist()
    }

    private func persist() {
        do { try ProfileStore.save(profiles) } catch { showError(error) }
    }

    // MARK: - Switching

    func activate(_ target: SwitchTarget, skipConfirm: Bool = false, openAfterSwitch: Bool = false) {
        guard !busy else { return }
        if case .profile(let p) = target, let err = p.validationError {
            showMessage(L("This profile is not complete", "这个配置还没填完整"), detail: err)
            return
        }
        if case .profile(let profile) = target, ClaudeDesktop.usesLocalGateway {
            guard gatewayRunning else {
                showMessage(L("Local gateway is not running", "本地网关未运行"), detail: gatewayError ?? L("Restart Claude Switcher or disable seamless switching in Settings.", "请重启 Claude Switcher，或在设置中关闭免重启切换。"))
                return
            }
            do {
                var settings = GatewaySettings.load()
                settings.selectedProfileID = profile.id
                try settings.save()
                refresh()
                if openAfterSwitch { openClaude() }
            } catch { showError(error) }
            return
        }
        let restart = restartAfterSwitch || openAfterSwitch
        if restart && ClaudeDesktop.isRunning && !skipConfirm
            && !UserDefaults.standard.bool(forKey: "skipRestartConfirm") {
            let alert = NSAlert()
            alert.messageText = L("Claude will restart to switch.", "切换需要重启 Claude。")
            alert.informativeText = L("Running conversations in Claude will be interrupted.", "Claude 里正在进行的对话会被中断。")
            alert.addButton(withTitle: L("Switch & Restart", "切换并重启"))
            alert.addButton(withTitle: L("Cancel", "取消"))
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L("Don't ask again", "不再询问")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: "skipRestartConfirm")
            }
        }
        busy = true
        let snapshot = profiles
        Task.detached {
            let result = Result {
                let note = try ClaudeDesktop.switchTo(target, profiles: snapshot, restart: restart)
                if openAfterSwitch && !ClaudeDesktop.isRunning { try ClaudeDesktop.launchChecked() }
                return note
            }
            await MainActor.run {
                let model = AppModel.shared
                model.busy = false
                model.refresh()
                if case .success = result, case .official = target {
                    var settings = GatewaySettings.load()
                    settings.enabled = false
                    do {
                        try settings.save()
                        model.gatewayEnabled = false
                        model.gatewayRunning = false
                        LocalGateway.shared.stop()
                    } catch { model.gatewayError = error.localizedDescription }
                }
                switch result {
                case .success(let note?): model.showMessage(L("Switched", "已切换"), detail: note)
                case .success(nil): break
                case .failure(let e): model.showError(e)
                }
            }
        }
    }

    func repairSavedTokens() {
        guard !busy else { return }
        do {
            let count = try TokenRepair.repair()
            profiles = ProfileStore.load()
            connectionNotes = [:]
            usage = [:]
            usageErrors = [:]
            usageRetryAt = [:]
            showMessage(L("Saved tokens repaired", "已修复保存的 Token"), detail: L("Repaired \(count) profiles. Originals were backed up. Restart Claude to reload an already active direct connection.", "已修复 \(count) 个配置，原记录已备份。若 Claude 正在使用直连，请重启以重新读取凭据。"))
        } catch { showError(error) }
    }

    func prepareHistoryImport() {
        guard !busy else { return }
        if mode == .official { openClaude(); return }
        guard !ClaudeDesktop.managedPlistExists else {
            showMessage(L("Managed configuration", "受管理的配置"), detail: L("Ask your administrator to enable Claude's import/export feature. This app will not change managed import policy.", "请管理员启用 Claude 的导入与导出功能；本工具不会修改受管理的导入策略。"))
            return
        }
        guard confirm(L("Enable Claude's import & export?", "启用 Claude 的导入与导出？"),
            detail: L("The active configuration will be backed up. Claude will close and reopen. No sessions are copied until you select them in Claude's import wizard.", "将先备份当前配置，再关闭并重新打开 Claude。只有你在 Claude 导入向导中选择内容后，才会复制会话。"), ok: L("Enable & open Claude", "启用并打开 Claude")) else { return }
        busy = true
        Task {
            let result = await Task.detached { Result { () -> URL in
                if ClaudeDesktop.isRunning && !ClaudeDesktop.quit() {
                    throw SwitchError(message: L("Claude did not quit. Close it and try again.", "Claude 未退出，请关闭后重试。"))
                }
                let backup = try HistoryImport.prepare()
                try ClaudeDesktop.launchChecked()
                return backup
            } }.value
            busy = false
            refresh()
            switch result {
            case .success:
                showMessage(L("Import is enabled", "已启用导入"), detail: L("In Claude, press ⌘, and choose Import & export. Select local history and the previous Claude data folder. Review sessions and projects before importing. The original files are retained by this tool.", "在 Claude 中按 ⌘,，选择「Import & export（导入与导出）」，从本地历史中选择原来的 Claude 数据目录，预览会话与项目后再导入。本工具保留原文件。"))
            case .failure(let error): showError(error)
            }
        }
    }

    func restoreGateway() {
        guard gatewayEnabled else { return }
        Task {
            do { try await LocalGateway.shared.start(); gatewayRunning = true }
            catch { gatewayError = error.localizedDescription }
        }
    }

    func setGatewayEnabled(_ enabled: Bool) {
        guard !busy else { return }
        let settings = GatewaySettings.load()
        guard case .profile(let id) = mode, let selected = profiles.first(where: { $0.id == id }) else {
            showMessage(L("Select an account first", "请先选中一个账号"), detail: L("Seamless switching is available for saved account and API profiles, not the official signed-in mode.", "免重启切换用于已保存的账号和 API 配置，不用于官方登录模式。"))
            return
        }
        let proxy: Profile
        do { proxy = try settings.proxyProfile(profiles: profiles) }
        catch { if enabled { showError(error); return }; proxy = selected }
        if ClaudeDesktop.isRunning && !confirm(L("Restart Claude to change connection mode?", "重启 Claude 以更改连接方式？"),
            detail: L("This first connection change requires a restart. Later switches through the local gateway affect new requests without restarting. Keep Claude Switcher running while using the gateway.", "首次更改连接方式需要重启。接入后更换后端账号只影响新请求，无需再次重启。使用网关期间请保持 Claude Switcher 运行。"), ok: L("Continue", "继续")) { return }
        busy = true
        gatewayError = nil
        let profiles = self.profiles
        Task {
            defer { busy = false; refresh() }
            do {
                if enabled {
                    try await LocalGateway.shared.start()
                    gatewayRunning = true
                    var next = settings
                    next.enabled = true
                    next.selectedProfileID = selected.id
                    try next.save()
                    gatewayEnabled = true
                }
                let target = enabled ? proxy : selected
                let result = await Task.detached { Result { try ClaudeDesktop.switchTo(.profile(target), profiles: profiles, restart: true) } }.value
                let note = try result.get()
                if !enabled {
                    var next = settings; next.enabled = false; try next.save()
                    gatewayEnabled = false
                    gatewayRunning = false
                    LocalGateway.shared.stop()
                }
                if let note { showMessage(L("Connection settings saved", "连接设置已保存"), detail: note) }
            } catch {
                gatewayError = error.localizedDescription
                if enabled && !ClaudeDesktop.usesLocalGateway {
                    try? settings.save()
                    gatewayEnabled = settings.enabled
                    if !settings.enabled { LocalGateway.shared.stop(); gatewayRunning = false }
                }
                showError(error)
            }
        }
    }

    func refreshUsage(_ profile: Profile) {
        guard !fetchingUsage.contains(profile.id) else { return }
        if let retryAt = usageRetryAt[profile.id], retryAt > Date() { return }
        fetchingUsage.insert(profile.id)
        usageErrors[profile.id] = nil
        Task {
            defer { fetchingUsage.remove(profile.id) }
            do {
                let snapshot = try await UsageFetcher.fetch(for: profile)
                guard profiles.first(where: { $0.id == profile.id })?.trimmedKey == profile.trimmedKey else { return }
                usage[profile.id] = snapshot
                usageRetryAt[profile.id] = Date().addingTimeInterval(60)
            } catch {
                usageErrors[profile.id] = error.localizedDescription
                usageRetryAt[profile.id] = Date().addingTimeInterval((error as? UsageFetchError)?.retryAfter ?? 60)
            }
        }
    }

    func checkConnection(_ profile: Profile) {
        guard !checkingConnections.contains(profile.id) else { return }
        checkingConnections.insert(profile.id)
        Task {
            defer { checkingConnections.remove(profile.id) }
            do {
                let models = try await ModelFetcher.fetch(for: profile)
                connectionNotes[profile.id] = L("Model list available · \(models.count) models", "模型接口可用 · \(models.count) 个模型")
            } catch {
                connectionNotes[profile.id] = error.localizedDescription
            }
        }
    }

    func openClaude() {
        guard !busy else { return }
        busy = true
        Task {
            let result = await Task.detached { Result { try ClaudeDesktop.launchChecked() } }.value
            busy = false
            if case .failure(let error) = result { showError(error) }
        }
    }

    // MARK: - Misc

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            showError(error)
        }
    }

    func checkForUpdates(automatically: Bool = false) {
        guard !checkingForUpdates else { return }
        if automatically {
            guard automaticallyCheckUpdates, !busy else { return }
            if let lastAutomaticCheck, Date().timeIntervalSince(lastAutomaticCheck) < 6 * 60 * 60 { return }
            lastAutomaticCheck = Date()
        }
        checkingForUpdates = true
        Task {
            defer { checkingForUpdates = false }
            do {
                let tag = try await Updater.latestTag()
                lastUpdateCheck = Date()
                updateStatus = Updater.isNewer(tag, than: Updater.currentVersion)
                    ? L("Update available: \(tag)", "有新版本：\(tag)") : L("Up to date", "已是最新版本")
                if automatically && !automaticallyCheckUpdates { return }
                if Updater.isNewer(tag, than: Updater.currentVersion) {
                    if automatically && promptedUpdateTag == tag { return }
                    promptedUpdateTag = tag
                    if confirm(L("Update to \(tag)?", "更新到 \(tag)？"),
                               detail: L("Current version: \(Updater.currentVersion). The installer runs in Terminal and relaunches the app.",
                                         "当前版本：\(Updater.currentVersion)。安装器会在终端里运行并自动重新打开本应用。"),
                               ok: L("Update", "更新")) {
                        try Updater.runInstaller(tag: tag)
                    }
                } else if !automatically {
                    showMessage(L("You're up to date", "已是最新版本"), detail: "Claude Switcher \(Updater.currentVersion)")
                }
            } catch {
                updateStatus = L("Check failed — try again", "检查失败，请重试")
                if !automatically { showError(error) }
            }
        }
    }

    func confirm(_ title: String, detail: String, ok: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: L("Cancel", "取消"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func showMessage(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Something went wrong", "出错了")
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

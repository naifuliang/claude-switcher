import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var profiles: [Profile] = ProfileStore.load()
    @Published private(set) var mode: ActiveMode = .official
    @Published private(set) var busy = false

    @Published var restartAfterSwitch: Bool = UserDefaults.standard.object(forKey: "restartAfterSwitch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(restartAfterSwitch, forKey: "restartAfterSwitch") }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    private var timer: Timer?

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.refresh() }
        }
    }

    func refresh() {
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
    func save(_ p: Profile, use: Bool = false) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
        persist()
        if use {
            activate(.profile(p))
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

    func activate(_ target: SwitchTarget, skipConfirm: Bool = false) {
        guard !busy else { return }
        if case .profile(let p) = target, let err = p.validationError {
            showMessage(L("This profile is not complete", "这个配置还没填完整"), detail: err)
            return
        }
        let restart = restartAfterSwitch
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
            let result = Result { try ClaudeDesktop.switchTo(target, profiles: snapshot, restart: restart) }
            await MainActor.run {
                let model = AppModel.shared
                model.busy = false
                model.refresh()
                switch result {
                case .success(let note?): model.showMessage(L("Switched", "已切换"), detail: note)
                case .success(nil): break
                case .failure(let e): model.showError(e)
                }
            }
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

    func checkForUpdates() {
        Task {
            do {
                let tag = try await Updater.latestTag()
                if Updater.isNewer(tag, than: Updater.currentVersion) {
                    if confirm(L("Update to \(tag)?", "更新到 \(tag)？"),
                               detail: L("Current version: \(Updater.currentVersion). The installer runs in Terminal and relaunches the app.",
                                         "当前版本：\(Updater.currentVersion)。安装器会在终端里运行并自动重新打开本应用。"),
                               ok: L("Update", "更新")) {
                        try Updater.runInstaller()
                    }
                } else {
                    showMessage(L("You're up to date", "已是最新版本"), detail: "Claude Switcher \(Updater.currentVersion)")
                }
            } catch {
                showError(error)
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

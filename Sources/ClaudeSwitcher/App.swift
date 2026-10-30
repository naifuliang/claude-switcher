import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
        // Any plain argument means CLI use; AppKit's own "-NS…"/"-Apple…" flags do not.
        if let first = args.first, !first.hasPrefix("-NS"), !first.hasPrefix("-Apple") {
            exit(CLI.run(Array(args)))
        }
        ClaudeSwitcherApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: open the manager on first run only.
        if AppModel.shared.profiles.isEmpty { ManagerWindow.show() }
    }

    /// Opening the app again (Finder, Launchpad, Spotlight) shows the manager.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ManagerWindow.show()
        return false
    }
}

/// The profile manager, kept as one reusable AppKit window.
@MainActor
enum ManagerWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: ManagerView()
                .environmentObject(AppModel.shared)
                .frame(minWidth: 720, minHeight: 500))
            let w = NSWindow(contentViewController: host)
            w.title = "Claude Switcher"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.setContentSize(NSSize(width: 820, height: 580))
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("ClaudeSwitcherManager")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ClaudeSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.menuIcon)
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Text(L("Now: ", "当前：") + model.activeTitle)
        Divider()
        Button(mark(model.mode == .official) + L("Official account (subscription)", "官方账号（订阅额度）")) {
            model.activate(.official)
        }
        ForEach(model.profiles) { p in
            Button(mark(model.isActive(p)) + p.name + "  ·  " + p.kind.title) {
                model.activate(.profile(p))
            }
        }
        if case .external(let name) = model.mode {
            Text("✓ " + name + L(" (set in Claude)", "（Claude 内设置）"))
        }
        Divider()
        Button(L("Manage Profiles…", "管理配置…")) {
            ManagerWindow.show()
        }
        .keyboardShortcut(",")
        Toggle(L("Restart Claude after switching", "切换后自动重启 Claude"), isOn: $model.restartAfterSwitch)
        Toggle(L("Launch at login", "开机自动启动"), isOn: $model.launchAtLogin)
        Button(L("Check for Updates…", "检查更新…")) { model.checkForUpdates() }
        Divider()
        Button(L("Quit Claude Switcher", "退出 Claude Switcher")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func mark(_ on: Bool) -> String { on ? "✓  " : "     " }
}

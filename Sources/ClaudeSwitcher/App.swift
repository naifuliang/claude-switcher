import AppKit
import SwiftUI

@main
enum Main {
    @MainActor
    static func main() {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
        if args.first == "gateway-serve" {
            guard GatewaySettings.load().enabled else { exit(1) }
            Task.detached {
                do { try await LocalGateway.shared.start() }
                catch { fputs("Local gateway could not start.\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        // Any plain argument means CLI use; AppKit's own "-NS…"/"-Apple…" flags do not.
        if let first = args.first, !first.hasPrefix("-NS"), !first.hasPrefix("-Apple") {
            exit(CLI.run(Array(args)))
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    @objc private func statusClicked() { ManagerWindow.show() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Claude Switcher")
        item.button?.toolTip = L("Open Claude Switcher", "打开 Claude Switcher 主界面")
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Quit Claude Switcher", "退出 Claude Switcher"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem(title: L("Edit", "编辑"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L("Edit", "编辑"))
        for (title, selector, key) in [(L("Undo", "撤销"), "undo:", "z"), (L("Cut", "剪切"), "cut:", "x"), (L("Copy", "复制"), "copy:", "c"), (L("Paste", "粘贴"), "paste:", "v"), (L("Select All", "全选"), "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        AppModel.shared.restoreGateway()
        AppModel.shared.startAutomaticUpdates()
        ManagerWindow.show()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if ClaudeDesktop.usesLocalGateway {
            AppModel.shared.showMessage(L("Claude is connected to the local gateway", "Claude 正在使用本地网关"),
                detail: L("Disable seamless switching in Settings before quitting, so Claude can connect directly. Closing this window keeps the gateway running.", "退出前请先在设置中关闭免重启切换，让 Claude 恢复直连。关闭窗口不会停止网关。"))
            return .terminateCancel
        }
        return .terminateNow
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
                .frame(minWidth: 920, minHeight: 640))
            let w = NSWindow(contentViewController: host)
            w.title = "Claude Switcher"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.setContentSize(NSSize(width: 1080, height: 760))
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("ClaudeSwitcherManager")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

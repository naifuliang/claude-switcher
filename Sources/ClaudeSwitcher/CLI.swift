import Foundation

/// `claude-switcher <command>` — the same switching from a terminal.
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        let profiles = ProfileStore.load()
        let noRestart = args.contains("--no-restart")
        let rest = args.filter { !$0.hasPrefix("--") }

        switch rest.first ?? "help" {
        case "status", "current":
            print(describe(ClaudeDesktop.currentMode(profiles: profiles), profiles: profiles))
            return 0

        case "list", "ls":
            let mode = ClaudeDesktop.currentMode(profiles: profiles)
            print("\(mode == .official ? "*" : " ") 0  official  (\(L("Official account", "官方账号")))")
            for (i, p) in profiles.enumerated() {
                let star = mode == .profile(p.id) ? "*" : " "
                let warn = p.validationError == nil ? "" : "  [\(L("incomplete", "未完成"))]"
                print("\(star) \(i + 1)  \(p.name)  (\(p.kind.title))\(warn)")
            }
            return 0

        case "use", "switch":
            guard rest.count >= 2 else { return usage() }
            let query = rest.dropFirst().joined(separator: " ")
            let target: SwitchTarget
            if ["official", "0", "1p"].contains(query.lowercased()) {
                target = .official
            } else if let p = find(query, in: profiles) {
                target = .profile(p)
            } else {
                fputs("\(L("No profile named", "没有找到配置")) \"\(query)\"\n", stderr)
                return 1
            }
            do {
                let note = try ClaudeDesktop.switchTo(target, profiles: profiles, restart: !noRestart)
                print("✓ " + describe(ClaudeDesktop.currentMode(profiles: profiles), profiles: profiles))
                if let note { print(note) }
                return 0
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                return 1
            }

        case "version", "-v":
            print(Updater.currentVersion)
            return 0

        default:
            return usage()
        }
    }

    private static func find(_ q: String, in profiles: [Profile]) -> Profile? {
        if let n = Int(q), n >= 1, n <= profiles.count { return profiles[n - 1] }
        return profiles.first { $0.name == q }
            ?? profiles.first { $0.name.lowercased() == q.lowercased() }
            ?? profiles.first { $0.name.lowercased().hasPrefix(q.lowercased()) }
    }

    private static func describe(_ mode: ActiveMode, profiles: [Profile]) -> String {
        switch mode {
        case .official: return L("Official account (subscription)", "官方账号（订阅额度）")
        case .profile(let id):
            let p = profiles.first { $0.id == id }
            return "\(p?.name ?? "?") (\(p?.kind.title ?? ""))"
        case .external(let name): return "\(name) (\(L("set in Claude", "Claude 内设置")))"
        }
    }

    private static func usage() -> Int32 {
        print("""
        Claude Switcher \(Updater.currentVersion)

        claude-switcher status              \(L("show what Claude Desktop uses", "查看当前使用的方式"))
        claude-switcher list                \(L("list profiles", "列出所有配置"))
        claude-switcher use official        \(L("use the signed-in account", "切换到官方账号"))
        claude-switcher use <name|number>   \(L("use a profile", "切换到某个配置"))
            --no-restart                    \(L("don't restart Claude", "不自动重启 Claude"))

        \(L("Profiles are managed in the menu bar app.", "配置在菜单栏 App 里管理。"))
        """)
        return 0
    }
}

import AppKit
import Foundation

enum ActiveMode: Equatable {
    /// Signed-in claude.ai account (subscription quota).
    case official
    /// One of our profiles is applied.
    case profile(UUID)
    /// A third-party config applied that this app does not manage.
    case external(String)
}

enum SwitchTarget {
    case official
    case profile(Profile)
}

struct SwitchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Reads and writes Claude Desktop's own third-party-inference settings.
///
/// Claude Desktop keeps them in `~/Library/Application Support/Claude-3p/`:
/// - `claude_desktop_config.json` → `"deploymentMode": "1p" | "3p"` picks the
///   claude.ai sign-in (1p) or the third-party inference config (3p).
/// - `configLibrary/_meta.json` → `{ appliedId, entries: [{id, name}] }`
/// - `configLibrary/<id>.json` → flat keys such as `inferenceProvider`.
/// The app reads all of this at launch, so a switch needs a restart.
enum ClaudeDesktop {
    static let bundleID = "com.anthropic.claudefordesktop"

    static var root: URL {
        if let o = ProcessInfo.processInfo.environment["CLAUDE_SWITCHER_3P_DIR"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude-3p", isDirectory: true)
    }
    static var configURL: URL { root.appendingPathComponent("claude_desktop_config.json") }
    static var libraryURL: URL { root.appendingPathComponent("configLibrary", isDirectory: true) }
    static var metaURL: URL { libraryURL.appendingPathComponent("_meta.json") }
    static func entryURL(_ id: String) -> URL { libraryURL.appendingPathComponent("\(id).json") }

    /// Device-wide MDM settings win over everything written here.
    static var managedPlistExists: Bool {
        let user = NSUserName()
        return ["/Library/Managed Preferences/com.anthropic.claudefordesktop.plist",
                "/Library/Managed Preferences/\(user)/com.anthropic.claudefordesktop.plist"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - State

    static func currentMode(profiles: [Profile]) -> ActiveMode {
        let mode = FileIO.readJSON(configURL)["deploymentMode"] as? String
        if mode == "1p" { return .official }
        let meta = FileIO.readJSON(metaURL)
        guard let applied = meta["appliedId"] as? String, !applied.isEmpty,
              FileIO.readJSON(entryURL(applied))["inferenceProvider"] != nil else { return .official }
        if let p = profiles.first(where: { $0.claudeID == applied }) { return .profile(p.id) }
        let entries = meta["entries"] as? [[String: Any]] ?? []
        let name = entries.first { ($0["id"] as? String) == applied }?["name"] as? String
        return .external(name ?? L("Custom config", "自定义配置"))
    }

    // MARK: - Writing

    private static func setDeploymentMode(_ mode: String) throws {
        var cfg = FileIO.readJSON(configURL)
        cfg["deploymentMode"] = mode
        try FileIO.writeJSON(cfg, to: configURL)
    }

    /// Writes (or refreshes) a profile's entry in Claude's config library.
    /// Does not change which mode Claude starts in.
    static func sync(_ p: Profile, profiles: [Profile], apply: Bool = false) throws {
        let wasOfficial = currentMode(profiles: profiles) == .official
        let id = p.claudeID

        // Keep any non-inference keys the user set in Claude's own editor.
        var entry = FileIO.readJSON(entryURL(id))
        for k in entry.keys where k.hasPrefix("inference") { entry.removeValue(forKey: k) }
        for (k, v) in p.claudeEntry { entry[k] = v }
        try FileIO.writeJSON(entry, to: entryURL(id))

        var meta = FileIO.readJSON(metaURL)
        var entries = meta["entries"] as? [[String: Any]] ?? []
        if let i = entries.firstIndex(where: { ($0["id"] as? String) == id }) {
            entries[i]["name"] = p.name
        } else {
            entries.append(["id": id, "name": p.name])
        }
        meta["entries"] = entries
        if apply || (meta["appliedId"] as? String ?? "").isEmpty { meta["appliedId"] = id }
        try FileIO.writeJSON(meta, to: metaURL)

        if apply {
            try setDeploymentMode("3p")
        } else if wasOfficial {
            // Without an explicit "1p", an applied entry would flip Claude to 3p.
            try setDeploymentMode("1p")
        }
    }

    static func apply(_ target: SwitchTarget, profiles: [Profile]) throws {
        switch target {
        case .official:
            try setDeploymentMode("1p")
        case .profile(let p):
            if let err = p.validationError { throw SwitchError(message: "\(p.name): \(err)") }
            try sync(p, profiles: profiles, apply: true)
        }
    }

    static func remove(_ p: Profile, profiles: [Profile]) throws {
        let id = p.claudeID
        if currentMode(profiles: profiles) == .profile(p.id) { try setDeploymentMode("1p") }
        var meta = FileIO.readJSON(metaURL)
        guard !meta.isEmpty else { return }
        var entries = meta["entries"] as? [[String: Any]] ?? []
        entries.removeAll { ($0["id"] as? String) == id }
        meta["entries"] = entries
        if (meta["appliedId"] as? String) == id {
            meta["appliedId"] = (entries.first?["id"] as? String) ?? ""
        }
        try FileIO.writeJSON(meta, to: metaURL)
        try? FileManager.default.removeItem(at: entryURL(id))
    }

    // MARK: - Process control

    static var runningApps: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }
    static var isRunning: Bool { !runningApps.isEmpty }

    /// Asks Claude to quit and waits up to `timeout` seconds. Returns true once it is gone.
    @discardableResult
    static func quit(timeout: TimeInterval = 20) -> Bool {
        runningApps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        if isRunning { return false }
        Thread.sleep(forTimeInterval: 0.5) // let it flush its files
        return true
    }

    static func launch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 15)
    }

    /// Applies a target, restarting Claude around the write when it is running.
    /// Blocking — call off the main thread. Returns a note for the user, if any.
    static func switchTo(_ target: SwitchTarget, profiles: [Profile], restart: Bool) throws -> String? {
        if case .profile(let p) = target, let err = p.validationError {
            throw SwitchError(message: "\(p.name): \(err)")
        }
        let wasRunning = isRunning
        var note: String?
        if restart && wasRunning && !quit() {
            note = L("Claude did not quit, so the change applies the next time you restart it.",
                     "Claude 没有退出，设置会在你下次重启 Claude 后生效。")
        }
        try apply(target, profiles: profiles)
        if restart && wasRunning && note == nil { launch() }
        if !restart && wasRunning {
            note = L("Restart Claude to apply.", "重启 Claude 后生效。")
        }
        if managedPlistExists {
            note = (note.map { $0 + "\n" } ?? "") + L(
                "A managed (MDM) Claude profile exists on this Mac and may override this setting.",
                "这台 Mac 上有 MDM 管理的 Claude 配置，可能会覆盖这里的设置。")
        }
        return note
    }
}

import AppKit
import Foundation

/// Runs a shell script in a visible Terminal window by opening a `.command`
/// file — no Automation permission needed.
enum TerminalRunner {
    static func run(script: String, name: String) throws {
        try FileManager.default.createDirectory(at: AppPaths.tmp, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = AppPaths.tmp.appendingPathComponent("\(name).command")
        try ("#!/bin/zsh -l\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: cfg)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Drives `claude setup-token` in Terminal and picks the token out of its output.
@MainActor
final class TokenLogin: ObservableObject {
    enum State: Equatable {
        case idle
        case waiting
        case found(String)
        case failed(String)
    }

    @Published var state: State = .idle
    private var timer: Timer?
    private var logURL: URL?
    private var lastSeen: String?
    private var startedAt = Date()

    func start() {
        stop()
        let log = AppPaths.tmp.appendingPathComponent("setup-token-\(UUID().uuidString).log")
        logURL = log
        lastSeen = nil
        startedAt = Date()
        let q = TerminalRunner.shellQuote(log.path)
        let script = """
        clear
        echo "Claude Switcher — \(L("long-lived token for another account", "为另一个账号生成长期 Token"))"
        echo ""
        echo "\(L("1. A browser page opens. Sign in with the OTHER Claude account",
                  "1. 浏览器会打开 Claude 授权页，请切换到【另一个】Claude 账号登录"))"
        echo "\(L("   (switch accounts in the browser first if needed) and approve.",
                  "   （如果浏览器里登录的是当前账号，请先退出或换个浏览器/无痕窗口）并授权。"))"
        echo "\(L("2. The token (valid for about a year) is picked up automatically.",
                  "2. 生成的 Token（有效期约一年）会被自动填回 Claude Switcher。"))"
        echo ""
        if ! command -v claude >/dev/null 2>&1; then
          echo "\(L("Claude Code CLI not found. Install it first:", "没有找到 claude 命令，请先安装 Claude Code："))"
          echo "  curl -fsSL https://claude.ai/install.sh | bash"
          exit 1
        fi
        umask 077
        /usr/bin/script -q \(q) claude setup-token
        echo ""
        echo "\(L("Done — you can close this window.", "完成，可以关闭这个窗口了。"))"
        """
        do {
            try TerminalRunner.run(script: script, name: "setup-token")
            state = .waiting
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let logURL { try? FileManager.default.removeItem(at: logURL) }
    }

    private func poll() {
        guard let logURL else { return }
        if Date().timeIntervalSince(startedAt) > 15 * 60 {
            stop()
            state = .failed(L("Timed out waiting for the token.", "等待 Token 超时。"))
            return
        }
        guard let data = try? Data(contentsOf: logURL),
              let token = Self.extractToken(from: String(decoding: data, as: UTF8.self)) else { return }
        // Accept only once two reads agree, so a half-written line is not taken.
        if token == lastSeen {
            stop()
            state = .found(token)
        } else {
            lastSeen = token
        }
    }

    /// Finds `sk-ant-oat…` in terminal output, ignoring colour codes and line wraps.
    nonisolated static func extractToken(from raw: String) -> String? {
        let text = raw
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}[@-_]", with: "", options: .regularExpression)
        guard let start = text.range(of: "sk-ant-oat", options: .backwards) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let isTokenChunk = { (s: Substring) in !s.isEmpty && s.unicodeScalars.allSatisfy { allowed.contains($0) } }
        // A TUI may hard-wrap the token; a following line counts as a
        // continuation only if it is made of token characters alone.
        let edge = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│┃║|"))
        let lines = text[start.lowerBound...]
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let head = first.prefix { $0.unicodeScalars.allSatisfy { allowed.contains($0) } }
        var token = String(head)
        if head.count == first.trimmingCharacters(in: edge).count {
            for line in lines.dropFirst() {
                let chunk = Substring(line.trimmingCharacters(in: edge))
                guard isTokenChunk(chunk) else { break }
                token += chunk
            }
        }
        return token.count >= 60 ? token : nil
    }
}

enum ModelFetcher {
    /// Lists model ids from `/v1/models`; doubles as a connection test.
    static func fetch(for p: Profile) async throws -> [String] {
        let base: String
        switch p.kind {
        case .gateway:
            var b = p.normalizedBaseURL
            if b.hasSuffix("/v1") { b.removeLast(3) }
            base = b
        case .apiKey, .accountToken:
            base = "https://api.anthropic.com"
        }
        guard let url = URL(string: base + "/v1/models?limit=1000") else {
            throw SwitchError(message: L("Invalid base URL.", "Base URL 无效。"))
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let key = p.trimmedKey
        if key.hasPrefix("sk-ant-oat") {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        } else if p.kind == .gateway && p.authScheme == .bearer {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            throw SwitchError(message: "HTTP \(status): \(body)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else {
            throw SwitchError(message: L("Unexpected response.", "返回格式无法识别。"))
        }
        return list.compactMap { $0["id"] as? String }
    }
}

enum Updater {
    static let repo = "naifuliang/claude-switcher"
    static var installCommand: String {
        "curl -fsSL https://raw.githubusercontent.com/\(repo)/main/install.sh | sh"
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static func latestTag() async throws -> String {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=1")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let tag = list.first?["tag_name"] as? String else {
            throw SwitchError(message: L("No release found.", "没有找到发布版本。"))
        }
        return tag
    }

    static func isNewer(_ tag: String, than current: String) -> Bool {
        let strip = { (s: String) in s.hasPrefix("v") ? String(s.dropFirst()) : s }
        return strip(tag).compare(strip(current), options: .numeric) == .orderedDescending
    }

    /// Runs the one-line installer in Terminal; it quits and relaunches this app.
    static func runInstaller() throws {
        try TerminalRunner.run(script: "CLAUDE_SWITCHER_INSTALL_CONFIRM=1 /bin/sh -c \(TerminalRunner.shellQuote(installCommand))\n",
                               name: "update")
    }
}

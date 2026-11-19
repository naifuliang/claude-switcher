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

/// Drives `claude setup-token` and extracts its completed token output.
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
    private var process: Process?
    private var input: Pipe?

    func start(inTerminal: Bool = false, cliExecutable: String = "claude") {
        stop()
        let log = AppPaths.tmp.appendingPathComponent("setup-token-\(UUID().uuidString).log")
        logURL = log
        lastSeen = nil
        startedAt = Date()
        guard let executable = Self.resolveCLI(cliExecutable) else {
            state = .failed(L("Claude Code CLI was not found. Install it or check its installation path.", "未找到 Claude Code CLI，请安装或检查安装路径。"))
            return
        }
        let cli = TerminalRunner.shellQuote(executable)
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
        if ! test -x \(cli); then
          echo "\(L("Claude Code CLI not found. Install it first:", "没有找到 claude 命令，请先安装 Claude Code："))"
          echo "  curl -fsSL https://claude.ai/install.sh | bash"
          exit 1
        fi
        umask 077
        /usr/bin/script -qF \(q) \(cli) setup-token
        echo ""
        echo "\(L("Done — you can close this window.", "完成，可以关闭这个窗口了。"))"
        """
        do {
            if inTerminal {
                try TerminalRunner.run(script: script, name: "setup-token")
            } else {
                try FileManager.default.createDirectory(at: AppPaths.tmp, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileIO.writePrivate(Data(), to: log)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
                process.arguments = ["-qF", log.path, "/bin/sh", "-c",
                    "/bin/stty rows 40 cols 200; exec " + cli + " setup-token"]
                var environment = ProcessInfo.processInfo.environment
                environment["TERM"] = "xterm-256color"
                process.environment = environment
                let input = Pipe()
                process.standardInput = input
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { [weak self] endedProcess in
                    let exitStatus = endedProcess.terminationStatus
                    Task { @MainActor in
                        guard let self, self.process === endedProcess, self.state == .waiting else { return }
                        self.poll()
                        if let data = try? Data(contentsOf: log),
                           let token = Self.extractToken(from: String(decoding: data, as: UTF8.self)) {
                            self.stop()
                            self.state = .found(token)
                        } else if self.state == .waiting {
                            let raw = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                            let details = Self.failureSummary(raw)
                            self.stop()
                            self.state = .failed(L("Claude Code login exited (status \(exitStatus)) before returning a complete token. Try again or use terminal login.", "Claude Code 登录已退出（状态 \(exitStatus)），未返回完整 Token。请重试或使用备用终端登录。") + "\n" + details)
                        }
                    }
                }
                self.process = process
                self.input = input
                try process.run()
            }
            state = .waiting
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // Finder launches do not inherit an interactive shell's PATH.
    nonisolated static func resolveCLI(_ requested: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                       path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> String? {
        let candidates: [String]
        if requested.contains("/") {
            candidates = [requested]
        } else {
            candidates = [home.appendingPathComponent(".local/bin/" + requested).path,
                          "/opt/homebrew/bin/" + requested, "/usr/local/bin/" + requested]
                + path.split(separator: ":").map { String($0) + "/" + requested }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Only structural diagnostics; never include token or OAuth URLs in errors.
    nonisolated static func failureSummary(_ output: String) -> String {
        if output.contains("sk-ant-oat") {
            return L("Token output was received, but could not be read completely. Browser sign-in may have succeeded.",
                     "已收到凭据输出，但未能完整读取；网页登录可能已经成功。")
        }
        if output.contains("Long-lived authentication token created") {
            return L("CLI reported success, but its token output was missing.", "CLI 报告成功，但未捕获到凭据内容。")
        }
        return L("No token output was captured; this does not establish that the account is invalid.",
                 "未捕获到凭据输出，这不代表账号无效。")
    }

    func submitAuthorizationCode(_ code: String) {
        guard state == .waiting, let input else { return }
        let line = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func stop() {
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        try? input?.fileHandleForWriting.close()
        input = nil
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
        // Do not accept a live terminal prefix. Wait for the complete instruction
        // that follows the token, even when the TUI wraps "Store" onto its own line.
        let tail = String(text[start.lowerBound...])
        guard let end = tail.range(of: #"Store[\s│┃║|]+this[\s│┃║|]+token[\s│┃║|]+securely\."#,
                                   options: .regularExpression) else { return nil }
        let ignored = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "│┃║|"))
        let token = String(String.UnicodeScalarView(tail[..<end.lowerBound].unicodeScalars.filter { !ignored.contains($0) }))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard token.hasPrefix("sk-ant-oat"), token.count >= 60,
              token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return token
    }
}

enum ModelFetcher {
    static func errorMessage(status: Int, data: Data, profile: Profile) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        var detail = (error?["message"] as? String) ?? (object?["message"] as? String)
            ?? L("The server rejected the request.", "服务器拒绝了请求。")
        if !profile.trimmedKey.isEmpty {
            detail = detail.replacingOccurrences(of: profile.trimmedKey, with: "[redacted]")
        }
        var message = "HTTP \(status): \(detail)"
        if status == 401 {
            if profile.kind == .accountToken {
                message += "\n" + L("Authentication failed. The token may be expired, revoked, incomplete, or unsupported by this endpoint. Sign in again to obtain a new token. Leaving Models empty does not fix authentication.",
                    "认证失败。Token 可能已过期、被撤销、不完整，或不被此接口接受。请重新登录生成 Token；模型留空并不能解决认证问题。")
            } else {
                message += "\n" + L("Check the key and the endpoint's required authentication method.", "请检查 Key 以及接口要求的认证方式。")
            }
        } else if status == 403 {
            message += "\n" + L("This credential may not have permission to list models. Check its permissions with the provider.", "此凭据可能没有读取模型列表的权限，请向服务商确认。")
        }
        return message
    }

    /// Lists model ids from `/v1/models`; doubles as a connection test.
    static func request(for p: Profile) throws -> URLRequest {
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
        if p.kind == .gateway {
            if p.authScheme == .bearer {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            } else {
                req.setValue(key, forHTTPHeaderField: "x-api-key")
            }
        } else if key.hasPrefix("sk-ant-oat") {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        } else {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        return req
    }

    static func fetch(for p: Profile, session: URLSession = .shared) async throws -> [String] {
        let req = try request(for: p)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SwitchError(message: errorMessage(status: status, data: data, profile: p))
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
        // Resolve the ~/.local/bin symlink so the CLI finds the app bundle too.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = Bundle(url: exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        return (bundle?.infoDictionary ?? Bundle.main.infoDictionary)?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static func latestTag() async throws -> String {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw SwitchError(message: L("Could not check for updates. Try again later.", "暂时无法检查更新，请稍后重试。"))
        }
        return try releaseTag(from: data)
    }

    static func releaseTag(from data: Data) throws -> String {
        guard let release = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              release["draft"] as? Bool != true, release["prerelease"] as? Bool != true,
              let tag = release["tag_name"] as? String,
              tag.range(of: #"^v?[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            throw SwitchError(message: L("No release found.", "没有找到发布版本。"))
        }
        return tag
    }

    static func isNewer(_ tag: String, than current: String) -> Bool {
        let strip = { (s: String) in s.hasPrefix("v") ? String(s.dropFirst()) : s }
        return strip(tag).compare(strip(current), options: .numeric) == .orderedDescending
    }

    /// Runs the one-line installer in Terminal; it quits and relaunches this app.
    static func runInstaller(tag: String) throws {
        try TerminalRunner.run(script: "CLAUDE_SWITCHER_RELEASE_TAG=\(TerminalRunner.shellQuote(tag)) CLAUDE_SWITCHER_INSTALL_CONFIRM=1 /bin/sh -c \(TerminalRunner.shellQuote(installCommand))\n",
                               name: "update")
    }
}

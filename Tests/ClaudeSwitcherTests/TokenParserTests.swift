import XCTest
@testable import ClaudeSwitcher

final class TokenParserTests: XCTestCase {
    let token = "sk-ant-oat01-" + String(repeating: "x", count: 95)
    let instruction = "Store this token securely. You won't be able to see it again."

    func testStoreOnSeparateLineIsNeverIncluded() {
        XCTAssertEqual(TokenLogin.extractToken(from: token + "\nStore\nthis token securely. You won't be able to see it again."), token)
    }
    func testANSIAndWrappedToken() {
        let raw = "\\u{1B}[33m" + String(token.prefix(70)) + "\r\n" + String(token.dropFirst(70)) + "\\u{1B}[0m\n" + instruction
        XCTAssertEqual(TokenLogin.extractToken(from: raw.replacingOccurrences(of: "\\u{1B}", with: "\u{1B}")), token)
    }
    func testIncompleteTerminalOutputIsNotAccepted() {
        XCTAssertNil(TokenLogin.extractToken(from: token + "\nStore"))
        XCTAssertNil(TokenLogin.extractToken(from: String(token.prefix(70))))
    }
    func testInlineInstructionAndRepeatedTerminalRenders() {
        XCTAssertEqual(TokenLogin.extractToken(from: token + "\n" + instruction + "\n" + token + instruction), token)
    }
    func testLegitimateTokenSuffixStoreIsPreserved() {
        let valid = String(token.dropLast(5)) + "Store"
        XCTAssertEqual(TokenLogin.extractToken(from: valid + "\n" + instruction), valid)
        var p = Profile(name: "test", kind: .accountToken)
        p.apiKey = valid
        XCTAssertNil(TokenRepair.candidate(p))
        p.apiKey = token + "Store"
        XCTAssertEqual(TokenRepair.candidate(p), token)
        p.kind = .apiKey
        XCTAssertNil(TokenRepair.candidate(p))
    }
    func testFinderEnvironmentResolvesNativeCLIWithoutShellPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        XCTAssertEqual(TokenLogin.resolveCLI("claude", home: root, path: "/usr/bin:/bin"), binary.path)
        XCTAssertNil(TokenLogin.resolveCLI(root.appendingPathComponent("missing").path))
    }

    @MainActor
    func testBackgroundLoginCapturesTokenWithoutTerminalCommandFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prior = ProcessInfo.processInfo.environment["CLAUDE_SWITCHER_HOME"]
        setenv("CLAUDE_SWITCHER_HOME", root.path, 1)
        defer {
            if let prior { setenv("CLAUDE_SWITCHER_HOME", prior, 1) } else { unsetenv("CLAUDE_SWITCHER_HOME") }
            try? FileManager.default.removeItem(at: root)
        }
        let fixture = root.appendingPathComponent("fake-claude")
        try ("#!/bin/sh\nprintf '%s\\n' '" + token + "' 'Store' 'this token securely. You will not see it again.'\nread ignored\n").write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let login = TokenLogin()
        login.start(cliExecutable: fixture.path)
        for _ in 0..<50 {
            if login.state != .waiting { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(login.state, .found(token))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.tmp.appendingPathComponent("setup-token.command").path))
        login.stop()
    }

}

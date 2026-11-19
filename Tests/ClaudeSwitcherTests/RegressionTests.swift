import XCTest
@testable import ClaudeSwitcher

final class RegressionTests: XCTestCase {
    func testStableReleaseParsing() throws {
        XCTAssertEqual(try Updater.releaseTag(from: Data(#"{"tag_name":"v0.1.3","draft":false,"prerelease":false}"#.utf8)), "v0.1.3")
        for json in [#"{"tag_name":"v0.1.3","draft":true}"#, #"{"tag_name":"v0.1.3","prerelease":true}"#, #"{"tag_name":"bad-tag"}"#, #"{"message":"rate limit"}"#] {
            XCTAssertThrowsError(try Updater.releaseTag(from: Data(json.utf8)))
        }
    }

    func testVersionComparison() {
        XCTAssertTrue(Updater.isNewer("v0.1.10", than: "0.1.9"))
        XCTAssertFalse(Updater.isNewer("v0.1.3", than: "0.1.3"))
        XCTAssertFalse(Updater.isNewer("v0.1.2", than: "0.1.3"))
    }

    func testGatewayHonorsSelectedHeaderEvenForOAuthLookingKey() throws {
        var p = Profile(name: "test", kind: .gateway)
        p.baseURL = "https://example.invalid/v1/"
        p.apiKey = "sk-ant-oat-test"
        p.authScheme = .xApiKey
        let request = try ModelFetcher.request(for: p)
        XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/v1/models?limit=1000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), p.apiKey)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-beta"))
        p.authScheme = .bearer
        XCTAssertEqual(try ModelFetcher.request(for: p).value(forHTTPHeaderField: "Authorization"), "Bearer " + p.apiKey)
    }

    func testOfficialAuthenticationHeaders() throws {
        var p = Profile(name: "test", kind: .accountToken)
        p.apiKey = "sk-ant-oat-test"
        let oauth = try ModelFetcher.request(for: p)
        XCTAssertEqual(oauth.value(forHTTPHeaderField: "Authorization"), "Bearer " + p.apiKey)
        XCTAssertNil(oauth.value(forHTTPHeaderField: "x-api-key"))
        p.kind = .apiKey
        p.apiKey = "sk-ant-api-test"
        XCTAssertEqual(try ModelFetcher.request(for: p).value(forHTTPHeaderField: "x-api-key"), p.apiKey)
    }

    func testAuthenticationErrorPreservesMessageAndRedactsCredential() {
        var p = Profile(name: "test", kind: .accountToken)
        p.apiKey = "secret-token"
        let data = Data(#"{"error":{"type":"authentication_error","message":"OAuth access token is invalid: secret-token"}}"#.utf8)
        let message = ModelFetcher.errorMessage(status: 401, data: data, profile: p)
        XCTAssertTrue(message.contains("OAuth access token is invalid"))
        XCTAssertTrue(message.contains("HTTP 401"))
        XCTAssertFalse(message.contains(p.apiKey))
        XCTAssertTrue(message.contains("[redacted]"))
    }

    func testNonJSONErrorDoesNotExposeResponseBody() {
        let p = Profile(name: "test", kind: .apiKey)
        let message = ModelFetcher.errorMessage(status: 502, data: Data("<html>private diagnostic</html>".utf8), profile: p)
        XCTAssertTrue(message.contains("502"))
        XCTAssertFalse(message.contains("private diagnostic"))
    }
    func testSessionScanSeparatesModesAndPreservesFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data(#"{"sessionId":"same-id","title":"Old work","cwd":"/project","isArchived":true}"#.utf8)
        for mode in ["Claude", "Claude-3p"] {
            let folder = root.appendingPathComponent(mode + "/claude-code-sessions/org/account")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try original.write(to: folder.appendingPathComponent("local_session.json"))
            try Data(#"{"scheduledTasks":[]}"#.utf8).write(to: folder.appendingPathComponent("scheduled-tasks.json"))
        }
        let badFile = root.appendingPathComponent("Claude/claude-code-sessions/broken.json")
        try Data("not json".utf8).write(to: badFile)
        let result = SessionLibrary.scan(support: root)
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(Set(result.sessions.map(\.id)).count, 2)
        XCTAssertEqual(Set(result.sessions.map(\.mode)), ["Claude", "Claude-3p"])
        XCTAssertEqual(result.unreadableFiles, 1)
        for session in result.sessions {
            XCTAssertTrue(session.archived)
            XCTAssertEqual(session.workingDirectory, "/project")
            XCTAssertEqual(try Data(contentsOf: session.file), original)
        }
    }

}

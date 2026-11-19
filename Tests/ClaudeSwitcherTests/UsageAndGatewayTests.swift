import XCTest
@testable import ClaudeSwitcher

final class UsageAndGatewayTests: XCTestCase {
    func testUsageParsesPercentAndBothResetFormats() throws {
        let data = Data(#"{"five_hour":{"utilization":42.5,"resets_at":"2026-11-20T01:00:00.000Z"},"seven_day":{"utilization":100,"resets_at":1795136400},"seven_day_opus":null}"#.utf8)
        let snapshot = try UsageFetcher.parse(data)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 42.5)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertNotNil(snapshot.windows[1].resetsAt)
    }
    func testUsageRejectsUnknownOrInvalidFiguresInsteadOfShowingZero() {
        for json in ["{}", #"{"five_hour":{"utilization":true}}"#, #"{"five_hour":{"utilization":-1}}"#, #"{"five_hour":{"utilization":"50"}}"#] {
            XCTAssertThrowsError(try UsageFetcher.parse(Data(json.utf8)))
        }
    }
    func testRetryAfter() {
        XCTAssertEqual(UsageFetcher.retryDelay("120"), 120)
        XCTAssertEqual(UsageFetcher.retryDelay("Thu, 19 Nov 2026 00:00:00 GMT", now: Date(timeIntervalSince1970: 1795046280)), 120)
        XCTAssertNil(UsageFetcher.retryDelay("invalid"))
    }
    func testHTTPWaitsForWholeBody() throws {
        let head = "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n"
        XCTAssertNil(try GatewayHTTP.parse(Data((head + "{").utf8)))
        let request = try XCTUnwrap(GatewayHTTP.parse(Data((head + "{}").utf8)))
        XCTAssertEqual(request.body, Data("{}".utf8))
    }
    func testHTTPRejectsAmbiguousOrOversizeRequests() {
        for request in [
            "POST /v1/messages HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
            "POST /v1/messages HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\nx",
            "POST /v1/messages HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n",
            "GET /v1/models HTTP/1.1\r\n\r\nextra"] {
            XCTAssertThrowsError(try GatewayHTTP.parse(Data(request.utf8)))
        }
    }
    func testGatewayReplacesLocalCredentialAndDropsCookies() throws {
        var profile = Profile(name: "provider", kind: .apiKey)
        profile.apiKey = "upstream-secret"
        let request = GatewayRequest(method: "POST", target: "/v1/messages", headers: ["authorization":"Bearer local-secret", "cookie":"private", "content-type":"application/json"], body: Data("{}".utf8))
        let outgoing = try GatewayHTTP.upstream(request, profile: profile, secret: "local-secret")
        XCTAssertEqual(outgoing.value(forHTTPHeaderField: "x-api-key"), "upstream-secret")
        XCTAssertNil(outgoing.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(outgoing.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(outgoing.url?.host, "api.anthropic.com")
    }
    func testGatewayOAuthAndAuthorizationFailures() throws {
        var profile = Profile(name: "provider", kind: .accountToken)
        profile.apiKey = "sk-ant-oat-fixture"
        let request = GatewayRequest(method: "GET", target: "/v1/models", headers: ["x-api-key":"local"], body: Data())
        let outgoing = try GatewayHTTP.upstream(request, profile: profile, secret: "local")
        XCTAssertEqual(outgoing.value(forHTTPHeaderField: "Authorization"), "Bearer " + profile.apiKey)
        XCTAssertTrue(outgoing.value(forHTTPHeaderField: "anthropic-beta")?.contains("oauth-2025-04-20") == true)
        XCTAssertThrowsError(try GatewayHTTP.upstream(request, profile: profile, secret: "wrong"))
        XCTAssertThrowsError(try GatewayHTTP.upstream(GatewayRequest(method: "GET", target: "/admin", headers: ["x-api-key":"local"], body: Data()), profile: profile, secret: "local"))
    }
}

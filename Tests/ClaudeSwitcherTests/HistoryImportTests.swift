import XCTest
@testable import ClaudeSwitcher

final class HistoryImportTests: XCTestCase {
    func testPreparationBacksUpAndPreservesCredentialsAndPolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let library = root.appendingPathComponent("configLibrary")
        try FileIO.writeJSON(["deploymentMode":"3p"], to: root.appendingPathComponent("claude_desktop_config.json"))
        try FileIO.writeJSON(["appliedId":id], to: library.appendingPathComponent("_meta.json"))
        let file = library.appendingPathComponent(id + ".json")
        try FileIO.writeJSON(["inferenceAnthropicApiKey":"fixture", "claudeAiImport":["allowedOrganizationUuids":["allowed-org"],"enabled":false]], to: file)
        let original = try Data(contentsOf: file)
        let backup = try HistoryImport.prepare(root: root, backupRoot: root.appendingPathComponent("backups"))
        XCTAssertEqual(try Data(contentsOf: backup), original)
        let result = FileIO.readJSON(file)
        XCTAssertEqual(result["inferenceAnthropicApiKey"] as? String, "fixture")
        let options = try XCTUnwrap(result["claudeAiImport"] as? [String: Any])
        XCTAssertEqual(options["enabled"] as? Bool, true)
        XCTAssertEqual(options["exportEnabled"] as? Bool, true)
        XCTAssertEqual(options["allowedOrganizationUuids"] as? [String], ["allowed-org"])
    }
    func testPreparationRefusesUnsafeActiveID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileIO.writeJSON(["deploymentMode":"3p"], to: root.appendingPathComponent("claude_desktop_config.json"))
        try FileIO.writeJSON(["appliedId":"../../outside"], to: root.appendingPathComponent("configLibrary/_meta.json"))
        XCTAssertThrowsError(try HistoryImport.prepare(root: root, backupRoot: root.appendingPathComponent("backups")))
    }
}

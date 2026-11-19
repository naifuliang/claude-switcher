import Foundation

/// Uses Claude Desktop's own import implementation rather than rewriting its private
/// transcript, group or identity databases. Only the local feature setting is changed.
enum HistoryImport {
    static func prepare(root: URL = ClaudeDesktop.root, backupRoot: URL = AppPaths.support.appendingPathComponent("backups")) throws -> URL {
        let configURL = root.appendingPathComponent("claude_desktop_config.json")
        let config = FileIO.readJSON(configURL)
        guard config["deploymentMode"] as? String == "3p" else {
            throw SwitchError(message: L("In official mode, use Claude Settings → Import & export. This app only enables the local third-party deployment's import setting.", "官方模式请直接使用 Claude 设置中的「导入与导出」。本工具只为本地第三方模式启用导入设置。"))
        }
        let library = root.appendingPathComponent("configLibrary")
        let meta = FileIO.readJSON(library.appendingPathComponent("_meta.json"))
        guard let id = meta["appliedId"] as? String, UUID(uuidString: id) != nil else {
            throw SwitchError(message: L("No valid active configuration was found.", "未找到有效的当前配置。"))
        }
        let entryURL = library.appendingPathComponent(id + ".json")
        let original = try Data(contentsOf: entryURL)
        guard var entry = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw SwitchError(message: L("The active configuration cannot be read.", "无法读取当前配置。"))
        }
        var options = entry["claudeAiImport"] as? [String: Any] ?? [:]
        // Do not broaden an existing organization allowlist or alter its remote endpoint.
        options["enabled"] = true
        options["exportEnabled"] = true
        entry["claudeAiImport"] = options
        let backup = backupRoot.appendingPathComponent("history-import-" + UUID().uuidString).appendingPathComponent(id + ".json")
        try FileIO.writePrivate(original, to: backup)
        try FileIO.writeJSON(entry, to: entryURL)
        return backup
    }
}

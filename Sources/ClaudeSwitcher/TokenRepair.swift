import Foundation

/// Migration for the confirmed v0.1.x bug: a 108-character token was saved with
/// the instruction word "Store" appended. Never trim arbitrary credential suffixes.
enum TokenRepair {
    static func candidate(_ profile: Profile) -> String? {
        let token = profile.trimmedKey
        guard profile.kind == .accountToken, token.count == 113,
              token.hasPrefix("sk-ant-oat01-"), token.hasSuffix("Store"),
              token.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        return String(token.dropLast(5))
    }

    static func repair() throws -> Int {
        var profiles = ProfileStore.load()
        let affected = profiles.indices.filter { candidate(profiles[$0]) != nil }
        guard !affected.isEmpty else { return 0 }
        let directory = AppPaths.support.appendingPathComponent("backups/token-parser-" + UUID().uuidString)
        // Back up exact original bytes before changing any credential or Desktop entry.
        try FileIO.writePrivate(Data(contentsOf: AppPaths.profiles), to: directory.appendingPathComponent("profiles.json"))
        for index in affected {
            let entry = ClaudeDesktop.entryURL(profiles[index].claudeID)
            if FileManager.default.fileExists(atPath: entry.path) {
                try FileIO.writePrivate(Data(contentsOf: entry), to: directory.appendingPathComponent(entry.lastPathComponent))
            }
            profiles[index].apiKey = candidate(profiles[index])!
        }
        try ProfileStore.save(profiles)
        for index in affected { try ClaudeDesktop.sync(profiles[index], profiles: profiles) }
        return affected.count
    }
}

import Foundation

enum ProfileKind: String, Codable, CaseIterable, Identifiable {
    /// Any Anthropic-compatible endpoint (proxy, gateway, third-party provider).
    case gateway
    /// A Claude Platform API key (sk-ant-api…), billed per token.
    case apiKey
    /// A long-lived OAuth token from `claude setup-token` (sk-ant-oat…),
    /// which spends another Claude account's subscription quota.
    case accountToken

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gateway: return L("Third-party endpoint", "第三方 Endpoint")
        case .apiKey: return L("Anthropic API key", "Anthropic API Key")
        case .accountToken: return L("Another Claude account", "另一个 Claude 账号")
        }
    }

    var symbol: String {
        switch self {
        case .gateway: return "server.rack"
        case .apiKey: return "key.horizontal"
        case .accountToken: return "person.2"
        }
    }
}

enum AuthScheme: String, Codable, CaseIterable, Identifiable {
    case bearer
    case xApiKey = "x-api-key"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bearer: return "Authorization: Bearer"
        case .xApiKey: return "x-api-key"
        }
    }
}

struct Profile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var kind: ProfileKind
    var apiKey: String = ""
    var baseURL: String = ""
    var authScheme: AuthScheme = .bearer
    var models: [String] = []
    var tokenCreatedAt: Date?

    init(name: String, kind: ProfileKind) {
        self.name = name
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        kind = try c.decodeIfPresent(ProfileKind.self, forKey: .kind) ?? .gateway
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        authScheme = try c.decodeIfPresent(AuthScheme.self, forKey: .authScheme) ?? .bearer
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        tokenCreatedAt = try c.decodeIfPresent(Date.self, forKey: .tokenCreatedAt)
    }

    /// Claude Desktop's config-library id: a lowercase UUID.
    var claudeID: String { id.uuidString.lowercased() }

    var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    var normalizedBaseURL: String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Returns a human-readable problem, or nil when the profile can be applied.
    var validationError: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return L("Name is empty.", "名称不能为空。") }
        if trimmedKey.isEmpty {
            return kind == .accountToken
                ? L("No token yet — sign in with the other account first.", "还没有 Token —— 请先用另一个账号登录生成。")
                : L("API key is empty.", "API Key 不能为空。")
        }
        switch kind {
        case .gateway:
            guard let url = URL(string: normalizedBaseURL), let scheme = url.scheme,
                  ["http", "https"].contains(scheme), url.host != nil else {
                return L("Base URL must be a full http(s) URL.", "Base URL 必须是完整的 http(s) 地址。")
            }
            if models.isEmpty { return L("Add at least one model.", "至少填写一个模型。") }
        case .accountToken:
            if !trimmedKey.hasPrefix("sk-ant-oat") {
                return L("Account tokens start with sk-ant-oat.", "账号 Token 应以 sk-ant-oat 开头。")
            }
        case .apiKey:
            break
        }
        return nil
    }

    /// The flat keys Claude Desktop reads from a config-library entry.
    var claudeEntry: [String: Any] {
        var d: [String: Any] = [:]
        switch kind {
        case .gateway:
            d["inferenceProvider"] = "gateway"
            d["inferenceGatewayBaseUrl"] = normalizedBaseURL
            d["inferenceGatewayApiKey"] = trimmedKey
            d["inferenceGatewayAuthScheme"] = authScheme.rawValue
        case .apiKey, .accountToken:
            d["inferenceProvider"] = "anthropic"
            d["inferenceAnthropicApiKey"] = trimmedKey
        }
        if !models.isEmpty { d["inferenceModels"] = models }
        return d
    }
}

enum AppPaths {
    static var support: URL {
        if let o = ProcessInfo.processInfo.environment["CLAUDE_SWITCHER_HOME"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeSwitcher", isDirectory: true)
    }
    static var profiles: URL { support.appendingPathComponent("profiles.json") }
    static var tmp: URL { support.appendingPathComponent("tmp", isDirectory: true) }
}

enum ProfileStore {
    static func load() -> [Profile] {
        guard let data = try? Data(contentsOf: AppPaths.profiles) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Profile].self, from: data)) ?? []
    }

    static func save(_ profiles: [Profile]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try FileIO.writePrivate(try enc.encode(profiles), to: AppPaths.profiles)
    }
}

enum FileIO {
    /// Writes atomically with 0600 permissions (the files hold API keys).
    static func writePrivate(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func readJSON(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static func writeJSON(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try writePrivate(data, to: url)
    }
}

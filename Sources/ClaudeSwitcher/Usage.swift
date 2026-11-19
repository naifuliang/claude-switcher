import Foundation

struct UsageWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
}

struct UsageSnapshot {
    let windows: [UsageWindow]
    let fetchedAt: Date
}

struct UsageFetchError: LocalizedError {
    let status: Int
    let retryAfter: TimeInterval?
    let message: String
    var errorDescription: String? { message }
}

enum UsageFetcher {
    // Same read-only endpoint used by the installed Claude Desktop client.
    // This is not a universal gateway/billing API; other profile kinds are excluded.
    static func fetch(for profile: Profile, session: URLSession = .shared) async throws -> UsageSnapshot {
        guard profile.kind == .accountToken, !profile.trimmedKey.isEmpty else {
            throw UsageFetchError(status: 0, retryAfter: nil, message: L("Usage lookup requires a Claude account token. API and gateway billing must be checked with the provider.", "订阅用量查询需要 Claude 账号 Token；API 与第三方接口账单请向服务商查询。"))
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(profile.trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw SwitchError(message: L("No server response.", "没有收到服务端响应。"))
        }
        guard response.statusCode == 200 else {
            let delay = retryDelay(response.value(forHTTPHeaderField: "Retry-After"))
            let message: String
            switch response.statusCode {
            case 401: message = L("This token was rejected (401). The account is still saved. Sign in again if the problem persists.", "此 Token 被拒绝（401），已保存的账号仍保留。如果持续出现，请重新登录。")
            case 403: message = L("This token cannot read subscription usage (403). It may lack the required permission; this does not prove inference is unavailable.", "此 Token 无权读取订阅用量（403），可能缺少所需权限；这不等于模型调用一定不可用。")
            case 429: message = L("Usage checks are temporarily rate limited (429). Wait before refreshing; this is not a sign-out.", "用量查询暂时限流（429），请等待后再刷新；这不代表账号退出登录。")
            default: message = L("Usage is temporarily unavailable (HTTP \(response.statusCode)).", "暂时无法读取用量（HTTP \(response.statusCode)）。")
            }
            throw UsageFetchError(status: response.statusCode, retryAfter: response.statusCode == 429 ? max(delay ?? 60, 60) : delay, message: message)
        }
        return try parse(data)
    }

    static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwitchError(message: L("Unexpected usage response.", "用量响应格式无法识别。"))
        }
        var windows: [UsageWindow] = []
        func append(id: String, label: String, value: [String: Any]?, percentKey: String = "utilization") {
            guard let value, let number = value[percentKey] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue >= 0 else { return }
            var reset: Date?
            if let string = value["resets_at"] as? String {
                let formatter = ISO8601DateFormatter()
                reset = formatter.date(from: string)
                if reset == nil {
                    formatter.formatOptions.insert(.withFractionalSeconds)
                    reset = formatter.date(from: string)
                }
            } else if let seconds = value["resets_at"] as? NSNumber,
                      CFGetTypeID(seconds) != CFBooleanGetTypeID(), seconds.doubleValue.isFinite {
                reset = Date(timeIntervalSince1970: seconds.doubleValue)
            }
            windows.append(UsageWindow(id: id, label: label, usedPercent: number.doubleValue, resetsAt: reset))
        }
        for (id, label) in [("five_hour", L("5-hour window", "5 小时额度")), ("seven_day", L("Weekly", "每周额度")), ("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
            append(id: id, label: label, value: object[id] as? [String: Any])
        }
        for (index, limit) in ((object["limits"] as? [[String: Any]]) ?? []).enumerated() where limit["kind"] as? String == "weekly_scoped" {
            let scope = limit["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            if let name = model?["display_name"] as? String {
                append(id: "scoped-\(index)", label: name, value: limit, percentKey: "percent")
            }
        }
        guard !windows.isEmpty else {
            throw SwitchError(message: L("The server did not provide readable usage limits. No quota estimate is available.", "服务端没有返回可读的额度数据，无法估算剩余额度。"))
        }
        return UsageSnapshot(windows: windows, fetchedAt: now)
    }
}

import CoreFoundation

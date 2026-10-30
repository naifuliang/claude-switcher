import Foundation

/// Two-language UI: Chinese when the system prefers it, English otherwise.
let prefersChinese: Bool = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

func L(_ en: String, _ zh: String) -> String { prefersChinese ? zh : en }

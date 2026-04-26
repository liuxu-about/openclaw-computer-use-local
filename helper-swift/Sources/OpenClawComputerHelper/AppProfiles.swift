import Foundation

struct AppProfile {
    let id: String
    let names: [String]
    let submitStrategy: String
    let searchSubmitStrategy: String
    let sensitive: Bool
    let notes: [String]
}

final class AppProfileRegistry {
    private let profiles: [AppProfile] = [
        AppProfile(
            id: "browser",
            names: ["safari", "chrome", "google chrome", "firefox", "arc", "edge", "microsoft edge"],
            submitStrategy: "enter",
            searchSubmitStrategy: "enter",
            sensitive: false,
            notes: ["Browser search/address fields usually submit with Enter."]
        ),
        AppProfile(
            id: "finder",
            names: ["finder"],
            submitStrategy: "enter",
            searchSubmitStrategy: "enter",
            sensitive: false,
            notes: ["Finder selection and search can often use Enter."]
        ),
        AppProfile(
            id: "notes",
            names: ["notes", "备忘录"],
            submitStrategy: "enter",
            searchSubmitStrategy: "enter",
            sensitive: false,
            notes: ["Notes text entry should generally stage text without submitting externally."]
        ),
        AppProfile(
            id: "messaging",
            names: ["messages", "telegram", "slack", "discord", "wechat", "whatsapp", "signal", "teams", "信息", "微信"],
            submitStrategy: "auto",
            searchSubmitStrategy: "enter",
            sensitive: true,
            notes: ["Messaging apps require approval before sending external messages."]
        ),
        AppProfile(
            id: "terminal",
            names: ["terminal", "iterm", "iterm2", "warp", "kitty", "终端"],
            submitStrategy: "enter",
            searchSubmitStrategy: "enter",
            sensitive: true,
            notes: ["Shell and terminal apps require approval before command entry or submission."]
        ),
        AppProfile(
            id: "system_settings",
            names: ["system settings", "system preferences", "settings", "系统设置", "系统偏好设置"],
            submitStrategy: "enter",
            searchSubmitStrategy: "enter",
            sensitive: true,
            notes: ["System settings changes require approval."]
        ),
        AppProfile(
            id: "credentials",
            names: ["keychain", "password", "1password", "bitwarden", "lastpass", "钥匙串", "密码"],
            submitStrategy: "enter",
            searchSubmitStrategy: "enter",
            sensitive: true,
            notes: ["Credential and password-manager apps require approval."]
        ),
    ]

    func profile(for appName: String?) -> AppProfile {
        let normalized = normalize(appName ?? "")
        guard !normalized.isEmpty else {
            return defaultProfile()
        }
        if let profile = profiles.first(where: { profile in
            profile.names.contains { name in
                let candidate = normalize(name)
                return normalized == candidate || normalized.contains(candidate) || candidate.contains(normalized)
            }
        }) {
            return profile
        }
        return defaultProfile()
    }

    private func defaultProfile() -> AppProfile {
        AppProfile(
            id: "default",
            names: [],
            submitStrategy: "auto",
            searchSubmitStrategy: "enter",
            sensitive: false,
            notes: ["Default app profile: prefer AX actions and verified one-step plans."]
        )
    }

    private func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

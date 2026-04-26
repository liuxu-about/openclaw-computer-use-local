import Foundation

enum SceneDigest {
    static func compute(_ scene: SceneSnapshot) -> String {
        compute(elements: scene.elements)
    }

    static func compute(elements: [String: AxElementSummary]) -> String {
        let material = elements.values
            .sorted { $0.id < $1.id }
            .prefix(96)
            .map {
                [
                    $0.id,
                    $0.role,
                    normalizedText($0.name),
                    normalizedText($0.value),
                    normalizedText($0.description),
                    $0.focused ? "1" : "0",
                    $0.path,
                ].joined(separator: "|")
            }
            .joined(separator: "||")
        return stableDigest(material)
    }

    private static func normalizedText(_ value: String?) -> String {
        guard let value else {
            return ""
        }
        return value
            .lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func stableDigest(_ input: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16, uppercase: false)
    }
}

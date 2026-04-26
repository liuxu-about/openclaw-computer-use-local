import Foundation

final class ObservationSummarizer {
    private let pressableRoles: Set<String> = [
        "AXButton",
        "AXDisclosureTriangle",
        "AXLink",
        "AXMenuButton",
        "AXMenuItem",
        "AXPopUpButton",
        "AXRadioButton",
        "AXTab",
    ]

    private let textRoles: Set<String> = [
        "AXComboBox",
        "AXSearchField",
        "AXTextArea",
        "AXTextField",
    ]

    private let scrollRoles: Set<String> = [
        "AXBrowser",
        "AXCollection",
        "AXOutline",
        "AXScrollArea",
        "AXTable",
    ]

    private let tableRoles: Set<String> = [
        "AXBrowser",
        "AXOutline",
        "AXTable",
    ]

    private let listRoles: Set<String> = [
        "AXCollection",
        "AXList",
    ]

    private let primaryActionKeywords = [
        "send", "submit", "search", "open", "save", "ok", "done", "continue", "next",
        "reply", "post", "publish", "run", "go",
    ]

    private let dangerousKeywords = [
        "delete", "remove", "erase", "discard", "trash", "archive", "purchase", "buy",
        "pay", "send money", "reset", "sign out", "log out", "shutdown", "restart",
        "terminal", "password", "wallet",
    ]

    func summarize(tree: [AxNode], elements: [String: AxElementSummary]) -> (uiSummary: UISummary, recommendedTargets: [RecommendedTarget]) {
        let ranked = elements.values
            .compactMap(recommendedTarget)
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.id < rhs.id
                }
                return lhs.score > rhs.score
            }

        let textInputs = ranked
            .filter { $0.kind == "text_input" }
            .prefix(12)
            .map(\.id)
        let primaryActions = ranked
            .filter { $0.kind == "primary_action" || $0.kind == "clickable" }
            .prefix(10)
            .map(\.id)
        let scrollRegions = ranked
            .filter { $0.kind == "scroll_region" }
            .prefix(8)
            .map(\.id)
        let dangerousActions = ranked
            .filter { $0.kind == "dangerous_action" }
            .prefix(10)
            .map(\.id)
        let focused = elements.values
            .first(where: { $0.focused })?
            .id
        let collections = collectionSummaries(tree: tree, elements: elements)

        return (
            UISummary(
                focusedElement: focused,
                primaryActions: Array(primaryActions),
                textInputs: Array(textInputs),
                scrollRegions: Array(scrollRegions),
                dangerousActions: Array(dangerousActions),
                tables: collections.tables,
                lists: collections.lists,
                visibleElementCount: elements.count
            ),
            Array(ranked.prefix(40))
        )
    }

    private func collectionSummaries(
        tree: [AxNode],
        elements: [String: AxElementSummary]
    ) -> (tables: [UICollectionSummary], lists: [UICollectionSummary]) {
        var tables: [UICollectionSummary] = []
        var lists: [UICollectionSummary] = []

        func visit(_ node: AxNode) {
            if let summary = collectionSummary(for: node, elements: elements) {
                if tableRoles.contains(summary.role) {
                    tables.append(summary)
                } else if listRoles.contains(summary.role) {
                    lists.append(summary)
                }
            }
            for child in node.children {
                visit(child)
            }
        }

        for root in tree {
            visit(root)
        }

        return (
            Array(tables.sorted { $0.childrenVisible > $1.childrenVisible }.prefix(8)),
            Array(lists.sorted { $0.childrenVisible > $1.childrenVisible }.prefix(8))
        )
    }

    private func collectionSummary(for node: AxNode, elements: [String: AxElementSummary]) -> UICollectionSummary? {
        guard let id = node.id,
              tableRoles.contains(node.role) || listRoles.contains(node.role)
        else {
            return nil
        }

        let rowCount = countDescendants(node, roles: ["AXRow"])
        let columnCount = countDescendants(node, roles: ["AXColumn"])
        let sampleLabels = descendantLabels(node, limit: 10)
        let element = elements[id]
        return UICollectionSummary(
            id: id,
            role: node.role,
            label: compact(node.name ?? node.value ?? node.description),
            rowsVisible: rowCount > 0 ? rowCount : nil,
            columnsVisible: columnCount > 0 ? columnCount : nil,
            childrenVisible: node.children.count,
            sampleLabels: sampleLabels,
            bbox: element?.bbox ?? node.bbox
        )
    }

    private func recommendedTarget(_ element: AxElementSummary) -> RecommendedTarget? {
        guard element.enabled || element.focused else {
            return nil
        }

        let label = normalizedLabel(element)
        let hasPress = element.actions.contains("AXPress")
        let isDangerous = containsAny(label, dangerousKeywords)
        let isText = textRoles.contains(element.role)
        let isPressable = pressableRoles.contains(element.role) || hasPress
        let isScroll = scrollRoles.contains(element.role)

        var kind: String?
        var score = 0.0
        var reason = ""

        if isDangerous && isPressable {
            kind = "dangerous_action"
            score = 120
            reason = "Pressable element with a risky label."
        } else if isText {
            kind = "text_input"
            score = element.focused ? 112 : 96
            reason = element.focused ? "Focused text-capable element." : "Text-capable element."
        } else if isPressable {
            let primaryScore = primaryActionScore(label)
            kind = primaryScore > 0 ? "primary_action" : "clickable"
            score = primaryScore > 0 ? primaryScore : 58
            reason = primaryScore > 0 ? "Pressable element with a likely primary-action label." : "Generic pressable element."
        } else if isScroll {
            kind = "scroll_region"
            score = 52
            reason = "Scrollable region candidate."
        }

        guard let kind else {
            return nil
        }

        if element.focused {
            score += 12
        }
        if element.bbox != nil {
            score += 4
        }
        if label.isEmpty {
            score -= 8
        }

        return RecommendedTarget(
            id: element.id,
            kind: kind,
            role: element.role,
            name: element.name,
            description: element.description,
            score: score,
            reason: reason,
            bbox: element.bbox,
            actions: element.actions
        )
    }

    private func primaryActionScore(_ label: String) -> Double {
        guard !label.isEmpty else {
            return 0
        }
        for keyword in primaryActionKeywords where label.contains(keyword) {
            switch keyword {
            case "send", "submit", "search", "save", "open":
                return 104
            case "ok", "done", "continue", "next":
                return 92
            default:
                return 82
            }
        }
        return 0
    }

    private func containsAny(_ label: String, _ keywords: [String]) -> Bool {
        keywords.contains { keyword in
            label.contains(keyword)
        }
    }

    private func countDescendants(_ node: AxNode, roles: Set<String>) -> Int {
        node.children.reduce(roles.contains(node.role) ? 1 : 0) { total, child in
            total + countDescendants(child, roles: roles)
        }
    }

    private func descendantLabels(_ node: AxNode, limit: Int) -> [String] {
        var labels: [String] = []
        collectDescendantLabels(node, limit: limit, output: &labels)
        return labels
    }

    private func collectDescendantLabels(_ node: AxNode, limit: Int, output: inout [String]) {
        guard output.count < limit else {
            return
        }

        let label = compact(node.name ?? node.value ?? node.description)
        if let label, !output.contains(label) {
            output.append(label)
        }

        for child in node.children {
            guard output.count < limit else {
                return
            }
            collectDescendantLabels(child, limit: limit, output: &output)
        }
    }

    private func compact(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let compacted = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compacted.isEmpty ? nil : String(compacted.prefix(120))
    }

    private func normalizedLabel(_ element: AxElementSummary) -> String {
        [element.name, element.description, element.value]
            .compactMap { $0 }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

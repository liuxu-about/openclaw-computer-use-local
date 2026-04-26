import Foundation

final class ElementFingerprintBuilder {
    func fingerprints(tree: [AxNode], elements: [String: AxElementSummary]) -> [String: ElementFingerprint] {
        var output: [String: ElementFingerprint] = [:]
        for node in tree {
            visit(
                node,
                parentChildren: [],
                childIndex: 0,
                ancestorRoles: [],
                elements: elements,
                output: &output
            )
        }
        return output
    }

    private func visit(
        _ node: AxNode,
        parentChildren: [AxNode],
        childIndex: Int,
        ancestorRoles: [String],
        elements: [String: AxElementSummary],
        output: inout [String: ElementFingerprint]
    ) {
        if let id = node.id, let summary = elements[id] {
            let before = siblingLabels(parentChildren, range: max(0, childIndex - 3)..<childIndex)
            let after = siblingLabels(parentChildren, range: (childIndex + 1)..<min(parentChildren.count, childIndex + 4))
            let descendantText = descendantLabels(node, limit: 8)
            let actionSignature = summary.actions.sorted().joined(separator: "|")
            let normalizedName = normalized(summary.name)
            let normalizedValue = normalized(summary.value)
            let normalizedDescription = normalized(summary.description)
            let fingerprintCore = [
                roleFamily(summary.role),
                normalizedName,
                normalizedValue,
                normalizedDescription,
                actionSignature,
                ancestorRoles.suffix(6).joined(separator: ">"),
                before.joined(separator: "<"),
                after.joined(separator: ">"),
                descendantText.joined(separator: " "),
            ].joined(separator: "|")

            output[id] = ElementFingerprint(
                id: id,
                role: summary.role,
                roleFamily: roleFamily(summary.role),
                normalizedName: normalizedName,
                normalizedValue: normalizedValue,
                normalizedDescription: normalizedDescription,
                actionSignature: actionSignature,
                bboxBucket: bboxBucket(summary.bbox),
                ancestorRoles: Array(ancestorRoles.suffix(8)),
                siblingLabelsBefore: before,
                siblingLabelsAfter: after,
                descendantText: descendantText,
                semanticHash: stableDigest(fingerprintCore)
            )
        }

        let nextAncestors = (ancestorRoles + [node.role]).suffix(10)
        for (index, child) in node.children.enumerated() {
            visit(
                child,
                parentChildren: node.children,
                childIndex: index,
                ancestorRoles: Array(nextAncestors),
                elements: elements,
                output: &output
            )
        }
    }

    private func siblingLabels(_ siblings: [AxNode], range: Range<Int>) -> [String] {
        guard !siblings.isEmpty, !range.isEmpty else {
            return []
        }
        let labels = range
            .filter { siblings.indices.contains($0) }
            .flatMap { descendantLabels(siblings[$0], limit: 2) }
            .filter { !$0.isEmpty }
        return Array(labels.prefix(6))
    }

    private func descendantLabels(_ node: AxNode, limit: Int) -> [String] {
        if limit <= 0 {
            return []
        }

        var labels: [String] = []
        collectDescendantLabels(node, limit: limit, output: &labels)
        return labels
    }

    private func collectDescendantLabels(_ node: AxNode, limit: Int, output: inout [String]) {
        if output.count >= limit {
            return
        }

        let label = normalized(node.name ?? node.value ?? node.description)
        if !label.isEmpty {
            output.append(label)
        }

        for child in node.children {
            if output.count >= limit {
                return
            }
            collectDescendantLabels(child, limit: limit, output: &output)
        }
    }

    private func bboxBucket(_ bbox: [Double]?) -> String? {
        guard let bbox, bbox.count == 4 else {
            return nil
        }
        return bbox
            .map { Int(($0 / 24.0).rounded()) }
            .map(String.init)
            .joined(separator: ",")
    }

    private func normalized(_ value: String?) -> String {
        guard let value else {
            return ""
        }
        return value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(12)
            .joined(separator: " ")
            .lowercased()
    }

    private func roleFamily(_ role: String) -> String {
        switch role {
        case "AXButton", "AXMenuButton", "AXMenuItem", "AXLink", "AXTab", "AXDisclosureTriangle", "AXPopUpButton":
            return "pressable"
        case "AXTextField", "AXTextArea", "AXComboBox":
            return "text"
        case "AXScrollArea", "AXTable", "AXOutline", "AXList":
            return "scroll_container"
        case "AXRow", "AXCell", "AXGroup":
            return "container"
        default:
            return role
        }
    }

    private func stableDigest(_ input: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16, uppercase: false)
    }
}

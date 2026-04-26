import CoreGraphics
import Foundation
import ImageIO
import Vision

struct OCRTextMatch {
    let text: String
    let confidence: Float
    let boundingBox: CGRect
}

final class OCRTextService {
    private let eventLogger = EventLogger.shared

    func bestMatch(screenshot: ScreenshotArtifact, query: String) -> OCRTextMatch? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let image = loadImage(from: screenshot.path) else {
            eventLogger.log("helper_ocr_failed", payload: [
                "query": query,
                "path": screenshot.path,
                "reason": "image_load_failed",
            ])
            return nil
        }

        do {
            let matches = try recognizeText(in: image)
            let best = matches.max { lhs, rhs in
                score(match: lhs, query: trimmed) < score(match: rhs, query: trimmed)
            }
            if let best {
                eventLogger.log("helper_ocr_match", payload: [
                    "query": query,
                    "path": screenshot.path,
                    "matched_text": best.text,
                    "confidence": best.confidence,
                    "bbox": bboxArray(best.boundingBox),
                ])
            } else {
                eventLogger.log("helper_ocr_no_match", payload: [
                    "query": query,
                    "path": screenshot.path,
                ])
            }
            return best.flatMap { score(match: $0, query: trimmed) > 0 ? $0 : nil }
        } catch {
            eventLogger.log("helper_ocr_failed", payload: [
                "query": query,
                "path": screenshot.path,
                "reason": error.localizedDescription,
            ])
            return nil
        }
    }

    func matches(screenshot: ScreenshotArtifact, limit: Int = 80) -> [OCRTextMatch] {
        guard let image = loadImage(from: screenshot.path) else {
            eventLogger.log("helper_ocr_failed", payload: [
                "path": screenshot.path,
                "reason": "image_load_failed",
            ])
            return []
        }

        do {
            let matches = try recognizeText(in: image)
                .sorted { lhs, rhs in
                    if lhs.confidence == rhs.confidence {
                        return lhs.boundingBox.minY < rhs.boundingBox.minY
                    }
                    return lhs.confidence > rhs.confidence
                }
            eventLogger.log("helper_ocr_scan", payload: [
                "path": screenshot.path,
                "match_count": matches.count,
            ])
            return Array(matches.prefix(max(0, limit)))
        } catch {
            eventLogger.log("helper_ocr_failed", payload: [
                "path": screenshot.path,
                "reason": error.localizedDescription,
            ])
            return []
        }
    }

    func bestMatch(query: String, within targetFrame: CGRect?) -> OCRTextMatch? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let capture = captureDisplayImage(containing: targetFrame.map { CGPoint(x: $0.midX, y: $0.midY) }) else {
            eventLogger.log("helper_ocr_failed", payload: [
                "query": query,
                "reason": "display_capture_failed",
            ])
            return nil
        }

        let image: CGImage
        let offset: CGPoint
        if let targetFrame,
           let cropRect = cropRect(for: targetFrame, within: capture.frame, imageWidth: capture.image.width, imageHeight: capture.image.height),
           let cropped = capture.image.cropping(to: cropRect)
        {
            image = cropped
            offset = CGPoint(x: targetFrame.minX, y: targetFrame.minY)
        } else {
            image = capture.image
            offset = CGPoint(x: capture.frame.minX, y: capture.frame.minY)
        }

        do {
            let matches = try recognizeText(in: image).map { match in
                OCRTextMatch(
                    text: match.text,
                    confidence: match.confidence,
                    boundingBox: match.boundingBox.offsetBy(dx: offset.x, dy: offset.y)
                )
            }
            let best = matches.max { lhs, rhs in
                score(match: lhs, query: trimmed) < score(match: rhs, query: trimmed)
            }
            if let best {
                eventLogger.log("helper_ocr_match", payload: [
                    "query": query,
                    "matched_text": best.text,
                    "confidence": best.confidence,
                    "bbox": bboxArray(best.boundingBox),
                    "capture": "live_display",
                ])
            } else {
                eventLogger.log("helper_ocr_no_match", payload: [
                    "query": query,
                    "capture": "live_display",
                ])
            }
            return best.flatMap { score(match: $0, query: trimmed) > 0 ? $0 : nil }
        } catch {
            eventLogger.log("helper_ocr_failed", payload: [
                "query": query,
                "reason": error.localizedDescription,
                "capture": "live_display",
            ])
            return nil
        }
    }

    private func loadImage(from path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func captureDisplayImage(containing point: CGPoint?) -> (image: CGImage, frame: CGRect)? {
        let displayId = bestDisplayID(containing: point) ?? CGMainDisplayID()
        guard let image = CGDisplayCreateImage(displayId) else {
            return nil
        }
        return (image, CGDisplayBounds(displayId))
    }

    private func bestDisplayID(containing point: CGPoint?) -> CGDirectDisplayID? {
        let maxDisplays: UInt32 = 16
        var active = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(maxDisplays, &active, &count) == .success else {
            return nil
        }
        if let point {
            for displayId in active.prefix(Int(count)) {
                if CGDisplayBounds(displayId).contains(point) {
                    return displayId
                }
            }
        }
        return active.prefix(Int(count)).first
    }

    private func recognizeText(in image: CGImage) throws -> [OCRTextMatch] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let observations = request.results ?? []
        var matches: [OCRTextMatch] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else {
                continue
            }
            let normalized = observation.boundingBox
            let pixelBox = CGRect(
                x: normalized.minX * width,
                y: (1 - normalized.maxY) * height,
                width: normalized.width * width,
                height: normalized.height * height
            ).integral
            matches.append(
                OCRTextMatch(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    boundingBox: pixelBox
                )
            )
        }
        return matches
    }

    private func score(match: OCRTextMatch, query: String) -> Double {
        let queryNorm = normalized(query)
        let textNorm = normalized(match.text)
        guard !queryNorm.isEmpty, !textNorm.isEmpty else {
            return 0
        }

        var score = 0.0
        if textNorm == queryNorm {
            score += 1000
        } else if textNorm.contains(queryNorm) {
            score += 700
        } else if queryNorm.contains(textNorm) {
            score += 500
        } else {
            let overlap = tokenOverlap(lhs: textNorm, rhs: queryNorm)
            guard overlap > 0 else {
                return 0
            }
            score += overlap * 200
        }

        score += Double(match.confidence) * 100
        score += min(Double(match.boundingBox.width * match.boundingBox.height) / 2000.0, 40)
        return score
    }

    private func cropRect(
        for targetFrame: CGRect,
        within displayFrame: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect? {
        let intersection = targetFrame.intersection(displayFrame)
        guard !intersection.isNull, !intersection.isEmpty else {
            return nil
        }

        let scaleX = CGFloat(imageWidth) / max(displayFrame.width, 1)
        let scaleY = CGFloat(imageHeight) / max(displayFrame.height, 1)
        let originX = (intersection.minX - displayFrame.minX) * scaleX
        let originY = (displayFrame.maxY - intersection.maxY) * scaleY
        let width = intersection.width * scaleX
        let height = intersection.height * scaleY
        let rect = CGRect(x: originX, y: originY, width: width, height: height).integral
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else {
            return nil
        }
        return clipped
    }

    private func tokenOverlap(lhs: String, rhs: String) -> Double {
        let left = Set(lhs.split(separator: " ").map(String.init))
        let right = Set(rhs.split(separator: " ").map(String.init))
        guard !left.isEmpty, !right.isEmpty else {
            return 0
        }
        let intersection = left.intersection(right)
        return Double(intersection.count) / Double(max(left.count, right.count))
    }

    private func normalized(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func bboxArray(_ rect: CGRect) -> [Double] {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
    }
}

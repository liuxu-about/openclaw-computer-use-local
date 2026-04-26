import CoreGraphics
import Foundation

struct VisualVerificationSnapshot {
    let digest: String
    let ocrTexts: [String]
}

final class VisualVerifier {
    private let ocrTextService = OCRTextService()

    func snapshot(scene: SceneSnapshot, queryTexts: [String] = []) -> VisualVerificationSnapshot? {
        guard let capture = captureDisplayImage(containing: scene.target?.windowFrame.map { CGPoint(x: $0.midX, y: $0.midY) }) else {
            return nil
        }

        let image: CGImage
        if let targetFrame = scene.target?.windowFrame,
           let cropRect = cropRect(
               for: targetFrame,
               within: capture.frame,
               imageWidth: capture.image.width,
               imageHeight: capture.image.height
           ),
           let cropped = capture.image.cropping(to: cropRect)
        {
            image = cropped
        } else {
            image = capture.image
        }

        let digest = imageDigest(image)
        let ocrTexts = queryTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { query -> String? in
                guard let match = ocrTextService.bestMatch(query: query, within: scene.target?.windowFrame) else {
                    return nil
                }
                return "ocr_match:\(normalized(query)):\(normalized(match.text)):\(String(format: "%.2f", match.confidence))"
            }

        return VisualVerificationSnapshot(digest: digest, ocrTexts: ocrTexts)
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
            for displayId in active.prefix(Int(count)) where CGDisplayBounds(displayId).contains(point) {
                return displayId
            }
        }
        return active.prefix(Int(count)).first
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

    private func imageDigest(_ image: CGImage) -> String {
        let sampleWidth = max(1, min(64, image.width))
        let sampleHeight = max(1, min(64, image.height))
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return "no-colorspace"
        }
        var buffer = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)
        guard let context = CGContext(
            data: &buffer,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return "no-context"
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        return stableDigest(Data(buffer).base64EncodedString())
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
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

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class OverlayRenderer {
    private let outputDirectory: URL
    private let isoFormatter = ISO8601DateFormatter()

    init() {
        outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-computer-use-local", isDirectory: true)
            .appendingPathComponent("overlays", isDirectory: true)
    }

    func render(
        screenshot: ScreenshotArtifact,
        recommendedTargets: [RecommendedTarget],
        ocrMatches: [OCRTextMatch]
    ) -> OverlayArtifact? {
        guard let image = loadImage(from: screenshot.path) else {
            return nil
        }

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: nil)
            guard let context = makeContext(width: image.width, height: image.height) else {
                return nil
            }

            let canvas = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.translateBy(x: 0, y: CGFloat(image.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: canvas)

            var legend: [OverlayLegendItem] = []
            var counters: [String: Int] = [:]

            for target in recommendedTargets.prefix(40) {
                guard let rect = rectForScreenBBox(target.bbox, screenshot: screenshot, image: image) else {
                    continue
                }
                let mark = nextMark(for: target.kind, counters: &counters)
                drawBox(context: context, rect: rect, mark: mark, color: color(for: target.kind))
                legend.append(
                    OverlayLegendItem(
                        mark: mark,
                        id: target.id,
                        kind: target.kind,
                        role: target.role,
                        name: target.name ?? target.description,
                        bbox: target.bbox
                    )
                )
            }

            for match in ocrMatches.prefix(40) {
                let mark = nextMark(for: "ocr_text", counters: &counters)
                let rect = clipped(match.boundingBox.integral, width: image.width, height: image.height)
                guard !rect.isEmpty else {
                    continue
                }
                drawBox(context: context, rect: rect, mark: mark, color: NSColor.systemPurple.cgColor, dashed: true)
                legend.append(
                    OverlayLegendItem(
                        mark: mark,
                        id: nil,
                        kind: "ocr_text",
                        role: "OCRText",
                        name: nil,
                        bbox: [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].map(Double.init)
                    )
                )
            }

            guard let outputImage = context.makeImage() else {
                return nil
            }

            let url = outputDirectory
                .appendingPathComponent("overlay-\(UUID().uuidString).png", isDirectory: false)
            try writePNG(image: outputImage, to: url)
            return OverlayArtifact(
                path: url.path,
                mimeType: "image/png",
                width: outputImage.width,
                height: outputImage.height,
                createdAt: isoFormatter.string(from: Date()),
                legend: legend
            )
        } catch {
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

    private func makeContext(width: Int, height: Int) -> CGContext? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
    }

    private func rectForScreenBBox(_ raw: [Double]?, screenshot: ScreenshotArtifact, image: CGImage) -> CGRect? {
        guard let raw, raw.count == 4 else {
            return nil
        }
        let source = CGRect(x: raw[0], y: raw[1], width: raw[2], height: raw[3])
        let frame: CGRect
        if let screenFrame = screenshot.screenFrame, screenFrame.count == 4 {
            frame = CGRect(x: screenFrame[0], y: screenFrame[1], width: screenFrame[2], height: screenFrame[3])
        } else {
            frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        }
        guard frame.width > 0, frame.height > 0 else {
            return nil
        }

        let scaleX = CGFloat(image.width) / frame.width
        let scaleY = CGFloat(image.height) / frame.height
        let rect = CGRect(
            x: (source.minX - frame.minX) * scaleX,
            y: (source.minY - frame.minY) * scaleY,
            width: source.width * scaleX,
            height: source.height * scaleY
        ).integral
        return clipped(rect, width: image.width, height: image.height)
    }

    private func clipped(_ rect: CGRect, width: Int, height: Int) -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let clipped = rect.intersection(bounds)
        if clipped.isNull {
            return .zero
        }
        return clipped
    }

    private func drawBox(context: CGContext, rect: CGRect, mark: String, color: CGColor, dashed: Bool = false) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(2)
        if dashed {
            context.setLineDash(phase: 0, lengths: [5, 4])
        }
        context.stroke(rect)
        context.restoreGState()

        let labelRect = CGRect(
            x: rect.minX,
            y: max(0, rect.minY - 18),
            width: max(28, CGFloat(mark.count * 9 + 8)),
            height: 16
        )
        context.saveGState()
        context.setFillColor(color.copy(alpha: 0.82) ?? color)
        context.fill(labelRect)
        context.restoreGState()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        (mark as NSString).draw(in: labelRect.insetBy(dx: 4, dy: 1), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func nextMark(for kind: String, counters: inout [String: Int]) -> String {
        let prefix: String
        switch kind {
        case "text_input":
            prefix = "T"
        case "scroll_region":
            prefix = "S"
        case "dangerous_action":
            prefix = "D"
        case "ocr_text":
            prefix = "O"
        default:
            prefix = "A"
        }
        let next = (counters[prefix] ?? 0) + 1
        counters[prefix] = next
        return "\(prefix)\(next)"
    }

    private func color(for kind: String) -> CGColor {
        switch kind {
        case "text_input":
            return NSColor.systemGreen.cgColor
        case "scroll_region":
            return NSColor.systemOrange.cgColor
        case "dangerous_action":
            return NSColor.systemRed.cgColor
        case "primary_action":
            return NSColor.systemBlue.cgColor
        default:
            return NSColor.systemTeal.cgColor
        }
    }

    private func writePNG(image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw HelperCLIError.invalidInput("Failed to create PNG destination for overlay output.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw HelperCLIError.invalidInput("Failed to finalize overlay PNG output.")
        }
    }
}

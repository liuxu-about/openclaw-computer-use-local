import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

private final class AwaitBox<T>: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedValue: T?
    private var storedError: Error?

    func store(value: T?, error: Error?) {
        lock.lock()
        storedValue = value
        storedError = error
        lock.unlock()
        semaphore.signal()
    }

    func snapshot() -> (value: T?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (storedValue, storedError)
    }
}

@MainActor
final class ScreenshotService {
    private struct ScreenshotValidationMetrics {
        let meanLuminance: Double
        let darkPixelRatio: Double
        let nearBlackPixelRatio: Double
        let visibleAlphaRatio: Double
        let uniqueColorBuckets: Int
    }

    private let outputDirectory: URL
    private let isoFormatter = ISO8601DateFormatter()
    private let eventLogger = EventLogger.shared
    private let maxWindowAttempts = 1
    private let maxDisplayAttempts = 1

    init() {
        self.outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-computer-use-local", isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
    }

    func shouldCapture(for request: ObserveRequest) -> Bool {
        request.includeScreenshot == true || request.mode == .axWithScreenshot || request.mode == .vision
    }

    func captureIfRequested(
        request: ObserveRequest,
        target: TargetContext?,
        screen: ScreenInfo
    ) async -> (artifact: ScreenshotArtifact?, error: String?) {
        guard shouldCapture(for: request) else {
            return (nil, nil)
        }

        do {
            let artifact = try await capture(target: target, screen: screen)
            eventLogger.log("helper_screenshot_capture_succeeded", payload: [
                "target_app": target?.appName as Any,
                "target_bundle_id": target?.bundleId as Any,
                "target_window": target?.windowTitle as Any,
                "capture_kind": artifact.captureKind,
                "path": artifact.path,
                "screen_frame": artifact.screenFrame as Any,
            ])
            return (artifact, nil)
        } catch {
            let message = String(describing: error)
            eventLogger.log("helper_screenshot_capture_failed", payload: [
                "target_app": target?.appName as Any,
                "target_bundle_id": target?.bundleId as Any,
                "target_window": target?.windowTitle as Any,
                "error": message,
            ])
            return (nil, message)
        }
    }

    private func capture(target: TargetContext?, screen: ScreenInfo) async throws -> ScreenshotArtifact {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: nil)

        let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = bestDisplay(for: target, displays: availableContent.displays, screen: screen)
            ?? availableContent.displays.first

        var failures: [String] = []

        if let target,
           let window = bestWindow(for: target, windows: availableContent.windows)
        {
            for attempt in 1...maxWindowAttempts {
                do {
                    eventLogger.log("helper_screenshot_attempt", payload: [
                        "route": "window",
                        "attempt": attempt,
                        "target_app": target.appName,
                        "target_bundle_id": target.bundleId,
                        "target_window": target.windowTitle as Any,
                        "window_title": window.title as Any,
                        "window_frame": bboxArray(window.frame),
                    ])
                    return try captureWindow(window, target: target)
                } catch {
                    failures.append("window[\(attempt)]: \(error.localizedDescription)")
                    eventLogger.log("helper_screenshot_attempt_failed", payload: [
                        "route": "window",
                        "attempt": attempt,
                        "target_app": target.appName,
                        "target_bundle_id": target.bundleId,
                        "target_window": target.windowTitle as Any,
                        "error": error.localizedDescription,
                    ])
                    if attempt < maxWindowAttempts {
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
            }
        }

        if let display {
            for attempt in 1...maxDisplayAttempts {
                do {
                    eventLogger.log("helper_screenshot_attempt", payload: [
                        "route": "display",
                        "attempt": attempt,
                        "target_app": target?.appName as Any,
                        "target_bundle_id": target?.bundleId as Any,
                        "target_window": target?.windowTitle as Any,
                        "display_id": display.displayID,
                        "display_frame": bboxArray(display.frame),
                    ])
                    return try captureDisplay(display, target: target)
                } catch {
                    failures.append("display[\(attempt)]: \(error.localizedDescription)")
                    eventLogger.log("helper_screenshot_attempt_failed", payload: [
                        "route": "display",
                        "attempt": attempt,
                        "target_app": target?.appName as Any,
                        "target_bundle_id": target?.bundleId as Any,
                        "target_window": target?.windowTitle as Any,
                        "display_id": display.displayID,
                        "error": error.localizedDescription,
                    ])
                    if attempt < maxDisplayAttempts {
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
            }
        }

        if let display {
            do {
                eventLogger.log("helper_screenshot_attempt", payload: [
                    "route": "cgdisplay",
                    "attempt": 1,
                    "target_app": target?.appName as Any,
                    "target_bundle_id": target?.bundleId as Any,
                    "target_window": target?.windowTitle as Any,
                    "display_id": display.displayID,
                    "display_frame": bboxArray(display.frame),
                ])
                return try captureCoreGraphicsDisplay(display, target: target)
            } catch {
                failures.append("cgdisplay[1]: \(error.localizedDescription)")
                eventLogger.log("helper_screenshot_attempt_failed", payload: [
                    "route": "cgdisplay",
                    "attempt": 1,
                    "target_app": target?.appName as Any,
                    "target_bundle_id": target?.bundleId as Any,
                    "target_window": target?.windowTitle as Any,
                    "display_id": display.displayID,
                    "error": error.localizedDescription,
                ])
            }
        }

        throw HelperCLIError.invalidInput(
            failures.isEmpty
                ? "Screenshot capture failed because no shareable displays or windows were available."
                : "Screenshot capture failed. " + failures.joined(separator: " | ")
        )
    }

    private func captureWindow(_ window: SCWindow, target: TargetContext) throws -> ScreenshotArtifact {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try captureImage(
            contentFilter: filter,
            width: max(1, Int(window.frame.width.rounded())),
            height: max(1, Int(window.frame.height.rounded()))
        )

        let nameHint = "\(target.appName)-\(target.windowTitle ?? window.title ?? "window")"
        return try validatedArtifact(
            image: image,
            route: "window",
            kind: "window",
            nameHint: nameHint,
            frame: window.frame
        )
    }

    private func captureDisplay(_ display: SCDisplay, target: TargetContext?) throws -> ScreenshotArtifact {
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let image = try captureImage(
            contentFilter: filter,
            width: max(1, Int(display.width)),
            height: max(1, Int(display.height))
        )

        if let targetFrame = target?.windowFrame,
           let cropRect = cropRect(
               for: targetFrame,
               within: display.frame,
               imageWidth: image.width,
               imageHeight: image.height
           ),
           let cropped = image.cropping(to: cropRect)
        {
            eventLogger.log("helper_screenshot_crop_applied", payload: [
                "route": "display_crop",
                "target_window_frame": bboxArray(targetFrame),
                "display_frame": bboxArray(display.frame),
                "crop_rect_px": bboxArray(cropRect),
            ])
            let nameHint = "\(target?.appName ?? "display")-\(target?.windowTitle ?? "crop")"
            return try validatedArtifact(
                image: cropped,
                route: "display_cropped",
                kind: "display_cropped",
                nameHint: nameHint,
                frame: targetFrame
            )
        }

        let nameHint = target?.appName ?? "display-\(display.displayID)"
        return try validatedArtifact(
            image: image,
            route: "display",
            kind: "display",
            nameHint: nameHint,
            frame: display.frame
        )
    }

    private func captureCoreGraphicsDisplay(_ display: SCDisplay, target: TargetContext?) throws -> ScreenshotArtifact {
        guard let image = CGDisplayCreateImage(display.displayID) else {
            throw HelperCLIError.invalidInput("CoreGraphics display capture returned no image.")
        }

        if let targetFrame = target?.windowFrame,
           let cropRect = cropRect(
               for: targetFrame,
               within: display.frame,
               imageWidth: image.width,
               imageHeight: image.height
           ),
           let cropped = image.cropping(to: cropRect)
        {
            eventLogger.log("helper_screenshot_crop_applied", payload: [
                "route": "cgdisplay_crop",
                "target_window_frame": bboxArray(targetFrame),
                "display_frame": bboxArray(display.frame),
                "crop_rect_px": bboxArray(cropRect),
            ])
            let nameHint = "\(target?.appName ?? "cgdisplay")-\(target?.windowTitle ?? "crop")"
            return try validatedArtifact(
                image: cropped,
                route: "cgdisplay_cropped",
                kind: "cgdisplay_cropped",
                nameHint: nameHint,
                frame: targetFrame
            )
        }

        let nameHint = target?.appName ?? "cgdisplay-\(display.displayID)"
        return try validatedArtifact(
            image: image,
            route: "cgdisplay",
            kind: "cgdisplay",
            nameHint: nameHint,
            frame: display.frame
        )
    }

    private func captureImage(contentFilter: SCContentFilter, width: Int, height: Int) throws -> CGImage {
        let config = SCStreamConfiguration()
        config.width = max(1, width)
        config.height = max(1, height)
        return try awaitResult(timeoutMs: 2200) { completion in
            SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: config, completionHandler: completion)
        }
    }

    private func writeArtifact(
        image: CGImage,
        kind: String,
        nameHint: String,
        frame: CGRect
    ) throws -> ScreenshotArtifact {
        let filename = "\(sanitized(nameHint))_\(UUID().uuidString).png"
        let url = outputDirectory.appendingPathComponent(filename, isDirectory: false)
        try writePNG(image: image, to: url)

        return ScreenshotArtifact(
            path: url.path,
            mimeType: "image/png",
            width: image.width,
            height: image.height,
            captureKind: kind,
            screenFrame: bboxArray(frame),
            createdAt: isoFormatter.string(from: Date())
        )
    }

    private func validatedArtifact(
        image: CGImage,
        route: String,
        kind: String,
        nameHint: String,
        frame: CGRect
    ) throws -> ScreenshotArtifact {
        if let metrics = validationMetrics(for: image),
           screenshotLooksInvalid(metrics)
        {
            eventLogger.log("helper_screenshot_validation_failed", payload: [
                "route": route,
                "kind": kind,
                "width": image.width,
                "height": image.height,
                "mean_luminance": metrics.meanLuminance,
                "dark_pixel_ratio": metrics.darkPixelRatio,
                "near_black_pixel_ratio": metrics.nearBlackPixelRatio,
                "visible_alpha_ratio": metrics.visibleAlphaRatio,
                "unique_color_buckets": metrics.uniqueColorBuckets,
            ])
            throw HelperCLIError.invalidInput(
                "Screenshot capture returned a near-black or visually invalid image."
            )
        }

        if let metrics = validationMetrics(for: image) {
            eventLogger.log("helper_screenshot_validation_succeeded", payload: [
                "route": route,
                "kind": kind,
                "width": image.width,
                "height": image.height,
                "mean_luminance": metrics.meanLuminance,
                "dark_pixel_ratio": metrics.darkPixelRatio,
                "near_black_pixel_ratio": metrics.nearBlackPixelRatio,
                "visible_alpha_ratio": metrics.visibleAlphaRatio,
                "unique_color_buckets": metrics.uniqueColorBuckets,
            ])
        }

        return try writeArtifact(
            image: image,
            kind: kind,
            nameHint: nameHint,
            frame: frame
        )
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

    private func bestWindow(for target: TargetContext, windows: [SCWindow]) -> SCWindow? {
        let candidates = windows.filter { window in
            window.isOnScreen && window.owningApplication?.bundleIdentifier == target.bundleId
        }

        return candidates.max { lhs, rhs in
            score(window: lhs, target: target) < score(window: rhs, target: target)
        }
    }

    private func bestDisplay(for target: TargetContext?, displays: [SCDisplay], screen: ScreenInfo) -> SCDisplay? {
        if let target, let frame = target.windowFrame {
            let midpoint = CGPoint(x: frame.midX, y: frame.midY)
            if let matched = displays.first(where: { $0.frame.contains(midpoint) }) {
                return matched
            }
        }

        if let displayId = UInt32(screen.displayId),
           let matched = displays.first(where: { $0.displayID == displayId })
        {
            return matched
        }

        return displays.first
    }

    private func score(window: SCWindow, target: TargetContext) -> Double {
        var score = 0.0

        if let title = target.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let windowTitle = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if windowTitle == title {
                score += 100
            } else if !windowTitle.isEmpty && (windowTitle.contains(title) || title.contains(windowTitle)) {
                score += 60
            }
        }

        if let targetFrame = target.windowFrame {
            let intersection = targetFrame.intersection(window.frame)
            if !intersection.isNull && !intersection.isEmpty {
                score += Double(intersection.width * intersection.height) / 5000.0
            }

            let dx = abs(targetFrame.origin.x - window.frame.origin.x)
            let dy = abs(targetFrame.origin.y - window.frame.origin.y)
            score -= Double(dx + dy) / 100.0
        }

        if window.windowLayer == 0 {
            score += 5
        }
        return score
    }

    private func writePNG(image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw HelperCLIError.invalidInput("Failed to create PNG destination for screenshot output.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw HelperCLIError.invalidInput("Failed to finalize screenshot PNG output.")
        }
    }

    private func sanitized(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(80)
            .description
            .lowercased()
    }

    private func bboxArray(_ rect: CGRect) -> [Double] {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
    }

    private func awaitResult<T>(
        timeoutMs: Int = 2200,
        _ body: (@escaping @Sendable (T?, Error?) -> Void) -> Void
    ) throws -> T {
        let box = AwaitBox<T>()

        body { value, error in
            box.store(value: value, error: error)
        }

        let timeout = DispatchTime.now() + .milliseconds(max(250, timeoutMs))
        if box.semaphore.wait(timeout: timeout) == .timedOut {
            throw HelperCLIError.invalidInput("ScreenCaptureKit timed out while waiting for a screenshot image.")
        }
        let snapshot = box.snapshot()
        if let thrown = snapshot.error {
            throw thrown
        }
        guard let output = snapshot.value else {
            throw HelperCLIError.invalidInput("Screenshot capture returned neither an image nor an error.")
        }
        return output
    }

    private func validationMetrics(for image: CGImage) -> ScreenshotValidationMetrics? {
        let sampleWidth = max(1, min(96, image.width))
        let sampleHeight = max(1, min(96, image.height))
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
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
            return nil
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var luminanceSum = 0.0
        var darkPixels = 0
        var nearBlackPixels = 0
        var visibleAlphaPixels = 0
        var buckets = Set<Int>()
        let pixelCount = sampleWidth * sampleHeight
        guard pixelCount > 0 else {
            return nil
        }

        for index in stride(from: 0, to: buffer.count, by: bytesPerPixel) {
            let r = Double(buffer[index])
            let g = Double(buffer[index + 1])
            let b = Double(buffer[index + 2])
            let a = Double(buffer[index + 3])
            let luminance = (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
            luminanceSum += luminance
            if luminance < 10 {
                darkPixels += 1
            }
            if luminance < 24 {
                nearBlackPixels += 1
            }
            if a > 8 {
                visibleAlphaPixels += 1
            }
            let bucket = ((Int(r) >> 5) << 10) | ((Int(g) >> 5) << 5) | (Int(b) >> 5)
            buckets.insert(bucket)
        }

        return ScreenshotValidationMetrics(
            meanLuminance: luminanceSum / Double(pixelCount),
            darkPixelRatio: Double(darkPixels) / Double(pixelCount),
            nearBlackPixelRatio: Double(nearBlackPixels) / Double(pixelCount),
            visibleAlphaRatio: Double(visibleAlphaPixels) / Double(pixelCount),
            uniqueColorBuckets: buckets.count
        )
    }

    private func screenshotLooksInvalid(_ metrics: ScreenshotValidationMetrics) -> Bool {
        if metrics.visibleAlphaRatio < 0.01 {
            return true
        }

        if metrics.meanLuminance < 4.0 && metrics.nearBlackPixelRatio > 0.995 {
            return true
        }

        if metrics.nearBlackPixelRatio > 0.998 && metrics.uniqueColorBuckets <= 4 {
            return true
        }

        return false
    }
}

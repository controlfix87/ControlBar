import AppKit
import ScreenCaptureKit

/// Captures pictures of menu bar items with ScreenCaptureKit (needs Screen Recording permission).
/// Images are cached by item ID so the strip can show something even when a live capture fails.
@MainActor
final class ItemImageCapturer {
    private(set) var cache: [String: NSImage] = [:]

    /// Captures the given items and returns every image available (fresh or cached).
    func images(for items: [MenuBarItem]) async -> [String: NSImage] {
        await refresh(items)
        return cache.filter { key, _ in items.contains { $0.id == key } }
    }

    /// Re-captures the given items, updating the cache. Returns the number of successful captures.
    @discardableResult
    func refresh(_ items: [MenuBarItem]) async -> Int {
        guard Permissions.screenRecording, !items.isEmpty else { return 0 }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            NSLog("ControlBar: SCShareableContent failed: \(error)")
            return 0
        }
        var byID: [CGWindowID: SCWindow] = [:]
        for window in content.windows { byID[window.windowID] = window }

        var captured = 0
        for item in items {
            guard let windowID = item.windowID, let window = byID[windowID] else { continue }
            if let image = await Self.capture(window) {
                cache[item.id] = image
                captured += 1
            }
        }
        return captured
    }

    private static func capture(_ window: SCWindow) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Capture with headroom for the strip's icon-size slider (up to 2x), which scales this
        // image up in point-space — capturing at only the display's native density would upscale
        // an already-native-resolution bitmap and blur it at larger strip scales. The extra margin
        // (beyond the slider's own 2x ceiling) keeps icons crisp at "normal" size too, since
        // ScreenCaptureKit's actual output can land a bit under the requested pixel dimensions.
        let scale = CGFloat(filter.pointPixelScale) * 3
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
              !isBlank(cgImage)
        else { return nil }
        let isMono = isMonochrome(cgImage)
        // Captured items include the status item's own padding, which reads as "small" once the
        // strip scales the whole (mostly empty) bounding box up — trimming to the glyph's actual
        // opaque content first means scaling enlarges the icon itself, not the padding around it.
        let (trimmedImage, trimmedSize) = trimmed(cgImage, fullSize: window.frame.size)
        let image = NSImage(cgImage: trimmedImage, size: trimmedSize)
        // Monochrome glyphs are drawn for the menu bar's own appearance, which may not match the
        // strip's; rendering them as templates lets the strip tint them for its background.
        image.isTemplate = isMono
        return image
    }

    /// Crops away fully-transparent padding around the glyph, keeping a 1px margin. Falls back to
    /// the original image untouched if no opaque content is found (e.g. an all-transparent capture
    /// that somehow passed `isBlank`).
    private static func trimmed(_ cgImage: CGImage, fullSize: NSSize) -> (CGImage, NSSize) {
        guard let bounds = contentBounds(of: cgImage), let cropped = cgImage.cropping(to: bounds) else {
            return (cgImage, fullSize)
        }
        let scaleX = fullSize.width / CGFloat(cgImage.width)
        let scaleY = fullSize.height / CGFloat(cgImage.height)
        return (cropped, NSSize(width: CGFloat(bounds.width) * scaleX, height: CGFloat(bounds.height) * scaleY))
    }

    private static func contentBounds(of image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, minY = h, maxX = -1, maxY = -1
        let threshold: UInt8 = 15
        for y in 0..<h {
            for x in 0..<w where p[(y * w + x) * 4 + 3] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        let margin = 1
        let x0 = max(0, minX - margin), y0 = max(0, minY - margin)
        let x1 = min(w - 1, maxX + margin), y1 = min(h - 1, maxY + margin)
        return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    private static func pixels(of image: CGImage, _ body: (UnsafePointer<UInt8>, Int) -> Bool) -> Bool {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return false }
        return body(data.bindMemory(to: UInt8.self, capacity: w * h * 4), w * h * 4)
    }

    /// Fully transparent captures happen when the window server has nothing drawn for the item.
    static func isBlank(_ image: CGImage) -> Bool {
        pixels(of: image) { p, count in
            stride(from: 3, to: count, by: 4).allSatisfy { p[$0] < 10 }
        }
    }

    static func isMonochrome(_ image: CGImage) -> Bool {
        pixels(of: image) { p, count in
            // Only solid pixels count: anti-aliased edges are premultiplied against the (possibly blue-tinted)
            // backdrop and read as coloured, which used to make plain white/grey glyphs fail this check and
            // get drawn raw — a bluish cast instead of the strip's label colour. Channels are un-premultiplied
            // so a dim solid pixel isn't mistaken for a desaturated one.
            var opaque = 0, colored = 0
            for i in stride(from: 0, to: count, by: 4) where p[i + 3] > 200 {
                opaque += 1
                let a = Int(p[i + 3])
                let r = Int(p[i]) * 255 / a, g = Int(p[i + 1]) * 255 / a, b = Int(p[i + 2]) * 255 / a
                if max(r, g, b) - min(r, g, b) > 60 { colored += 1 }
            }
            return opaque > 0 && Double(colored) / Double(opaque) < 0.12
        }
    }
}

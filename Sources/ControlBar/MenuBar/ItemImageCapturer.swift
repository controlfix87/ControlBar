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
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
              !isBlank(cgImage)
        else { return nil }
        let image = NSImage(cgImage: cgImage, size: window.frame.size)
        // Monochrome glyphs are drawn for the menu bar's own appearance, which may not match the
        // strip's; rendering them as templates lets the strip tint them for its background.
        image.isTemplate = isMonochrome(cgImage)
        return image
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
            var opaque = 0, colored = 0
            for i in stride(from: 0, to: count, by: 4) where p[i + 3] > 40 {
                opaque += 1
                let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
                if max(r, g, b) - min(r, g, b) > 40 { colored += 1 }
            }
            return opaque > 0 && Double(colored) / Double(opaque) < 0.05
        }
    }
}

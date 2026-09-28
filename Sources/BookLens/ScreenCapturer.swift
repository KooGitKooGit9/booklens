import AppKit
import CoreGraphics
import ScreenCaptureKit

/// A captured region of the screen and how to map between its pixels and global screen coordinates.
struct CapturedRegion {
    var image: CGImage
    /// Captured area in Cocoa global coordinates (origin bottom-left of the primary screen), in points.
    var frame: CGRect
    /// Pixels per point.
    var scale: CGFloat

    /// Converts a global Cocoa point to image pixel coordinates (origin top-left).
    func imagePoint(for global: CGPoint) -> CGPoint {
        CGPoint(x: (global.x - frame.minX) * scale, y: (frame.maxY - global.y) * scale)
    }

    /// Converts an image pixel rect (origin top-left) back to global Cocoa coordinates.
    func globalRect(for imageRect: CGRect) -> CGRect {
        CGRect(x: frame.minX + imageRect.minX / scale,
               y: frame.maxY - imageRect.maxY / scale,
               width: imageRect.width / scale,
               height: imageRect.height / scale)
    }
}

enum CaptureError: LocalizedError, Equatable {
    case permissionDenied
    case noDisplay
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "화면 기록 권한이 필요합니다."
        case .noDisplay: return "마우스 아래의 화면을 찾지 못했습니다."
        case .failed(let message): return "화면을 캡처하지 못했습니다: \(message)"
        }
    }
}

/// Captures screen regions with ScreenCaptureKit, excluding BookLens's own windows.
final class ScreenCapturer {
    /// Half-height of the captured band around the cursor, in points.
    var halfHeight: CGFloat = 200
    /// Widest band captured; wider windows are cropped around the cursor.
    var maxWidth: CGFloat = 1800

    private var cachedContent: SCShareableContent?
    private var cachedAt = Date.distantPast

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    private func shareableContent() async throws -> SCShareableContent {
        if let cachedContent, Date().timeIntervalSince(cachedAt) < 5 { return cachedContent }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            cachedContent = content
            cachedAt = Date()
            return content
        } catch {
            if !Self.hasPermission { throw CaptureError.permissionDenied }
            throw CaptureError.failed(error.localizedDescription)
        }
    }

    func capture(around point: CGPoint) async throws -> CapturedRegion {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else {
            throw CaptureError.noDisplay
        }
        let screenFrame = screen.frame
        // Capture a horizontal band spanning the window under the cursor, so text lines are not cut
        // off at the sides (a cut line would garble the sentence sent to the model).
        let window = Self.windowFrame(at: point) ?? screenFrame
        var minX = max(window.minX, screenFrame.minX)
        var maxX = min(window.maxX, screenFrame.maxX)
        if maxX - minX > maxWidth {
            minX = max(minX, min(point.x - maxWidth / 2, maxX - maxWidth))
            maxX = minX + maxWidth
        }
        var rect = CGRect(x: minX, y: point.y - halfHeight, width: maxX - minX, height: halfHeight * 2)
        rect = rect.intersection(screenFrame).integral
        guard !rect.isEmpty else { throw CaptureError.noDisplay }

        let content = try await shareableContent()
        let displayID = screen.displayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        // Capture at least 2 pixels per point: OCR is much more reliable on small text at 2x,
        // and ScreenCaptureKit upscales non-Retina displays for us.
        let scale = max(screen.backingScaleFactor, 2)
        let config = SCStreamConfiguration()
        // sourceRect is in display-local points with a top-left origin.
        config.sourceRect = CGRect(x: rect.minX - screenFrame.minX,
                                   y: screenFrame.maxY - rect.maxY,
                                   width: rect.width,
                                   height: rect.height)
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return CapturedRegion(image: image, frame: rect, scale: CGFloat(image.width) / rect.width)
        } catch {
            cachedContent = nil
            if !Self.hasPermission { throw CaptureError.permissionDenied }
            throw CaptureError.failed(error.localizedDescription)
        }
    }

    /// Frame (Cocoa global coordinates) of the front-most normal window under `point`, excluding BookLens.
    static func windowFrame(at point: CGPoint) -> CGRect? {
        guard let info = windowInfo(at: point), let primary = NSScreen.screens.first,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        return CGRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    private static func windowInfo(at point: CGPoint) -> [String: Any]? {
        guard let primary = NSScreen.screens.first else { return nil }
        // CGWindowList uses top-left origin global coordinates.
        let cgPoint = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return list.first { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return false }
            return bounds.contains(cgPoint)
        }
    }

    /// Title of the front-most window under `point` ("App — Window"), for the vocabulary list.
    static func windowTitle(at point: CGPoint) -> String {
        guard let info = windowInfo(at: point) else { return "" }
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        let name = info[kCGWindowName as String] as? String ?? ""
        return cleanTitle(owner: owner, name: name)
    }

    /// Strips browser noise so the title reads like a book name.
    static func cleanTitle(owner: String, name: String) -> String {
        var title = name
        for suffix in [" - Google Chrome", " — Safari", " - Safari", " - Microsoft Edge", " - Whale", " - Arc", " — Mozilla Firefox"] {
            if title.hasSuffix(suffix) { title.removeLast(suffix.count) }
        }
        title = title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return owner }
        return title
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
}

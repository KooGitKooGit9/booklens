import CoreGraphics

/// A captured region of the screen and how to map between its pixels and global screen coordinates.
public struct CapturedRegion {
    public var image: CGImage
    /// Captured area in Cocoa global coordinates (origin bottom-left of the primary screen), in points.
    public var frame: CGRect
    /// Pixels per point.
    public var scale: CGFloat

    public init(image: CGImage, frame: CGRect, scale: CGFloat) {
        self.image = image
        self.frame = frame
        self.scale = scale
    }

    /// Converts a global Cocoa point to image pixel coordinates (origin top-left).
    public func imagePoint(for global: CGPoint) -> CGPoint {
        CGPoint(x: (global.x - frame.minX) * scale, y: (frame.maxY - global.y) * scale)
    }

    /// Converts an image pixel rect (origin top-left) back to global Cocoa coordinates.
    public func globalRect(for imageRect: CGRect) -> CGRect {
        CGRect(x: frame.minX + imageRect.minX / scale,
               y: frame.maxY - imageRect.maxY / scale,
               width: imageRect.width / scale,
               height: imageRect.height / scale)
    }
}


import AppKit

// The menubar icon: a hummingbird silhouette extracted from the fleet's
// reference art (see scripts/extract-template.py). Rendered as a macOS
// template image so the system recolors it for light/dark mode.
// Falls back to the geometric vector bird if the bundled asset is missing.
// NOTE: SPM's Bundle.module accessor TRAPS (uncatchable crash) when the
// resource bundle is missing, so the bundle is located manually here.

enum BirdIcon {
    static func resourceBundle() -> Bundle? {
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL { candidates.append(resourceURL) }
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() { candidates.append(exeDir) }
        for dir in candidates {
            if let bundle = Bundle(url: dir.appendingPathComponent("HumminMenubar_HumminMenubar.bundle")) {
                return bundle
            }
        }
        return nil
    }

    static func statusBarIcon() -> NSImage {
        if let bundle = resourceBundle(),
           let url = bundle.url(forResource: "menubar-template", withExtension: "png", subdirectory: "Resources"),
           let art = NSImage(contentsOf: url) {
            let aspect = art.size.width / max(art.size.height, 1)
            let img = NSImage(size: NSSize(width: 20, height: 20 / max(aspect, 0.1)), flipped: false) { rect in
                art.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
            img.isTemplate = true
            return img
        }
        // fallback: geometric vector bird (used when assets are not installed)
        let img = birdImage(33)
        img.size = NSSize(width: 22, height: 16.5)
        img.isTemplate = true
        return img
    }
}

// Construction-geometry fallback bird: built from circles, arcs and wedges
// (no freehand curves), y-UP design space: head upper left, body behind,
// beak wedge to the far left, wing crescent up-right, tail wedges lower right.
enum BirdDesign {
    static let designWidth: CGFloat = 100
    static let designHeight: CGFloat = 75

    private static func circle(center: CGPoint, radius: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360, clockwise: false)
        p.close()
        return p
    }

    private static func wedge(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: a)
        p.line(to: b)
        p.line(to: c)
        p.close()
        return p
    }

    static func shapes() -> [NSBezierPath] {
        var shapes: [NSBezierPath] = []
        shapes.append(circle(center: CGPoint(x: 36, y: 47), radius: 9.5))
        shapes.append(circle(center: CGPoint(x: 53, y: 36), radius: 13.5))
        shapes.append(wedge(CGPoint(x: 27, y: 46), CGPoint(x: 4, y: 40.5), CGPoint(x: 27, y: 42.5)))
        let wing = NSBezierPath()
        wing.appendArc(withCenter: CGPoint(x: 50, y: 34), radius: 30,
                       startAngle: 32, endAngle: 78, clockwise: false)
        wing.appendArc(withCenter: CGPoint(x: 47, y: 31), radius: 24,
                       startAngle: 78, endAngle: 32, clockwise: true)
        wing.close()
        shapes.append(wing)
        shapes.append(wedge(CGPoint(x: 58, y: 27), CGPoint(x: 86, y: 7), CGPoint(x: 63, y: 21.5)))
        shapes.append(wedge(CGPoint(x: 62, y: 23), CGPoint(x: 89, y: 14.5), CGPoint(x: 66, y: 18)))
        return shapes
    }
}

func birdImage(_ pixelHeight: CGFloat) -> NSImage {
    let scale = pixelHeight / BirdDesign.designHeight
    let w = BirdDesign.designWidth * scale, h = pixelHeight
    let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
        NSColor.black.setFill()
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.scaleBy(x: rect.width / BirdDesign.designWidth, y: rect.height / BirdDesign.designHeight)
        for path in BirdDesign.shapes() { path.fill() }
        NSGraphicsContext.current?.cgContext.restoreGState()
        return true
    }
    return img
}

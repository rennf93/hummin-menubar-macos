import AppKit

// Vector hummingbird: the fleet mascot as a clean template icon.
// Design space is 100 x 75, bird facing right: long beak, round head,
// teardrop body, swept wing separated from the body by a bold gap so the
// negative space survives menubar size (16-18pt), tail sweeping down-left.

enum BirdDesign {
    static let designWidth: CGFloat = 100
    static let designHeight: CGFloat = 75

    static func bodyPath() -> NSBezierPath {
        let p = NSBezierPath()
        // needle beak: tip, top edge into the forehead
        p.move(to: NSPoint(x: 96, y: 34.8))
        p.line(to: NSPoint(x: 72, y: 37.2))
        // pronounced crown dome
        p.curve(to: NSPoint(x: 56, y: 33),
                controlPoint1: NSPoint(x: 68, y: 44),
                controlPoint2: NSPoint(x: 61, y: 40))
        // back flowing down-left
        p.curve(to: NSPoint(x: 35, y: 47),
                controlPoint1: NSPoint(x: 48, y: 36),
                controlPoint2: NSPoint(x: 40, y: 41))
        // tail: upper feather to the far tip
        p.curve(to: NSPoint(x: 7, y: 68),
                controlPoint1: NSPoint(x: 28, y: 53),
                controlPoint2: NSPoint(x: 15, y: 60))
        // fork notch between the two tail feathers (shallow, stays clean at size)
        p.curve(to: NSPoint(x: 23, y: 64),
                controlPoint1: NSPoint(x: 15, y: 65),
                controlPoint2: NSPoint(x: 19, y: 64.5))
        // lower tail feather, shorter and steeper
        p.curve(to: NSPoint(x: 14, y: 74),
                controlPoint1: NSPoint(x: 25, y: 67),
                controlPoint2: NSPoint(x: 18, y: 72))
        // back to the body underside
        p.curve(to: NSPoint(x: 32, y: 57),
                controlPoint1: NSPoint(x: 18, y: 72),
                controlPoint2: NSPoint(x: 26, y: 64))
        // belly toward the chest
        p.curve(to: NSPoint(x: 62, y: 50),
                controlPoint1: NSPoint(x: 43, y: 62),
                controlPoint2: NSPoint(x: 55, y: 57))
        // throat with a small chin notch, then the beak underside
        p.curve(to: NSPoint(x: 66, y: 42),
                controlPoint1: NSPoint(x: 65, y: 48),
                controlPoint2: NSPoint(x: 68, y: 45))
        p.line(to: NSPoint(x: 96, y: 33.2))
        p.close()
        return p
    }

    static func wingPath() -> NSBezierPath {
        let p = NSBezierPath()
        // shoulder, leading edge sweeping up-left to the tip
        p.move(to: NSPoint(x: 57, y: 33))
        p.curve(to: NSPoint(x: 20, y: 3),
                controlPoint1: NSPoint(x: 46, y: 19),
                controlPoint2: NSPoint(x: 30, y: 6))
        // slim rounded tip
        p.curve(to: NSPoint(x: 28, y: 10),
                controlPoint1: NSPoint(x: 17, y: 5),
                controlPoint2: NSPoint(x: 22, y: 8))
        // concave trailing edge back down to the shoulder, gap stays visible
        p.curve(to: NSPoint(x: 46, y: 30),
                controlPoint1: NSPoint(x: 32, y: 18),
                controlPoint2: NSPoint(x: 40, y: 26))
        p.close()
        return p
    }
}

// Renders the black bird at the requested pixel height on transparency.
func birdImage(_ pixelHeight: CGFloat) -> NSImage {
    let scale = pixelHeight / BirdDesign.designHeight
    let w = BirdDesign.designWidth * scale, h = pixelHeight
    let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
        NSColor.black.setFill()
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: rect.height)
        NSGraphicsContext.current?.cgContext.scaleBy(x: rect.width / BirdDesign.designWidth, y: -rect.height / BirdDesign.designHeight)
        BirdDesign.bodyPath().fill()
        BirdDesign.wingPath().fill()
        NSGraphicsContext.current?.cgContext.restoreGState()
        return true
    }
    return img
}

// Menubar-ready template image (the system recolors it for light/dark mode).
func templateBirdImage() -> NSImage {
    let img = birdImage(33)
    img.size = NSSize(width: 22, height: 16.5)
    img.isTemplate = true
    return img
}

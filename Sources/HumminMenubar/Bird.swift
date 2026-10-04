import AppKit

// Vector hummingbird: the fleet mascot as a clean template icon.
// Design space is 100 x 75, bird facing right: long beak, round head,
// teardrop body, swept wing separated from the body by a bold gap so the
// negative space survives menubar size (16-18pt), tail sweeping down-left.

enum BirdDesign {
    static let designWidth: CGFloat = 100
    static let designHeight: CGFloat = 75

    // Design space is y-UP (the CG context is y-up): beak on the LEFT at mid
    // height, crown ABOVE the beak, wing sweeping up-right, tail down-right.
    static func bodyPath() -> NSBezierPath {
        let p = NSBezierPath()
        // needle beak: tip, top edge into the forehead
        p.move(to: NSPoint(x: 3, y: 40))
        p.line(to: NSPoint(x: 28, y: 43))
        // crown dome: the head is the highest point of the whole bird
        p.curve(to: NSPoint(x: 47, y: 45),
                controlPoint1: NSPoint(x: 32, y: 53),
                controlPoint2: NSPoint(x: 42, y: 55))
        // back of the head with a slight dip, then the back slopes to the tail
        p.curve(to: NSPoint(x: 53, y: 46),
                controlPoint1: NSPoint(x: 51, y: 43),
                controlPoint2: NSPoint(x: 52, y: 44))
        p.curve(to: NSPoint(x: 68, y: 28),
                controlPoint1: NSPoint(x: 58, y: 37),
                controlPoint2: NSPoint(x: 65, y: 32))
        // tail: upper feather
        p.curve(to: NSPoint(x: 94, y: 15),
                controlPoint1: NSPoint(x: 76, y: 26),
                controlPoint2: NSPoint(x: 88, y: 19))
        // fork notch between the feathers
        p.curve(to: NSPoint(x: 81, y: 17),
                controlPoint1: NSPoint(x: 89, y: 13.5),
                controlPoint2: NSPoint(x: 84, y: 15))
        // lower tail feather
        p.curve(to: NSPoint(x: 88, y: 5),
                controlPoint1: NSPoint(x: 77, y: 11),
                controlPoint2: NSPoint(x: 84, y: 7.5))
        // underside back to the belly
        p.curve(to: NSPoint(x: 68, y: 24),
                controlPoint1: NSPoint(x: 84, y: 3),
                controlPoint2: NSPoint(x: 75, y: 12))
        // belly and chest rising toward the chin
        p.curve(to: NSPoint(x: 37, y: 35),
                controlPoint1: NSPoint(x: 56, y: 17),
                controlPoint2: NSPoint(x: 43, y: 24))
        // rounded chin under the beak
        p.curve(to: NSPoint(x: 30, y: 37),
                controlPoint1: NSPoint(x: 33, y: 34),
                controlPoint2: NSPoint(x: 31, y: 35.5))
        p.close()
        return p
    }

    static func wingPath() -> NSBezierPath {
        let p = NSBezierPath()
        // shoulder, leading edge sweeping up-right to the tip
        p.move(to: NSPoint(x: 52, y: 44))
        p.curve(to: NSPoint(x: 83, y: 64),
                controlPoint1: NSPoint(x: 63, y: 51),
                controlPoint2: NSPoint(x: 76, y: 60))
        // slim rounded tip
        p.curve(to: NSPoint(x: 76, y: 57),
                controlPoint1: NSPoint(x: 81, y: 62),
                controlPoint2: NSPoint(x: 78, y: 60))
        // concave trailing edge back down, bold gap to the back
        p.curve(to: NSPoint(x: 63, y: 47),
                controlPoint1: NSPoint(x: 72, y: 56),
                controlPoint2: NSPoint(x: 66, y: 51))
        p.close()
        return p
    }
}

// Menubar-ready template image (the system recolors it for light/dark mode).
func templateBirdImage() -> NSImage {
    let img = birdImage(33)
    img.size = NSSize(width: 22, height: 16.5)
    img.isTemplate = true
    return img
}

// Renders the black bird at the requested pixel height on transparency.
func birdImage(_ pixelHeight: CGFloat) -> NSImage {
    let scale = pixelHeight / BirdDesign.designHeight
    let w = BirdDesign.designWidth * scale, h = pixelHeight
    let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
        NSColor.black.setFill()
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.scaleBy(x: rect.width / BirdDesign.designWidth, y: rect.height / BirdDesign.designHeight)
        BirdDesign.bodyPath().fill()
        BirdDesign.wingPath().fill()
        NSGraphicsContext.current?.cgContext.restoreGState()
        return true
    }
    return img
}

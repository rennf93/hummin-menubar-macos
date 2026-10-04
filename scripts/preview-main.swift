// Design preview harness for the menubar icon: renders the current vector
// bird large, plus menubar-scale strips on dark and light, to a PNG.
//
// Usage (top-level code must live in a file named main.swift):
//   tmp=$(mktemp -d)
//   cp Sources/HumminMenubar/Bird.swift $tmp/
//   cp scripts/preview-main.swift $tmp/main.swift
//   swiftc -O $tmp/Bird.swift $tmp/main.swift -o $tmp/preview
//   $tmp/preview bird-preview.png
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "bird-preview.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 380, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 480, height: 380).fill()
NSColor.black.setStroke()
NSBezierPath(rect: NSRect(x: 0.5, y: 0.5, width: 479, height: 379)).stroke()
let big = birdImage(360)
big.draw(in: NSRect(x: 60, y: 45, width: 360, height: 270), from: .zero, operation: .sourceOver, fraction: 1)
// menubar-scale strips: dark chip and light chip, icon at true 44x33
NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
NSRect(x: 20, y: 8, width: 200, height: 30).fill()
NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
NSRect(x: 240, y: 8, width: 220, height: 30).fill()
let dark = birdImage(33); dark.size = NSSize(width: 44, height: 33)
NSColor.white.setFill()
dark.draw(in: NSRect(x: 30, y: 6, width: 44, height: 33), from: .zero, operation: .sourceOver, fraction: 1)
NSColor.black.setFill()
dark.draw(in: NSRect(x: 250, y: 6, width: 44, height: 33), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

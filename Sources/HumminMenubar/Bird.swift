import AppKit

// The hummin bird, drawn pixel by pixel so the binary needs no assets.
let BIRD: [String] = [
    "...BBBBB........",
    "...BDDWWB.......",
    "WWWWWEEEB.......",
    "...BEEEDBB......",
    "...WEEBDDBB.....",
    "...WGGDDDDBB....",
    "....BGGBDDDBB...",
    "....BBGBBBDDB...",
    ".....BBGGGBDDB..",
    "......BBBGBBBDBB",
    "......BWBB..BBDB",
    ".............BBB",
]

func birdImage() -> NSImage {
    let cols = BIRD[0].count, rows = BIRD.count
    let img = NSImage(size: NSSize(width: cols, height: rows))
    img.lockFocus()
    NSColor.black.set()
    for (y, row) in BIRD.enumerated() {
        for (x, ch) in row.enumerated() where ch != "." {
            NSRect(x: x, y: rows - 1 - y, width: 1, height: 1).fill()
        }
    }
    img.unlockFocus()
    img.isTemplate = true
    return img
}

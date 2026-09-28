import AppKit

let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

NSColor.black.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()

let ring = NSBezierPath(ovalIn: NSRect(x: 196, y: 196, width: 632, height: 632))
ring.lineWidth = 26
NSColor.white.withAlphaComponent(0.94).setStroke()
ring.stroke()

NSColor.white.setFill()
for (width, y) in [(CGFloat(300), CGFloat(548)), (CGFloat(220), CGFloat(478)), (CGFloat(270), CGFloat(408))] {
    let rect = NSRect(x: (CGFloat(size) - width) / 2, y: y, width: width, height: 22)
    NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
}

NSColor(calibratedRed: 1, green: 0.23, blue: 0.19, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 470, y: 292, width: 84, height: 84)).fill()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    fputs("Could not encode icon\n", stderr)
    exit(1)
}

let url = URL(fileURLWithPath: "TempCam/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try png.write(to: url)
print(url.path)

// eqVol app icon generator — generic speaker glyph on a blue rounded square.
// Rendered on a 512-unit grid, scaled to any size. Usage:
//   swift make-icon.swift <out.png> [size]
// Draws with transparency outside the rounded corners (macOS icon style).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
  fputs("usage: swift make-icon.swift <out.png> [size]\n", stderr)
  exit(2)
}
let outPath = args[1]
let size = CGFloat(args.count > 2 ? (Int(args[2]) ?? 1024) : 1024)
let s = size / 512.0

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Blue rounded square (jocala accent #007aff), 22% corner radius.
let radius = 0.22 * size
ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                   cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.setFillColor(CGColor(srgbRed: 0, green: 122.0 / 255.0, blue: 1, alpha: 1))
ctx.fillPath()

// Coordinates authored on the 512 grid.
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
  CGPoint(x: x * s, y: y * s)
}
let white = CGColor(gray: 1, alpha: 1)

// Speaker body: magnet box + flaring horn mouth.
ctx.move(to: p(130, 320))
ctx.addLine(to: p(130, 192))
ctx.addLine(to: p(200, 192))
ctx.addLine(to: p(285, 128))
ctx.addLine(to: p(285, 384))
ctx.addLine(to: p(200, 320))
ctx.closePath()
ctx.setFillColor(white)
ctx.fillPath()

// Sound waves: two stroked arcs off the horn mouth.
ctx.setStrokeColor(white)
ctx.setLineWidth(26 * s)
ctx.setLineCap(.round)
let center = CGPoint(x: 285 * s, y: 256 * s)
for r in [52.0, 102.0] {
  ctx.addArc(center: center, radius: CGFloat(r) * s,
             startAngle: -.pi * 0.28, endAngle: .pi * 0.28, clockwise: false)
  ctx.strokePath()
}

guard let image = ctx.makeImage() else {
  fputs("make-icon: CGContext.makeImage() failed\n", stderr)
  exit(1)
}
let url = URL(fileURLWithPath: outPath) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
  fputs("make-icon: cannot create image destination at \(outPath)\n", stderr)
  exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
  fputs("make-icon: failed to write \(outPath)\n", stderr)
  exit(1)
}
print("wrote \(outPath) (\(Int(size))x\(Int(size)))")

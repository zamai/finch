// Draws the app icon: a finch working a switchboard, headset on, routes leading out four ways.
//   swift tools/make-icon.swift Resources/AppIcon.icns docs/icon.png
import AppKit
import SwiftUI

func rgb(_ v: Int) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

let white = rgb(0xFFFFFF), navy = rgb(0x241257), ink = rgb(0x17131F), teal = rgb(0x41D6C3)
let gold = rgb(0xFFD03D), cream = rgb(0xFFF3DC), red = rgb(0xE93B35), orange = rgb(0xFF8A3D)

// Drawn on a 1024 canvas, y down, with the origin moved to the middle of the hub.
func draw(pixels: Int) -> CGImage {
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    func fill(_ path: CGPath, _ color: CGColor) {
        c.addPath(path); c.setFillColor(color); c.fillPath()
    }
    func stroke(_ path: CGPath, _ color: CGColor, width: CGFloat) {
        c.addPath(path); c.setStrokeColor(color); c.setLineWidth(width)
        c.setLineCap(.round); c.setLineJoin(.round); c.strokePath()
    }
    func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: CGColor) {
        c.setFillColor(color); c.fillEllipse(in: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry))
    }

    let scale = CGFloat(pixels) / 1024
    c.translateBy(x: 0, y: CGFloat(pixels)); c.scaleBy(x: scale, y: -scale)

    // Tile
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    c.addPath(Path(roundedRect: tile, cornerRadius: 185.4, style: .continuous).cgPath); c.clip()
    let shade = CGGradient(colorsSpace: nil, colors: [rgb(0x7253D8), rgb(0x35207E)] as CFArray, locations: nil)!
    c.drawLinearGradient(shade, start: point(512, 100), end: point(512, 924), options: [])
    c.translateBy(x: 512, y: 512)

    // Routes
    for turn in 0..<4 {
        c.saveGState(); c.rotate(by: CGFloat(turn) * .pi / 2)
        let shaft = CGMutablePath()
        shaft.move(to: point(0, 0)); shaft.addLine(to: point(0, -250))
        stroke(shaft, white, width: 64)
        let head = CGMutablePath()
        head.move(to: point(0, -350))
        head.addLine(to: point(75.44, -258)); head.addLine(to: point(-75.44, -258))
        head.closeSubpath()
        fill(head, white); stroke(head, white, width: 20.24)
        c.restoreGState()
    }
    oval(0, 0, 216, 216, navy)

    // Bird
    let body = CGMutablePath()
    body.move(to: point(0, -120))
    body.addCurve(to: point(116, -6), control1: point(76, -120), control2: point(112, -70))
    body.addCurve(to: point(0, 140), control1: point(136, 74), control2: point(90, 140))
    body.addCurve(to: point(-116, -6), control1: point(-90, 140), control2: point(-136, 74))
    body.addCurve(to: point(0, -120), control1: point(-112, -70), control2: point(-76, -120))
    body.closeSubpath()
    fill(body, gold)
    c.saveGState(); c.addPath(body); c.clip()
    oval(0, -134, 88, 68, red)
    oval(0, 120, 80, 72, cream)
    c.restoreGState()

    // Headset
    let band = CGMutablePath()
    band.move(to: point(-120, -22))
    band.addCurve(to: point(120, -22), control1: point(-118, -186), control2: point(118, -186))
    stroke(band, white, width: 22)
    oval(-122, -14, 28, 44, teal); oval(122, -14, 28, 44, teal)
    let boom = CGMutablePath()
    boom.move(to: point(124, 22)); boom.addQuadCurve(to: point(52, 74), control: point(124, 78))
    stroke(boom, white, width: 14)
    oval(46, 74, 18, 18, teal)

    // Face
    for x: CGFloat in [-46, 46] {
        let r: CGFloat = 22
        oval(x, -36, r, r, ink)
        oval(x + r * 0.3, -36 - r * 0.32, r * 0.36, r * 0.36, white)
    }
    let beak = CGMutablePath()
    beak.move(to: point(-28, -8)); beak.addQuadCurve(to: point(28, -8), control: point(0, -32))
    beak.addLine(to: point(0, 38)); beak.closeSubpath()
    fill(beak, orange)

    return c.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) throws {
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}

let args = CommandLine.arguments
guard args.count > 1 else { print("usage: make-icon.swift <out.icns> [preview.png]"); exit(2) }
let set = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
// No 16 or 32 px representations: macOS puts those on a grey plate even when the shape is right,
// and scales down cleanly from the 64 px one (32@2x) instead.
for size in [32, 128, 256, 512] {
    if size > 32 { try writePNG(draw(pixels: size), set.appendingPathComponent("icon_\(size)x\(size).png")) }
    try writePNG(draw(pixels: size * 2), set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let p = try Process.run(URL(fileURLWithPath: "/usr/bin/iconutil"),
                        arguments: ["-c", "icns", set.path, "-o", args[1]])
p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
guard p.terminationStatus == 0 else { print("iconutil failed"); exit(1) }
if args.count > 2 { try writePNG(draw(pixels: 512), URL(fileURLWithPath: args[2])) }

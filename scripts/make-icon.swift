#!/usr/bin/env swift
// Draws the Rainbarrel app icon and builds Resources/AppIcon.icns. macOS only.
//
//   swift scripts/make-icon.swift <out-dir> [--preview <png>] [--keep-iconset]
//
// Writes <out-dir>/AppIcon.icns. The icon is drawn in code (CoreGraphics only, no SF Symbols,
// whose license excludes app icons) on Apple's 1024 pt canvas: an 824 pt rounded-square body with
// a soft shadow, a blue gradient, a white rain barrel with two blue hoops and three raindrops.
// --preview also writes a 256 px PNG; --keep-iconset leaves AppIcon.iconset next to the icns.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The macOS icon shape: a superellipse, which has the continuous corners of Apple's icon grid.
func iconShape(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + rect.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent)
        let y = rect.midY + rect.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// A raindrop with its tip at the top and a round belly at the bottom.
func drop(centerX: CGFloat, bottom: CGFloat, radius r: CGFloat, height: CGFloat) -> CGPath {
    let belly = bottom + r
    let tip = bottom + height
    let path = CGMutablePath()
    path.move(to: CGPoint(x: centerX, y: tip))
    path.addCurve(
        to: CGPoint(x: centerX + r, y: belly),
        control1: CGPoint(x: centerX + r * 0.15, y: tip - (tip - belly) * 0.45),
        control2: CGPoint(x: centerX + r, y: belly + (tip - belly) * 0.35))
    path.addArc(center: CGPoint(x: centerX, y: belly), radius: r, startAngle: 0, endAngle: .pi, clockwise: true)
    path.addCurve(
        to: CGPoint(x: centerX, y: tip),
        control1: CGPoint(x: centerX - r, y: belly + (tip - belly) * 0.35),
        control2: CGPoint(x: centerX - r * 0.15, y: tip - (tip - belly) * 0.45))
    path.closeSubpath()
    return path
}

func drawIcon(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = iconShape(in: body)

    // Body with the soft shadow of the icon grid.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.30))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x0B3A8F))
    ctx.fillPath()
    ctx.restoreGState()

    // Vertical gradient, sky blue at the top to deep blue at the bottom.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: space, colors: [color(0x49B4F7), color(0x0B3A8F)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()

    // Barrel: slightly bulging sides, an open top and a gently curved base.
    let cx: CGFloat = 512
    let top: CGFloat = 620, bottom: CGFloat = 210
    let topHalf: CGFloat = 188, midHalf: CGFloat = 232
    let rimRY: CGFloat = 46
    let barrel = CGMutablePath()
    barrel.move(to: CGPoint(x: cx - topHalf, y: top))
    barrel.addCurve(
        to: CGPoint(x: cx - topHalf, y: bottom),
        control1: CGPoint(x: cx - midHalf - 40, y: top - 120),
        control2: CGPoint(x: cx - midHalf - 40, y: bottom + 120))
    barrel.addQuadCurve(to: CGPoint(x: cx + topHalf, y: bottom), control: CGPoint(x: cx, y: bottom - 50))
    barrel.addCurve(
        to: CGPoint(x: cx + topHalf, y: top),
        control1: CGPoint(x: cx + midHalf + 40, y: bottom + 120),
        control2: CGPoint(x: cx + midHalf + 40, y: top - 120))
    barrel.closeSubpath()

    ctx.setFillColor(color(0xFFFFFF))
    ctx.addPath(barrel)
    ctx.fillPath()

    // Staves and hoops are clipped to the barrel.
    ctx.saveGState()
    ctx.addPath(barrel)
    ctx.clip()
    ctx.setStrokeColor(color(0xCFE3F6))
    ctx.setLineWidth(8)
    for dx: CGFloat in [-78, 78] {
        ctx.move(to: CGPoint(x: cx + dx, y: top))
        ctx.addCurve(
            to: CGPoint(x: cx + dx, y: bottom - 30),
            control1: CGPoint(x: cx + dx * 1.18, y: top - 120),
            control2: CGPoint(x: cx + dx * 1.18, y: bottom + 120))
        ctx.strokePath()
    }
    ctx.setStrokeColor(color(0x1B55B0))
    ctx.setLineWidth(40)
    for hoopY: CGFloat in [500, 300] {
        // The front half of a ring seen from slightly above: the lower half of a flat ellipse.
        ctx.saveGState()
        ctx.translateBy(x: cx, y: hoopY)
        ctx.scaleBy(x: 1, y: 0.17)
        ctx.addArc(center: .zero, radius: 330, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
        ctx.restoreGState()
        ctx.strokePath()
    }
    ctx.restoreGState()

    // Open top: a rim ring and the dark water inside.
    let rim = CGRect(x: cx - topHalf, y: top - rimRY, width: topHalf * 2, height: rimRY * 2)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillEllipse(in: rim)
    ctx.setFillColor(color(0x1B55B0))
    ctx.fillEllipse(in: rim.insetBy(dx: 16, dy: 10))

    // Raindrops falling into the opening.
    ctx.setFillColor(color(0xD6F0FF))
    for (x, y, r, h) in [
        (cx - 118, 742.0, 30.0, 92.0), (cx, 700.0, 34.0, 100.0), (cx + 118, 742.0, 30.0, 92.0),
    ] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        ctx.addPath(drop(centerX: x, bottom: y, radius: r, height: h))
        ctx.fillPath()
    }
}

func render(size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(url.path)") }
}

// MARK: Main

var arguments = Array(CommandLine.arguments.dropFirst())
var preview: String?
if let index = arguments.firstIndex(of: "--preview"), index + 1 < arguments.count {
    preview = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
}
let keepIconset = arguments.contains("--keep-iconset")
arguments.removeAll { $0 == "--keep-iconset" }
guard let outPath = arguments.first else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <out-dir> [--preview <png>] [--keep-iconset]\n".utf8))
    exit(2)
}

let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let fileManager = FileManager.default
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    writePNG(render(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let preview { writePNG(render(size: 256), to: URL(fileURLWithPath: preview)) }

let icns = outDir.appendingPathComponent("AppIcon.icns")
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try tool.run()
tool.waitUntilExit()
guard tool.terminationStatus == 0 else { fatalError("iconutil failed") }
if !keepIconset { try? fileManager.removeItem(at: iconset) }
print("Wrote \(icns.path)")

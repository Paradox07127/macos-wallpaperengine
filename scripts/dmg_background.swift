// Renders the DMG window background and emits a HiDPI (@1x+@2x) TIFF.
//
//   swift scripts/dmg_background.swift <out.tiff> "<App Name>"
//
// The app name is baked into the Terminal command on the image, so Pro and Lite
// need separate renders — that is why release-app.sh calls this per SKU instead
// of committing a static PNG.

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Single source of truth for the DMG window layout. Finder places icons over
// this image by absolute coordinate, so release-app.sh imports these same
// numbers via --print-layout rather than repeating them as create-dmg flags.
//
// H carries ~100pt of dead space below the last icon on purpose: Finder draws
// the path bar (and optionally the status bar) inside the window, eating up to
// ~52pt, and their visibility comes from the *viewer's* Finder prefs, not from
// anything we can bake into the image. create-dmg's AppleScript only turns off
// the toolbar and status bar, never the path bar.
let W: CGFloat = 680
let H: CGFloat = 560
let iconSize: CGFloat = 104
let appCenter = CGPoint(x: 180, y: 155)
let appsCenter = CGPoint(x: 500, y: 155)
let readmeCenter = CGPoint(x: 340, y: 400)

// Gaps between an icon's edge and the arrow; the end gap also leaves room for
// the arrowhead, which extends past the shaft's end point.
let arrowStartGap: CGFloat = 20
let arrowEndGap: CGFloat = 42

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

let cGradTop = rgb(249, 250, 252)
let cGradBottom = rgb(228, 232, 239)
let cTitle = rgb(48, 54, 64)
let cSubtitle = rgb(126, 134, 148)
let cArrow = rgb(168, 178, 194)
let cCodeBg = rgb(255, 255, 255, 0.85)
let cCodeBorder = rgb(198, 205, 216)
let cCodeText = rgb(58, 66, 78)

/// Finder icon coords are top-left origin; CoreGraphics is bottom-left.
func cgY(_ finderY: CGFloat) -> CGFloat { H - finderY }

func drawText(_ ctx: CGContext, _ s: String, font: NSFont, color: CGColor,
              centerX: CGFloat, baselineY: CGFloat, tracking: CGFloat = 0)
{
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: color)!,
        .kern: tracking,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.textPosition = CGPoint(x: centerX - bounds.width / 2 - bounds.origin.x, y: baselineY)
    CTLineDraw(line, ctx)
}

/// Painted onto the background, so it cannot be selected. The same command is
/// duplicated in the READ ME text file, which is where users can copy it from.
func drawCodeBlock(_ ctx: CGContext, _ cmd: String, centerY finderY: CGFloat) {
    let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: cCodeText)!,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: cmd, attributes: attrs))
    var ascent: CGFloat = 0, descent: CGFloat = 0
    let textW = CTLineGetTypographicBounds(line, &ascent, &descent, nil)

    let padX: CGFloat = 16, boxH: CGFloat = 34
    let boxW = CGFloat(textW) + padX * 2
    if boxW > W - 24 {
        FileHandle.standardError.write(
            "ERROR: command too wide for the window (\(Int(boxW))pt > \(Int(W - 24))pt)\n".data(using: .utf8)!)
        exit(1)
    }
    let box = CGRect(x: (W - boxW) / 2, y: cgY(finderY) - boxH / 2, width: boxW, height: boxH)
    let path = CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil)

    ctx.addPath(path)
    ctx.setFillColor(cCodeBg)
    ctx.fillPath()
    ctx.addPath(path)
    ctx.setStrokeColor(cCodeBorder)
    ctx.setLineWidth(1)
    ctx.strokePath()

    ctx.textPosition = CGPoint(x: box.minX + padX, y: box.midY - (ascent - descent) / 2)
    CTLineDraw(line, ctx)
}

/// Arc from the app icon to the Applications folder. The arrowhead sits at the
/// tip: its base is centred on the curve's end point and it extends outward
/// along the tangent, so x1 is where the shaft stops, not where the point lands.
func drawCurvedArrow(_ ctx: CGContext, from x0: CGFloat, to x1: CGFloat, y: CGFloat,
                     lift: CGFloat)
{
    let yy = cgY(y)
    let p0 = CGPoint(x: x0, y: yy)
    let p2 = CGPoint(x: x1, y: yy)
    let ctrl = CGPoint(x: (x0 + x1) / 2, y: yy + lift)

    let curve = CGMutablePath()
    curve.move(to: p0)
    curve.addQuadCurve(to: p2, control: ctrl)
    ctx.addPath(curve)
    ctx.setStrokeColor(cArrow)
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.strokePath()

    // Derivative of a quadratic Bezier at t=1 is 2*(P2-P1).
    let dx = 2 * (p2.x - ctrl.x), dy = 2 * (p2.y - ctrl.y)
    let len = (dx * dx + dy * dy).squareRoot()
    let ux = dx / len, uy = dy / len
    let headLen: CGFloat = 22, headHalf: CGFloat = 10

    let head = CGMutablePath()
    head.move(to: CGPoint(x: p2.x + ux * headLen, y: p2.y + uy * headLen))
    head.addLine(to: CGPoint(x: p2.x - uy * headHalf, y: p2.y + ux * headHalf))
    head.addLine(to: CGPoint(x: p2.x + uy * headHalf, y: p2.y - ux * headHalf))
    head.closeSubpath()
    ctx.addPath(head)
    ctx.setFillColor(cArrow)
    ctx.fillPath()
}

func render(appName: String, scale: CGFloat, to url: URL) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale),
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("could not create bitmap context") }

    ctx.scaleBy(x: scale, y: scale)

    let grad = CGGradient(colorsSpace: cs, colors: [cGradTop, cGradBottom] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

    let prev = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    drawText(ctx, "Drag to Applications to install",
             font: .systemFont(ofSize: 21, weight: .semibold),
             color: cTitle, centerX: W / 2, baselineY: cgY(54), tracking: 0.2)

    drawCurvedArrow(ctx,
                    from: appCenter.x + iconSize / 2 + arrowStartGap,
                    to: appsCenter.x - iconSize / 2 - arrowEndGap,
                    y: appCenter.y, lift: 38)

    drawText(ctx, "Blocked on first launch? Run this once in Terminal:",
             font: .systemFont(ofSize: 12.5, weight: .medium),
             color: cSubtitle, centerX: W / 2, baselineY: cgY(258))

    drawCodeBlock(ctx, "xattr -dr com.apple.quarantine \"/Applications/\(appName).app\"",
                  centerY: 292)

    NSGraphicsContext.current = prev

    guard let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(
              url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("could not encode \(url.lastPathComponent)") }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

// Emits the layout as shell assignments so release-app.sh can build its
// create-dmg flags from these constants instead of duplicating them.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--print-layout" {
    print("""
    DMG_WINDOW_W=\(Int(W))
    DMG_WINDOW_H=\(Int(H))
    DMG_ICON_SIZE=\(Int(iconSize))
    DMG_APP_X=\(Int(appCenter.x))
    DMG_APP_Y=\(Int(appCenter.y))
    DMG_APPS_X=\(Int(appsCenter.x))
    DMG_APPS_Y=\(Int(appsCenter.y))
    DMG_README_X=\(Int(readmeCenter.x))
    DMG_README_Y=\(Int(readmeCenter.y))
    """)
    exit(0)
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write("""
    usage: dmg_background.swift <out.tiff> "<App Name>"
           dmg_background.swift --print-layout

    """.data(using: .utf8)!)
    exit(2)
}
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
let appName = CommandLine.arguments[2]

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("dmgbg-\(ProcessInfo.processInfo.processIdentifier)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let at1x = tmp.appendingPathComponent("bg.png")
let at2x = tmp.appendingPathComponent("bg@2x.png")
render(appName: appName, scale: 1, to: at1x)
render(appName: appName, scale: 2, to: at2x)

// A plain PNG renders blurry on Retina; -cathidpicheck packs both scales into
// one TIFF that Finder resolves per-display.
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
p.arguments = ["-cathidpicheck", at1x.path, at2x.path, "-out", outURL.path]
let errPipe = Pipe()
p.standardError = errPipe
p.standardOutput = FileHandle.nullDevice
try p.run()
let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
p.waitUntilExit()
guard p.terminationStatus == 0 else {
    FileHandle.standardError.write("ERROR: tiffutil failed:\n".data(using: .utf8)!)
    FileHandle.standardError.write(errData)
    exit(1)
}
print("wrote \(outURL.path) (\(Int(W))x\(Int(H)) @1x+@2x)")

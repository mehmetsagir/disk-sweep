import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// DiskSweep app icon generator.
// Usage: swift Support/make-icon.swift <output.png> [style 1-5]
// Style 2 (pie-chart disk with one lifted slice) is the shipped icon; 1, 3, 4 and 5 are
// alternative concepts (monogram, treemap, storage units, gauge).
// Then build the iconset (sips) and `iconutil -c icns` to produce Support/AppIcon.icns.
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let style = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 2 : 2
let size = 1024
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError() }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}
let center = CGPoint(x: 512, y: 512)
let half: CGFloat = 412

func squircle() -> CGPath {
    let path = CGMutablePath()
    for step in 0...360 {
        let t = CGFloat(step) / 360 * 2 * .pi
        let c = cos(t), s = sin(t)
        let p = CGPoint(x: center.x + half * (c < 0 ? -1 : 1) * pow(abs(c), 0.5),
                        y: center.y + half * (s < 0 ? -1 : 1) * pow(abs(s), 0.5))
        step == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}
let shape = squircle()

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

struct Theme { let top: UInt32; let bottom: UInt32; let rim: CGColor }
let themes: [Int: Theme] = [
    1: Theme(top: 0x14808A, bottom: 0x0B3B47, rim: color(0xFFFFFF, 0.18)),
    2: Theme(top: 0x262F42, bottom: 0x0B0F17, rim: color(0xFFFFFF, 0.14)),
    3: Theme(top: 0x1B2436, bottom: 0x0A0F1A, rim: color(0xFFFFFF, 0.14)),
    4: Theme(top: 0x4338CA, bottom: 0x1E1B4B, rim: color(0xFFFFFF, 0.18)),
    5: Theme(top: 0x2A2724, bottom: 0x0E0D0C, rim: color(0xFFFFFF, 0.14)),
]
let theme = themes[style]!

// Shared base: soft drop shadow, flat two-stop background, light top edge.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 30, color: color(0x000000, 0.5))
ctx.addPath(shape); ctx.setFillColor(color(theme.bottom)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
ctx.drawLinearGradient(gradient([color(theme.top), color(theme.bottom)], [0, 1]),
                       start: CGPoint(x: center.x - 200, y: center.y + half), end: CGPoint(x: center.x + 200, y: center.y - half), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)], [0, 1]),
                       start: CGPoint(x: center.x, y: center.y + half), end: CGPoint(x: center.x, y: center.y + 120), options: [])

func softShadow(_ blur: CGFloat = 18, _ alpha: CGFloat = 0.35, dy: CGFloat = -8) {
    ctx.setShadow(offset: CGSize(width: 0, height: dy), blur: blur, color: color(0x000000, alpha))
}

switch style {
case 1:
    // Monogram: a bold D whose counter holds a disk hub.
    let height: CGFloat = 440, r = height / 2, stroke: CGFloat = 92
    let straight: CGFloat = 130
    let x0 = 512 - (straight + r) / 2 - 8, yBottom = 512 - r, yTop = 512 + r
    let outer = CGMutablePath()
    outer.move(to: CGPoint(x: x0, y: yBottom))
    outer.addLine(to: CGPoint(x: x0, y: yTop))
    outer.addLine(to: CGPoint(x: x0 + straight, y: yTop))
    outer.addArc(center: CGPoint(x: x0 + straight, y: 512), radius: r, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
    outer.closeSubpath()
    let innerR = r - stroke
    let inner = CGMutablePath()
    inner.move(to: CGPoint(x: x0 + stroke, y: 512 - innerR))
    inner.addLine(to: CGPoint(x: x0 + stroke, y: 512 + innerR))
    inner.addLine(to: CGPoint(x: x0 + straight, y: 512 + innerR))
    inner.addArc(center: CGPoint(x: x0 + straight, y: 512), radius: innerR, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
    inner.closeSubpath()
    ctx.saveGState()
    softShadow(24, 0.35, dy: -10)
    ctx.addPath(outer); ctx.addPath(inner)
    ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
    // hub
    let hubCenter = CGPoint(x: x0 + stroke + (straight - stroke) / 2 + innerR * 0.55, y: 512)
    ctx.setFillColor(color(0xFFFFFF, 0.92)); ctx.fillEllipse(in: CGRect(x: hubCenter.x - 46, y: hubCenter.y - 46, width: 92, height: 92))
    ctx.setFillColor(color(0x0B3B47)); ctx.fillEllipse(in: CGRect(x: hubCenter.x - 15, y: hubCenter.y - 15, width: 30, height: 30))

case 2:
    // Pie disk: used / system / cache / one lifted accent slice (what can be removed).
    let radius: CGFloat = 330
    // The lifted slice pulls the visual weight up and to the left, so the pie sits a little low and right.
    let pieCenter = CGPoint(x: center.x + 14, y: center.y - 14)
    let slices: [(start: CGFloat, end: CGFloat, hex: UInt32, lift: CGFloat)] = [
        (90, -50, 0xE9EDF3, 0), (-50, -140, 0x98A3B6, 0), (-140, -190, 0x566178, 0), (-190, -270, 0x3B82F6, 32)]
    for slice in slices {
        let mid = (slice.start + slice.end) / 2 * .pi / 180
        let origin = CGPoint(x: pieCenter.x + cos(mid) * slice.lift, y: pieCenter.y + sin(mid) * slice.lift)
        let path = CGMutablePath()
        path.move(to: origin)
        path.addArc(center: origin, radius: radius, startAngle: slice.start * .pi / 180, endAngle: slice.end * .pi / 180, clockwise: true)
        path.closeSubpath()
        ctx.saveGState()
        softShadow(slice.lift > 0 ? 28 : 14, slice.lift > 0 ? 0.40 : 0.22)
        ctx.addPath(path); ctx.setFillColor(color(slice.hex)); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path); ctx.setStrokeColor(color(0x141A27)); ctx.setLineWidth(12); ctx.setLineJoin(.round); ctx.strokePath()
    }

case 3:
    // Treemap: the classic way to look at disk usage; one tile is highlighted.
    let area = CGRect(x: 232, y: 232, width: 560, height: 560)
    let gap: CGFloat = 14
    let leftW = area.width * 0.56 - gap / 2, rightW = area.width * 0.44 - gap / 2
    let aH = area.height * 0.62 - gap / 2, bH = area.height * 0.38 - gap / 2
    let cH = area.height * 0.36 - gap, dH = area.height * 0.30 - gap / 2, eH = area.height * 0.34 - gap / 2
    let tiles: [(CGRect, UInt32)] = [
        (CGRect(x: area.minX, y: area.maxY - aH, width: leftW, height: aH), 0x2A3C63),
        (CGRect(x: area.minX, y: area.minY, width: leftW, height: bH), 0x35507F),
        (CGRect(x: area.maxX - rightW, y: area.maxY - cH, width: rightW, height: cH), 0x3E5E96),
        (CGRect(x: area.maxX - rightW, y: area.maxY - cH - gap - dH, width: rightW, height: dH), 0xF59E0B),
        (CGRect(x: area.maxX - rightW, y: area.minY, width: rightW, height: eH), 0x30486F)]
    for (rect, hex) in tiles {
        let path = roundedRect(rect, 30)
        ctx.saveGState()
        softShadow(16, 0.35)
        ctx.addPath(path); ctx.setFillColor(color(hex)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)], [0, 1]),
                               start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])
        ctx.restoreGState()
    }

case 4:
    // Three storage units in a rack, only the top one reports in green.
    let barW: CGFloat = 560, barH: CGFloat = 132, gap: CGFloat = 38
    let alphas: [CGFloat] = [0.97, 0.80, 0.62]
    for index in 0..<3 {
        let y = 512 + CGFloat(1 - index) * (barH + gap) - barH / 2
        let rect = CGRect(x: 512 - barW / 2, y: y, width: barW, height: barH)
        let path = roundedRect(rect, 34)
        ctx.saveGState()
        softShadow(22, 0.40, dy: -10)
        ctx.addPath(path); ctx.setFillColor(color(0xFFFFFF, alphas[index])); ctx.fillPath()
        ctx.restoreGState()
        // label slot
        let slot = roundedRect(CGRect(x: rect.minX + 44, y: rect.midY - 11, width: 190, height: 22), 11)
        ctx.addPath(slot); ctx.setFillColor(color(0x1E1B4B, 0.22)); ctx.fillPath()
        // status light
        let led = CGRect(x: rect.maxX - 84, y: rect.midY - 17, width: 34, height: 34)
        ctx.saveGState()
        if index == 0 { ctx.setShadow(offset: .zero, blur: 22, color: color(0x34D399, 0.9)) }
        ctx.setFillColor(index == 0 ? color(0x34D399) : color(0x1E1B4B, 0.28))
        ctx.fillEllipse(in: led)
        ctx.restoreGState()
    }

default:
    // Gauge: instrument-style dial with ticks and a needle.
    let dial = CGPoint(x: 512, y: 470)
    let radius: CGFloat = 270
    func arc(_ start: CGFloat, _ sweep: CGFloat, _ stroke: CGColor, width: CGFloat) {
        ctx.setStrokeColor(stroke); ctx.setLineWidth(width); ctx.setLineCap(.round)
        ctx.addArc(center: dial, radius: radius, startAngle: start * .pi / 180, endAngle: (start - sweep) * .pi / 180, clockwise: true)
        ctx.strokePath()
    }
    arc(210, 240, color(0xFFFFFF, 0.14), width: 46)
    ctx.saveGState(); softShadow(16, 0.45)
    arc(210, 240 * 0.64, color(0xFFFFFF, 0.95), width: 46)
    ctx.restoreGState()
    // ticks
    for tick in 0...12 {
        let angle = (210 - CGFloat(tick) * 20) * .pi / 180
        let inner: CGFloat = radius + 46, outer: CGFloat = radius + (tick % 3 == 0 ? 78 : 64)
        ctx.setStrokeColor(color(0xFFFFFF, tick % 3 == 0 ? 0.55 : 0.28)); ctx.setLineWidth(tick % 3 == 0 ? 7 : 5); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: dial.x + cos(angle) * inner, y: dial.y + sin(angle) * inner))
        ctx.addLine(to: CGPoint(x: dial.x + cos(angle) * outer, y: dial.y + sin(angle) * outer))
        ctx.strokePath()
    }
    // needle
    let needleAngle = (210 - 240 * 0.64) * .pi / 180
    ctx.saveGState(); softShadow(14, 0.5)
    ctx.setStrokeColor(color(0xF97316)); ctx.setLineWidth(18); ctx.setLineCap(.round)
    ctx.move(to: dial)
    ctx.addLine(to: CGPoint(x: dial.x + cos(needleAngle) * 215, y: dial.y + sin(needleAngle) * 215))
    ctx.strokePath()
    ctx.restoreGState()
    ctx.setFillColor(color(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: dial.x - 40, y: dial.y - 40, width: 80, height: 80))
    ctx.setFillColor(color(0x2A2724)); ctx.fillEllipse(in: CGRect(x: dial.x - 14, y: dial.y - 14, width: 28, height: 28))
}
ctx.restoreGState()

ctx.addPath(shape); ctx.setStrokeColor(theme.rim); ctx.setLineWidth(3); ctx.strokePath()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest); print("ok \(style)")

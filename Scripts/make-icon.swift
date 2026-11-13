#!/usr/bin/env swift
import AppKit
import Foundation

let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    let s = CGFloat(size)

    let pad = s * 0.08
    let rect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    cg.saveGState()
    cg.addPath(path)
    cg.clip()

    // Dieter Rams warm titanium brushed chassis gradient
    let bgColors = [
        CGColor(red: 0.965, green: 0.960, blue: 0.945, alpha: 1.0),
        CGColor(red: 0.890, green: 0.882, blue: 0.850, alpha: 1.0)
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors, locations: [0.0, 1.0])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // Recessed white oscilloscope screen
    let screenRect = CGRect(x: s * 0.16, y: s * 0.22, width: s * 0.68, height: s * 0.58)
    let screenPath = CGPath(roundedRect: screenRect, cornerWidth: s * 0.08, cornerHeight: s * 0.08, transform: nil)
    cg.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
    cg.addPath(screenPath)
    cg.fillPath()
    cg.setStrokeColor(CGColor(red: 0.80, green: 0.78, blue: 0.74, alpha: 1.0))
    cg.setLineWidth(max(1, s * 0.014))
    cg.addPath(screenPath)
    cg.strokePath()

    // Amber oscilloscope waveform trace
    cg.setStrokeColor(CGColor(red: 0.788, green: 0.357, blue: 0.118, alpha: 1.0))
    cg.setLineWidth(max(1.5, s * 0.042))
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    let pts: [(CGFloat, CGFloat)] = [
        (0.21, 0.42), (0.33, 0.43), (0.41, 0.40), (0.49, 0.69),
        (0.56, 0.33), (0.63, 0.53), (0.71, 0.44), (0.79, 0.45)
    ]
    for (idx, pt) in pts.enumerated() {
        let p = CGPoint(x: s * pt.0, y: s * pt.1)
        if idx == 0 { cg.move(to: p) } else { cg.addLine(to: p) }
    }
    cg.strokePath()

    // Vermilion DVR playhead needle aligned to spike
    let needleX = s * 0.49
    cg.setStrokeColor(CGColor(red: 0.808, green: 0.231, blue: 0.141, alpha: 0.95))
    cg.setLineWidth(max(1.0, s * 0.022))
    cg.move(to: CGPoint(x: needleX, y: screenRect.minY + s * 0.03))
    cg.addLine(to: CGPoint(x: needleX, y: screenRect.maxY - s * 0.03))
    cg.strokePath()

    // Bottom titanium dial ticks
    let dotY = s * 0.145
    let colors: [CGColor] = [
        CGColor(red: 0.788, green: 0.357, blue: 0.118, alpha: 1.0),
        CGColor(red: 0.114, green: 0.337, blue: 0.651, alpha: 1.0),
        CGColor(red: 0.086, green: 0.455, blue: 0.345, alpha: 1.0),
        CGColor(red: 0.357, green: 0.259, blue: 0.604, alpha: 1.0)
    ]
    for (i, c) in colors.enumerated() {
        let cx = s * (0.32 + CGFloat(i) * 0.12)
        let r = s * 0.022
        cg.setFillColor(c)
        cg.fillEllipse(in: CGRect(x: cx - r, y: dotY - r, width: r * 2, height: r * 2))
    }

    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, px) in specs {
    try drawIcon(size: px).write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
}

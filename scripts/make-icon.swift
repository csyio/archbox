// Renders Resources/AppIcon.icns: a blue rounded square with a white peak.
// Usage: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS icon grid: 824 pt body centered in 1024, corner radius ~185.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(red: 0.13, green: 0.62, blue: 0.88, alpha: 1),
    NSColor(red: 0.04, green: 0.27, blue: 0.52, alpha: 1),
])!.draw(in: shape, angle: -90)

// A peak with a notch cut into its base.
let peak = NSBezierPath()
peak.move(to: NSPoint(x: 512, y: 790))
peak.line(to: NSPoint(x: 760, y: 250))
peak.line(to: NSPoint(x: 600, y: 250))
peak.curve(to: NSPoint(x: 424, y: 250),
           controlPoint1: NSPoint(x: 560, y: 420), controlPoint2: NSPoint(x: 464, y: 420))
peak.line(to: NSPoint(x: 264, y: 250))
peak.close()
NSColor.white.setFill()
peak.fill()

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = iconset.appendingPathComponent("master.png")
try! png.write(to: master)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        task.arguments = ["-z", "\(pixels)", "\(pixels)", master.path, "--out", iconset.appendingPathComponent(name).path]
        task.standardOutput = FileHandle.nullDevice
        try! task.run()
        task.waitUntilExit()
    }
}
try! FileManager.default.removeItem(at: master)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print("Wrote Resources/AppIcon.icns")

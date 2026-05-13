import AppKit

let outputDir: URL = {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("assets", isDirectory: true)
}()

let pointSize = CGSize(width: 18, height: 18)
let pixelSize = CGSize(width: 36, height: 36)

func drawIcon(showRearCard: Bool) throws -> NSBitmapImageRep {
    guard let ctx = CGContext(
        data: nil,
        width: Int(pixelSize.width),
        height: Int(pixelSize.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
        throw NSError(domain: "MenuIconGen", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to create bitmap context"
        ])
    }

    ctx.clear(CGRect(origin: .zero, size: pixelSize))
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: pixelSize.width / pointSize.width, y: pixelSize.height / pointSize.height)

    if showRearCard {
        let rearRect = CGRect(x: 5.2, y: 3.2, width: 8.8, height: 7.4)
        let rearPath = CGPath(
            roundedRect: rearRect,
            cornerWidth: 2.2,
            cornerHeight: 2.2,
            transform: nil)

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.22).cgColor)
        ctx.addPath(rearPath)
        ctx.fillPath()

        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.38).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(rearPath)
        ctx.strokePath()

        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.34).cgColor)
        ctx.setLineWidth(0.9)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 7.2, y: 6.1))
        ctx.addLine(to: CGPoint(x: 11.8, y: 6.1))
        ctx.strokePath()
    }

    let frontRect = CGRect(x: 3.0, y: 6.4, width: 9.8, height: 8.4)
    let frontPath = CGPath(
        roundedRect: frontRect,
        cornerWidth: 2.4,
        cornerHeight: 2.4,
        transform: nil)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.addPath(frontPath)
    ctx.fillPath()

    ctx.saveGState()
    ctx.setBlendMode(.clear)
    ctx.setLineWidth(1.5)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 5.8, y: 10.6))
    ctx.addLine(to: CGPoint(x: 10.2, y: 10.6))
    ctx.strokePath()

    let markerRect = CGRect(x: 4.45, y: 9.65, width: 1.9, height: 1.9)
    ctx.fillEllipse(in: markerRect)
    ctx.restoreGState()

    guard let cgImage = ctx.makeImage() else {
        throw NSError(domain: "MenuIconGen", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to create CGImage"
        ])
    }

    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: pointSize.width, height: pointSize.height)
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MenuIconGen", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to encode PNG at \(url.path)"
        ])
    }

    try data.write(to: url, options: .atomic)
}

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
try writePNG(
    drawIcon(showRearCard: true),
    to: outputDir.appendingPathComponent("codex-profile-switcher-menu-icon.png"))
try writePNG(
    drawIcon(showRearCard: false),
    to: outputDir.appendingPathComponent("codex-profile-switcher-menu-icon-empty.png"))

print("Wrote icons to \(outputDir.path)")

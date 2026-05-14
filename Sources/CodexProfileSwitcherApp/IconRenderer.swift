import Cocoa
import Foundation

enum IconRenderer {
    static let iconSize = CGSize(width: 18, height: 18)
    private static let scale: CGFloat = 2
    private static let filledIconName = "codex-profile-switcher-menu-icon.png"
    private static let emptyIconName = "codex-profile-switcher-menu-icon-empty.png"

    static func render(primaryPercent: Int, secondaryPercent: Int) -> NSImage {
        Self.loadIcon(named: Self.filledIconName)
            ?? Self.renderStackedProfiles(showRearCard: true)
    }

    static func renderEmpty() -> NSImage {
        Self.loadIcon(named: Self.emptyIconName)
            ?? Self.renderStackedProfiles(showRearCard: false)
    }

    private static func loadIcon(named name: String) -> NSImage? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent(name)
        ].compactMap { $0 }

        for url in candidates {
            guard let image = NSImage(contentsOf: url) else { continue }
            image.size = Self.iconSize
            image.isTemplate = true
            return image
        }

        return nil
    }

    private static func renderStackedProfiles(showRearCard: Bool) -> NSImage {
        let size = Self.iconSize

        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: Self.scale, y: Self.scale)
            if showRearCard {
                Self.drawRearCard(ctx: ctx)
            }
            Self.drawFrontCard(ctx: ctx)

            return true
        }

        image.isTemplate = true
        return image
    }

    private static func drawRearCard(ctx: CGContext) {
        let rearRect = CGRect(x: 5.2, y: 3.2, width: 8.8, height: 7.4)
        let rearPath = CGPath(roundedRect: rearRect, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.addPath(rearPath)
        ctx.fillPath()

        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setLineWidth(1.1)
        ctx.addPath(rearPath)
        ctx.strokePath()

        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setLineWidth(1.1)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 7.3, y: 6.2))
        ctx.addLine(to: CGPoint(x: 11.7, y: 6.2))
        ctx.strokePath()
    }

    private static func drawFrontCard(ctx: CGContext) {
        let frontRect = CGRect(x: 3.0, y: 6.4, width: 9.8, height: 8.4)
        let frontPath = CGPath(roundedRect: frontRect, cornerWidth: 2.4, cornerHeight: 2.4, transform: nil)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(frontPath)
        ctx.fillPath()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 5.8, y: 10.6))
        ctx.addLine(to: CGPoint(x: 10.1, y: 10.6))
        ctx.strokePath()

        let markerRect = CGRect(x: 4.45, y: 9.65, width: 1.9, height: 1.9)
        let markerPath = CGPath(ellipseIn: markerRect, transform: nil)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(markerPath)
        ctx.fillPath()
    }
}

// MARK: - CodexBridge

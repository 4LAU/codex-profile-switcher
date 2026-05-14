import Cocoa
import Foundation

enum IconRenderer {
    private static let iconHeight: CGFloat = 18
    private static let emptyIconSize = CGSize(width: 18, height: 18)
    private static let scale: CGFloat = 2
    private static let emptyIconName = "codex-profile-switcher-menu-icon-empty.png"

    // MARK: - Public

    static func render(primaryPercent: Int, secondaryPercent: Int) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]

        let topStr = NSAttributedString(string: String(format: "%02d", primaryPercent), attributes: attrs)
        let bottomStr = NSAttributedString(string: String(format: "%02d", secondaryPercent), attributes: attrs)
        let topSize = topStr.size()
        let bottomSize = bottomStr.size()

        let topUrgency = Urgency(percent: primaryPercent)
        let bottomUrgency = Urgency(percent: secondaryPercent)

        let topPadded = Self.paddedSize(topSize, urgency: topUrgency)
        let bottomPadded = Self.paddedSize(bottomSize, urgency: bottomUrgency)

        let contentWidth = max(topPadded.width, bottomPadded.width)
        let contentHeight = topPadded.height + bottomPadded.height
        let margin: CGFloat = 1
        let imageWidth = ceil(contentWidth + margin * 2)
        let size = NSSize(width: imageWidth, height: Self.iconHeight)

        let topY = (Self.iconHeight - contentHeight) / 2
        let bottomY = topY + topPadded.height

        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let rightEdge = imageWidth - margin

            Self.drawRow(attrStr: topStr, textSize: topSize, urgency: topUrgency,
                         rightEdge: rightEdge, y: topY, in: ctx)
            Self.drawRow(attrStr: bottomStr, textSize: bottomSize, urgency: bottomUrgency,
                         rightEdge: rightEdge, y: bottomY, in: ctx)

            return true
        }

        image.isTemplate = true
        return image
    }

    static func renderEmpty() -> NSImage {
        Self.loadIcon(named: Self.emptyIconName)
            ?? Self.renderFallbackEmpty()
    }

    // MARK: - Urgency

    private enum Urgency {
        case normal, warning, critical

        init(percent: Int) {
            if percent >= 95 { self = .critical }
            else if percent >= 80 { self = .warning }
            else { self = .normal }
        }

        var boxPadding: (h: CGFloat, v: CGFloat)? {
            switch self {
            case .normal: return nil
            case .warning: return (h: 1.5, v: 1.0)
            case .critical: return (h: 2.0, v: 1.5)
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .normal: return 0
            case .warning: return 2.0
            case .critical: return 2.5
            }
        }
    }

    // MARK: - Row Drawing

    private static func paddedSize(_ textSize: CGSize, urgency: Urgency) -> CGSize {
        guard let p = urgency.boxPadding else { return textSize }
        return CGSize(width: textSize.width + p.h * 2, height: textSize.height + p.v * 2)
    }

    private static func drawRow(
        attrStr: NSAttributedString,
        textSize: CGSize,
        urgency: Urgency,
        rightEdge: CGFloat,
        y: CGFloat,
        in ctx: CGContext
    ) {
        guard let padding = urgency.boxPadding else {
            attrStr.draw(at: NSPoint(x: rightEdge - textSize.width, y: y))
            return
        }

        let boxWidth = textSize.width + padding.h * 2
        let boxHeight = textSize.height + padding.v * 2
        let boxX = rightEdge - boxWidth
        let boxRect = CGRect(x: boxX, y: y, width: boxWidth, height: boxHeight)
        let boxPath = CGPath(
            roundedRect: boxRect,
            cornerWidth: urgency.cornerRadius,
            cornerHeight: urgency.cornerRadius,
            transform: nil)

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(boxPath)
        ctx.fillPath()
        ctx.setBlendMode(.clear)
        attrStr.draw(at: NSPoint(x: boxX + padding.h, y: y + padding.v))
        ctx.restoreGState()
    }

    // MARK: - Empty Icon

    private static func loadIcon(named name: String) -> NSImage? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent(name),
        ].compactMap { $0 }

        for url in candidates {
            guard let image = NSImage(contentsOf: url) else { continue }
            image.size = Self.emptyIconSize
            image.isTemplate = true
            return image
        }

        return nil
    }

    private static func renderFallbackEmpty() -> NSImage {
        let size = Self.emptyIconSize

        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: Self.scale, y: Self.scale)
            Self.drawFrontCard(ctx: ctx)
            return true
        }

        image.isTemplate = true
        return image
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

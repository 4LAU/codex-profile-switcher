import Cocoa
import CodexProfileCore
import SwiftUI

func resetCountdown(from date: Date?) -> String {
    guard let date, date > Date() else { return "" }
    let diff = Int(date.timeIntervalSinceNow)
    let days = diff / 86400
    let hours = (diff % 86400) / 3600
    let mins = (diff % 3600) / 60
    if days > 0 { return "\(days)d\(hours)h" }
    if hours > 0 { return "\(hours)h\(mins)m" }
    return "\(mins)m"
}

enum Palette {
    static let accent = Color(red: 0.40, green: 0.55, blue: 0.75)
    static let accentLight = Color(red: 0.45, green: 0.58, blue: 0.72)
    static let success = Color(red: 0.40, green: 0.60, blue: 0.55)
    static let warning = Color(red: 0.75, green: 0.55, blue: 0.30)
    static let danger = Color(red: 0.75, green: 0.38, blue: 0.35)
    static let mid = Color(red: 0.70, green: 0.55, blue: 0.35)
}

func progressColor(for percent: Int) -> Color {
    if percent >= 90 { return Palette.danger }
    if percent >= 70 { return Palette.mid }
    return Palette.success
}

func usageWindowLabel(durationMins: Int?, legacyLabel: String) -> String {
    guard let durationMins, durationMins > 0 else { return legacyLabel }
    if durationMins == 7 * 24 * 60 { return "Wk" }
    if durationMins % (24 * 60) == 0 { return "\(durationMins / (24 * 60))d" }
    if durationMins % 60 == 0 { return "\(durationMins / 60)h" }
    return "\(durationMins)m"
}

func planDisplayName(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return "" }
    switch raw {
    case "pro": return "Pro"
    case "plus": return "Plus"
    case "team": return "Team"
    case "business": return "Business"
    case "enterprise": return "Enterprise"
    case "free": return "Free"
    case "edu", "education": return "Edu"
    default: return raw.capitalized
    }
}

func creditsDisplayName(_ value: Double?) -> String? {
    guard let value else { return nil }
    let clamped = max(0, value)
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = clamped >= 100 ? 0 : 1
    formatter.minimumFractionDigits = 0
    guard let formatted = formatter.string(from: NSNumber(value: clamped)) else { return nil }
    return "\(formatted) cr"
}

// MARK: - Toast

enum ToastStyle { case success, error, info }

final class ToastState: ObservableObject {
    @Published var message: String = ""
    @Published var style: ToastStyle = .success
    @Published var isVisible: Bool = false
    private var hideTask: DispatchWorkItem?

    func show(_ message: String, style: ToastStyle = .success) {
        self.hideTask?.cancel()
        self.message = message
        self.style = style
        withAnimation(.easeOut(duration: 0.2)) { self.isVisible = true }
        let item = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.3)) { self?.isVisible = false }
        }
        self.hideTask = item
        let duration = style == .error ? 7.0 : 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }
}

struct ToastOverlay: View {
    @ObservedObject var state: ToastState

    var body: some View {
        if self.state.isVisible {
            VStack {
                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: self.iconName)
                        .font(.system(size: 11, weight: .semibold))
                    Text(self.state.message)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                }
                .foregroundStyle(self.foregroundColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(self.borderColor, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            }
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var iconName: String {
        switch self.state.style {
        case .success: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var foregroundColor: Color {
        switch self.state.style {
        case .success: Palette.success
        case .error: Palette.danger
        case .info: Palette.accent
        }
    }

    private var borderColor: Color {
        switch self.state.style {
        case .success: Palette.success.opacity(0.3)
        case .error: Palette.danger.opacity(0.3)
        case .info: Palette.accent.opacity(0.3)
        }
    }
}

// MARK: - SwiftUI Views (progress bar adapted from codexbar)

struct UsageBar: View {
    let percent: Double
    let tint: Color

    private static let markerPercents: [Double] = [25, 50, 75]

    var body: some View {
        Canvas { context, size in
            let fillWidth = size.width * min(100, max(0, self.percent)) / 100
            let cornerRadius = size.height / 2
            let cornerSize = CGSize(width: cornerRadius, height: cornerRadius)
            let rect = CGRect(origin: .zero, size: size)

            let trackPath = Path { p in p.addRoundedRect(in: rect, cornerSize: cornerSize) }
            context.fill(trackPath, with: .color(.primary.opacity(0.10)))

            if fillWidth > 0 {
                let fillRect = CGRect(x: 0, y: 0, width: min(fillWidth, size.width), height: size.height)
                let fillPath = Path { p in p.addRoundedRect(in: fillRect, cornerSize: cornerSize) }
                context.fill(fillPath, with: .color(self.tint))
            }

            let markerWidth: CGFloat = 1.5
            for markerPct in Self.markerPercents {
                let x = size.width * markerPct / 100
                let markerRect = CGRect(x: x - markerWidth / 2, y: 0, width: markerWidth, height: size.height)
                context.fill(Path(markerRect), with: .color(.primary.opacity(0.3)))
            }
        }
        .frame(height: 6)
    }
}

struct UsageRow: View {
    let label: String
    let percent: Int
    let resetAt: Date?
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(self.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(self.isHighlighted ? .secondary : .tertiary)
                .frame(width: 16, alignment: .leading)

            UsageBar(percent: Double(self.percent), tint: progressColor(for: self.percent))

            Text("\(self.percent)%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(self.isHighlighted ? .primary : .secondary)
                .frame(width: 30, alignment: .trailing)

            Text(resetCountdown(from: self.resetAt))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(self.isHighlighted ? .secondary : .tertiary)
                .frame(width: 42, alignment: .trailing)
        }
    }
}

struct ProfileCardView: View {
    let profile: ProfileConfig
    let status: ProfileStatus
    let isActive: Bool
    let duplicateLine: String?
    let onSwitch: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: self.onSwitch) {
            VStack(alignment: .leading, spacing: 4) {
                self.headerRow
                if let duplicateLine, !duplicateLine.isEmpty {
                    Label(duplicateLine, systemImage: "square.stack.3d.up.trianglebadge.exclamationmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.warning)
                        .lineLimit(1)
                }
                self.statusContent
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 290, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(ProfileCardButtonStyle(
            isActive: self.isActive,
            isHovered: self.isHovered,
            colorScheme: self.colorScheme))
        .onHover { hovering in
            self.isHovered = hovering
        }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.16), value: self.isHovered)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text(self.profile.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(self.titleColor)
                .lineLimit(1)

            Spacer()

            HStack(spacing: 5) {
                if let credits = self.credits {
                    Text(credits)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(self.metadataColor)
                }

                if let planName = self.planType {
                    Text(planName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(self.metadataColor)
                }
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch self.status {
        case .available(let snap):
            self.usageBars(snap)
        case .loading:
            Text("Refreshing...")
                .font(.system(size: 10))
                .foregroundStyle(self.metadataColor)
        case .stale(let snap):
            if let snap {
                self.usageBars(snap)
            } else {
                Text("No data yet")
                    .font(.system(size: 10))
                    .foregroundStyle(self.metadataColor)
            }
        case .reloginNeeded(let snap):
            if let snap { self.usageBars(snap) }
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text("Re-login needed")
                    .font(.system(size: 10))
            }
            .foregroundStyle(Palette.warning)
        case .notSetUp:
            Text("Click to set up")
                .font(.system(size: 10))
                .foregroundStyle(Palette.accentLight)
        }
    }

    private func usageBars(_ snap: UsageSnapshot) -> some View {
        VStack(spacing: 2) {
            if self.hasPrimaryWindow(snap) {
                UsageRow(
                    label: usageWindowLabel(
                        durationMins: snap.primaryWindowDurationMins,
                        legacyLabel: "5h"),
                    percent: snap.primaryUsedPercent,
                    resetAt: snap.primaryResetAt,
                    isHighlighted: self.isActive || self.isHovered)
            }
            if self.hasSecondaryWindow(snap) {
                UsageRow(
                    label: usageWindowLabel(
                        durationMins: snap.secondaryWindowDurationMins,
                        legacyLabel: "Wk"),
                    percent: snap.secondaryUsedPercent,
                    resetAt: snap.secondaryResetAt,
                    isHighlighted: self.isActive || self.isHovered)
            }
        }
    }

    private func hasPrimaryWindow(_ snap: UsageSnapshot) -> Bool {
        snap.primaryWindowDurationMins != nil || snap.primaryResetAt != nil || snap.primaryUsedPercent > 0
    }

    private func hasSecondaryWindow(_ snap: UsageSnapshot) -> Bool {
        snap.secondaryWindowDurationMins != nil || snap.secondaryResetAt != nil || snap.secondaryUsedPercent > 0
    }

    private var planType: String? {
        guard let snap = self.status.snapshot else { return nil }
        return planDisplayName(snap.planType)
    }

    private var credits: String? {
        guard let snap = self.status.snapshot else { return nil }
        return creditsDisplayName(snap.creditsRemaining)
    }

    private var titleColor: Color {
        let base = Color(nsColor: .labelColor)
        return self.isActive || self.isHovered ? base : base.opacity(0.94)
    }

    private var metadataColor: Color {
        let base = Color(nsColor: .secondaryLabelColor)
        return self.isActive || self.isHovered ? base : base.opacity(0.82)
    }
}

private struct ProfileCardButtonStyle: ButtonStyle {
    let isActive: Bool
    let isHovered: Bool
    let colorScheme: ColorScheme

    func makeBody(configuration: Configuration) -> some View {
        let visualState = ProfileCardVisualState(
            isActive: self.isActive,
            isHovered: self.isHovered,
            isPressed: configuration.isPressed,
            colorScheme: self.colorScheme)

        return configuration.label
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(visualState.fillColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(visualState.borderColor, lineWidth: visualState.borderWidth)
            }
    }
}

private struct ProfileCardVisualState {
    let isActive: Bool
    let isHovered: Bool
    let isPressed: Bool
    let colorScheme: ColorScheme

    var fillColor: Color {
        if self.isPressed {
            return self.neutralWash(dark: 0.14, light: 0.10)
        }
        if self.isActive && self.isHovered {
            return self.neutralWash(dark: 0.13, light: 0.085)
        }
        if self.isActive {
            return self.accentedWash(dark: 0.085, light: 0.055)
        }
        if self.isHovered {
            return self.neutralWash(dark: 0.085, light: 0.055)
        }
        return .clear
    }

    var borderColor: Color {
        if self.isPressed {
            return Palette.accent.opacity(self.colorScheme == .dark ? 0.26 : 0.22)
        }
        if self.isActive {
            return Palette.accent.opacity(self.colorScheme == .dark ? 0.22 : 0.18)
        }
        if self.isHovered {
            return Color.primary.opacity(self.colorScheme == .dark ? 0.12 : 0.08)
        }
        return .clear
    }

    var borderWidth: CGFloat {
        (self.isActive || self.isHovered || self.isPressed) ? 1 : 0
    }

    private func neutralWash(dark: Double, light: Double) -> Color {
        Color.primary.opacity(self.colorScheme == .dark ? dark : light)
    }

    private func accentedWash(dark: Double, light: Double) -> Color {
        Palette.accent.opacity(self.colorScheme == .dark ? dark : light)
    }
}

// MARK: - Menu Bar Icon

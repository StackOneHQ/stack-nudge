import SwiftUI

// Pill-shaped glance widget. Layout left→right:
//   [gauge]  [7d%, reset-in]  |  [headline: project · tokens · status]
//   [active count badge]  [expand]
//
// Gauge = full-circle 5h-quota meter with angular gradient stroke
// (green→red), pulsing inner glow when any session is busy, center
// digital % readout, and a sweeping spinner dot when actively polling.
// Glass background with soft cyan border glow.
struct CompactView: View {

    @ObservedObject var store: EventStore
    @ObservedObject var sessions: SessionStore
    @ObservedObject var nav: PanelNav

    let onExpand: () -> Void
    let onExitCompact: () -> Void

    @State private var rippleScale: CGFloat = 0.3
    @State private var rippleOpacity: Double = 0
    @State private var isHovering: Bool = false

    private static let glowColor = Color(red: 0.4, green: 0.85, blue: 1.0)
    private static let recentEventWindow: TimeInterval = 5 * 60

    var body: some View {
        HStack(spacing: 10) {
            gaugeCluster
            separator
            headline
            Spacer(minLength: 4)
            sessionBadge
            expandButton
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pillBackground)
        .overlay(ripple)
        .contentShape(Capsule())
        .onTapGesture(count: 2) { onExitCompact() }
        .onChange(of: store.events.first?.id) { _ in triggerRipple() }
        // Hover state drives per-mascot reactions (robot antenna flick,
        // cat wink + ear twitch, eye pupil dilate-and-dart, ghost
        // pop-and-yawn). Gated on pill mode inside each mascot.
        .onHover { isHovering = $0 }
    }

    private var mascotHovered: Bool {
        isHovering && !nav.compactExpanded
    }

    // Soft outward wave on event arrival. Capsule scales from 0.3 → 1.15
    // and fades from 0.45 → 0 over ~600ms, drawn under the pill content
    // so it reads as "the pill pulsed" rather than a separate overlay.
    private var ripple: some View {
        Capsule()
            .stroke(urgencyColor, lineWidth: 1.5)
            .scaleEffect(rippleScale)
            .opacity(rippleOpacity)
            .allowsHitTesting(false)
    }

    private func triggerRipple() {
        rippleScale = 0.6
        rippleOpacity = 0.55
        withAnimation(.easeOut(duration: 0.7)) {
            rippleScale = 1.18
            rippleOpacity = 0
        }
    }

    // MARK: - Gauge cluster (5h gauge + 7d + reset countdown)

    private var gaugeCluster: some View {
        HStack(spacing: 6) {
            ZStack {
                if !nav.compactDragging {
                    Circle()
                        .fill(urgencyColor.opacity(0.18))
                        .frame(width: 44, height: 44)
                        .blur(radius: 8)
                }
                QuotaGauge(
                    fivePct:  nav.quota?.fiveHour?.utilization ?? 0,
                    sevenPct: nav.quota?.sevenDay?.utilization ?? 0,
                    hasFive:  nav.quota?.fiveHour != nil,
                    hasSeven: nav.quota?.sevenDay != nil,
                    polling:  nav.quotaSyncing,
                    anyBusy:  anyBusy,
                    paused:   nav.compactDragging,
                    showRemaining: nav.quotaShowRemaining
                )
                .frame(width: 42, height: 42)
            }

            if let reset = nav.quota?.fiveHour?.resetsAt {
                Text(Self.shortDuration(until: reset))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Headline

    @ViewBuilder
    private var headline: some View {
        HStack(spacing: 6) {
            BotMascot(state: botState, kind: nav.mascot, paused: nav.compactDragging, hovered: mascotHovered)
                .frame(width: 26, height: 24)
            headlineText
        }
    }

    @ViewBuilder
    private var headlineText: some View {
        if let busy = busiestSession {
            HStack(spacing: 4) {
                Text(displayName(busy))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let stats = transcriptStats(for: busy) {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(Self.formatTokens(stats.tokens))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } else if let recent = recentEvent {
            HStack(spacing: 4) {
                Text(recent.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("·")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                // Adaptive: pending count when the queue has built up,
                // otherwise show age of the latest event so the user can
                // gauge whether it's fresh.
                if store.events.count > 1 {
                    Text("×\(store.events.count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Text(Self.relative.localizedString(for: recent.timestamp, relativeTo: Date()))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else if let active = mostRecentActive {
            Text(displayName(active))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        } else {
            Text("watching")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var botState: BotState {
        if let _ = recentEvent {
            // Most recent event drives expression briefly
            switch store.events.first?.kind {
            case .permission: return .alert
            case .stop:       return .happy
            default:          return .alert
            }
        }
        if busiestSession != nil { return .busy }
        if mostRecentActive != nil { return .watching }
        return .idle
    }

    // MARK: - Right side

    @ViewBuilder
    private var sessionBadge: some View {
        let activeCount = sessions.sessions.filter { $0.status == .active }.count
        if activeCount > 0 {
            HStack(spacing: 3) {
                Circle()
                    .fill(anyBusy ? Color.yellow : Color.green)
                    .frame(width: 6, height: 6)
                Text("\(activeCount)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }
        }
    }

    private var expandButton: some View {
        Button(action: onExpand) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.22))
            .frame(width: 1, height: 22)
    }

    // MARK: - Background + outer glow

    @ViewBuilder
    private var pillBackground: some View {
        if nav.compactDragging {
            // Static render while dragging — frees the main thread for
            // AppKit's drag handler so the pill keeps up with the cursor.
            staticPillBackground
        } else {
            animatedPillBackground
        }
    }

    private var staticPillBackground: some View {
        let color = urgencyColor
        return ZStack {
            Capsule().fill(.regularMaterial)
            Capsule().strokeBorder(color.opacity(0.55), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.30), radius: 6, y: 2)
    }

    private var animatedPillBackground: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { tl in
            let pulse = pulseAmount(at: tl.date)
            let color = urgencyColor
            ZStack {
                Capsule().fill(.regularMaterial)
                Capsule()
                    .strokeBorder(color.opacity(0.45 + 0.3 * pulse), lineWidth: 0.8)
                Capsule()
                    .stroke(color.opacity(0.20 + 0.25 * pulse), lineWidth: 3)
                    .blur(radius: 4)
            }
            .shadow(color: .black.opacity(0.30), radius: 10, y: 3)
            .animation(.easeInOut(duration: 0.6), value: color)
        }
    }

    // Border color tracks 5h quota urgency: cyan under 75%, amber 75–90%,
    // red 90%+. Pulse rate climbs with severity so red-state pill is
    // visibly more urgent than amber.
    private var urgencyColor: Color {
        let pct = nav.quota?.fiveHour?.utilization ?? 0
        if pct >= 90 { return .red }
        if pct >= 75 { return .orange }
        return Self.glowColor
    }

    private func pulseAmount(at date: Date) -> Double {
        let pct = nav.quota?.fiveHour?.utilization ?? 0
        let busyPulse = anyBusy
        guard busyPulse || pct >= 75 else { return 0 }
        let speed: Double = pct >= 90 ? 4.5 : pct >= 75 ? 3.2 : 2.4
        let t = date.timeIntervalSinceReferenceDate
        return (sin(t * speed) + 1) / 2
    }

    // MARK: - Data helpers

    private var anyBusy: Bool {
        sessions.sessions.contains { $0.claudeStatus == "busy" }
    }

    private var recentEvent: NudgeEvent? {
        guard let e = store.events.first,
              Date().timeIntervalSince(e.timestamp) < Self.recentEventWindow
        else { return nil }
        return e
    }

    private var busiestSession: Session? {
        sessions.sessions.first { $0.status == .active && $0.claudeStatus == "busy" }
    }

    private var mostRecentActive: Session? {
        sessions.sessions.first { $0.status == .active }
    }

    private func transcriptStats(for s: Session) -> TranscriptStats? {
        guard let id = s.claudeSessionID else { return nil }
        return nav.claudeSessionStats[id]
    }

    private func displayName(_ s: Session) -> String {
        if let custom = s.customName, !custom.isEmpty { return custom }
        if let name = s.claudeName, !name.isEmpty, name != "main-agent" { return name }
        return s.projectName ?? "session"
    }

    private func glyph(for e: NudgeEvent) -> String {
        switch e.kind {
        case .permission: return "questionmark.circle.fill"
        case .stop:       return "checkmark.circle.fill"
        case .other:      return "bell.fill"
        }
    }

    fileprivate static func gaugeColor(pct: Double) -> Color {
        if pct >= 90 { return .red }
        if pct >= 75 { return .orange }
        if pct >= 50 { return .yellow }
        return Color(red: 0.4, green: 0.85, blue: 1.0)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
        if n >= 1_000 {
            return "\(Int((Double(n) / 1_000).rounded()))K"
        }
        return "\(n)"
    }

    private static func shortDuration(until date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        if s >= 3600 {
            let h = s / 3600
            let m = (s % 3600) / 60
            return m > 0 ? "\(h)h\(m)m" : "\(h)h"
        }
        return "\(max(1, s / 60))m"
    }
}

// Concentric quota gauge: outer ring = 7d utilization, inner ring = 5h.
// Each fills clockwise from 12 o'clock with its own angular gradient
// (cyan → yellow → orange → red). Inner glow pulses on busy sessions.
// A spinner dot orbits the outer ring when actively polling. Center
// shows the 5h % since that's the more immediate concern.
private struct QuotaGauge: View {

    let fivePct: Double
    let sevenPct: Double
    let hasFive: Bool
    let hasSeven: Bool
    let polling: Bool
    let anyBusy: Bool
    let paused: Bool
    let showRemaining: Bool

    private static let cyan = Color(red: 0.30, green: 0.92, blue: 1.0)
    private static let outerLineWidth: CGFloat = 4.0
    private static let innerLineWidth: CGFloat = 4.0
    private static let ringGap: CGFloat = 5.0

    var body: some View {
        if paused {
            // Static render — no TimelineView re-ticks during drag.
            ZStack {
                outerTrack
                innerTrack
                if hasSeven { outerFill }
                if hasFive  { innerFill }
                centerReadout
            }
        } else {
            TimelineView(.animation(minimumInterval: 0.05)) { tl in
                ZStack {
                    outerTrack
                    innerTrack
                    if hasSeven { outerFill }
                    if hasFive  { innerFill }
                    innerGlow(at: tl.date)
                    centerReadout
                    if polling { spinnerDot(at: tl.date) }
                }
                .animation(.easeOut(duration: 0.45), value: fivePct)
                .animation(.easeOut(duration: 0.45), value: sevenPct)
            }
        }
    }

    private var outerTrack: some View {
        Circle()
            .stroke(Color.secondary.opacity(0.16), lineWidth: Self.outerLineWidth)
            .padding(Self.outerLineWidth / 2)
    }

    private var innerTrack: some View {
        Circle()
            .stroke(Color.secondary.opacity(0.14), lineWidth: Self.innerLineWidth)
            .padding(Self.outerLineWidth + Self.ringGap)
    }

    private var outerFill: some View {
        Circle()
            .trim(from: 0, to: max(0, min(1, sevenPct / 100)))
            .stroke(gradient, style: StrokeStyle(lineWidth: Self.outerLineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(Self.outerLineWidth / 2)
    }

    private var innerFill: some View {
        Circle()
            .trim(from: 0, to: max(0, min(1, fivePct / 100)))
            .stroke(gradient, style: StrokeStyle(lineWidth: Self.innerLineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(Self.outerLineWidth + Self.ringGap)
    }

    private var gradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: Self.cyan,  location: 0.0),
                .init(color: .yellow,    location: 0.55),
                .init(color: .orange,    location: 0.80),
                .init(color: .red,       location: 1.0),
            ]),
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
    }

    private func innerGlow(at date: Date) -> some View {
        let t = date.timeIntervalSinceReferenceDate
        let pulse = anyBusy ? (sin(t * 2.4) + 1) / 2 : 0
        let intensity = 0.22 + 0.45 * pulse
        return Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: [Self.cyan.opacity(intensity), .clear]),
                    center: .center,
                    startRadius: 0,
                    endRadius: 22
                )
            )
            .padding(Self.outerLineWidth + Self.ringGap + 2)
    }

    private var centerReadout: some View {
        // Ring still fills with "used" so the urgency-colored gradient
        // (green→red as it grows) keeps its meaning. Only the number in
        // the middle flips: 30% used ↔ 70% (remaining).
        let pct = showRemaining ? max(0, 100 - fivePct) : fivePct
        return Text(hasFive ? "\(Int(pct.rounded()))" : "—")
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .foregroundStyle(.primary)
    }

    private func spinnerDot(at date: Date) -> some View {
        let t = date.timeIntervalSinceReferenceDate
        let angle = (t * 180).truncatingRemainder(dividingBy: 360)
        return Circle()
            .fill(Self.cyan)
            .frame(width: 3, height: 3)
            .offset(y: -15)
            .rotationEffect(.degrees(angle))
    }
}

enum BotState {
    case idle      // no sessions, no recent events
    case watching  // sessions exist but nothing happening
    case busy      // a session is busy
    case alert     // recent permission event
    case happy     // recent stop event
}

// Dispatcher: picks the user-chosen mascot kind. Each mascot owns its
// own SwiftUI rendering and expression-state mapping.
private struct BotMascot: View {

    let state: BotState
    let kind: MascotKind
    let paused: Bool
    let hovered: Bool

    var body: some View {
        switch kind {
        case .robot: RobotMascot(state: state, paused: paused, hovered: hovered)
        case .cat:   CatMascot(state: state, paused: paused, hovered: hovered)
        case .eye:   EyeMascot(state: state, paused: paused, hovered: hovered)
        case .ghost: GhostMascot(state: state, paused: paused, hovered: hovered)
        }
    }
}

private struct RobotMascot: View {

    let state: BotState
    let paused: Bool
    let hovered: Bool

    private static let cyan = Color(red: 0.4, green: 0.85, blue: 1.0)
    private static let outline = Color.secondary.opacity(0.7)

    var body: some View {
        if paused {
            // Static: no blink, no antenna pulse, no TimelineView ticks.
            ZStack {
                head
                staticAntenna
                staticEyes
                mouth
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TimelineView(.animation(minimumInterval: 0.05)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                ZStack {
                    head
                    antenna(at: t)
                    eyes(at: t)
                    mouth
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var staticAntenna: some View {
        VStack(spacing: 0) {
            Circle().fill(antennaColor.opacity(0.9))
                .frame(width: 3.5, height: 3.5)
                .scaleEffect(hovered ? 1.5 : 1.0)
            Rectangle().fill(Self.outline).frame(width: 1, height: 3)
        }
        .offset(y: hovered ? -10.5 : -8.5)
        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: hovered)
    }

    private var staticEyes: some View {
        HStack(spacing: 4.5) {
            eyeShape
            eyeShape
        }
        .offset(y: 0.5)
    }

    private var head: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(Self.outline, lineWidth: 1.2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(headFill)
            )
            .frame(width: 20, height: 15)
            .offset(y: 2)
    }

    private var headFill: Color {
        switch state {
        case .alert: return .orange.opacity(0.15)
        case .happy: return .green.opacity(0.15)
        case .busy:  return Self.cyan.opacity(0.18)
        default:     return Color.secondary.opacity(0.10)
        }
    }

    private func antenna(at t: TimeInterval) -> some View {
        let blink = (sin(t * 2.2) + 1) / 2
        return VStack(spacing: 0) {
            Circle()
                .fill(antennaColor.opacity(0.6 + 0.4 * blink))
                .frame(width: 3.5, height: 3.5)
                .scaleEffect(hovered ? 1.5 : 1.0)
            Rectangle()
                .fill(Self.outline)
                .frame(width: 1, height: 3)
        }
        .offset(y: hovered ? -10.5 : -8.5)
        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: hovered)
    }

    private var antennaColor: Color {
        switch state {
        case .alert: return .orange
        case .happy: return .green
        case .busy:  return Self.cyan
        default:     return Self.outline
        }
    }

    private func eyes(at t: TimeInterval) -> some View {
        // Blink: scale the eyes vertically toward 0 every ~3.2s for ~150ms.
        let cycle = t.truncatingRemainder(dividingBy: 3.2)
        let blinking = state != .alert && cycle < 0.15
        let scaleY: CGFloat = blinking ? 0.15 : 1.0

        return HStack(spacing: 4.5) {
            eyeShape
            eyeShape
        }
        .scaleEffect(x: 1, y: scaleY)
        .animation(.easeInOut(duration: 0.08), value: blinking)
        .offset(y: 0.5)
    }

    @ViewBuilder
    private var eyeShape: some View {
        switch state {
        case .busy:
            // Focused: narrow horizontal slits
            Capsule()
                .fill(Self.cyan)
                .frame(width: 4.5, height: 1.8)
        case .alert:
            // Surprised: bigger round eyes
            Circle()
                .fill(Color.orange)
                .frame(width: 4.5, height: 4.5)
        case .happy:
            // Smiling closed-arc eyes (carets)
            Path { p in
                p.move(to: CGPoint(x: 0, y: 2.2))
                p.addQuadCurve(to: CGPoint(x: 4.5, y: 2.2),
                               control: CGPoint(x: 2.25, y: -0.6))
            }
            .stroke(Color.green, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .frame(width: 4.5, height: 3)
        case .watching:
            Circle()
                .fill(Self.cyan)
                .frame(width: 3.3, height: 3.3)
        case .idle:
            Circle()
                .fill(Self.outline)
                .frame(width: 2.7, height: 2.7)
        }
    }

    @ViewBuilder
    private var mouth: some View {
        switch state {
        case .happy:
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addQuadCurve(to: CGPoint(x: 6, y: 0),
                               control: CGPoint(x: 3, y: 2.4))
            }
            .stroke(Color.green, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .frame(width: 6, height: 2.4)
            .offset(y: 6)
        case .alert:
            Circle()
                .fill(Color.orange.opacity(0.7))
                .frame(width: 2.3, height: 2.3)
                .offset(y: 6)
        case .busy:
            Rectangle()
                .fill(Self.cyan.opacity(0.5))
                .frame(width: 4.5, height: 1.2)
                .offset(y: 6)
        default:
            // Hover-only smile arc — the robot grins back when you reach
            // for it, regardless of its current state.
            if hovered {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addQuadCurve(to: CGPoint(x: 6, y: 0),
                                   control: CGPoint(x: 3, y: 2.2))
                }
                .stroke(Self.cyan, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .frame(width: 6, height: 2.2)
                .offset(y: 6)
                .transition(.scale.combined(with: .opacity))
            } else {
                EmptyView()
            }
        }
    }
}

// Triangle-eared cat with vertical-slit eyes when busy, big round when
// alert, smiling closed-arcs when happy. Whiskers as static decoration.
private struct CatMascot: View {

    let state: BotState
    let paused: Bool
    let hovered: Bool

    private static let cyan = Color(red: 0.4, green: 0.85, blue: 1.0)
    private static let outline = Color.secondary.opacity(0.7)

    var body: some View {
        if paused {
            ZStack { head; staticEyes; mouth; whiskers; blep }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TimelineView(.animation(minimumInterval: 0.05)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                ZStack { head; eyes(at: t); mouth; whiskers; blep }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // Ears perked = head + ear-hints lift slightly while hovered.
    private var earLift: CGFloat { hovered ? -1.5 : 0 }

    // Tiny tongue blep — a pink rounded triangle peeking out below the
    // mouth on hover. Pure decoration; appears only while hovered.
    @ViewBuilder
    private var blep: some View {
        if hovered {
            Capsule()
                .fill(Color(red: 1.0, green: 0.55, blue: 0.7))
                .frame(width: 2.2, height: 2.8)
                .offset(y: 7.5)
                .transition(.scale.combined(with: .opacity))
                .animation(.spring(response: 0.25, dampingFraction: 0.55), value: hovered)
        }
    }

    private var head: some View {
        ZStack {
            // Face + ears combined as a single path so the ears feel
            // attached to the head, not floating above.
            CatHeadShape()
                .fill(headFill)
                .overlay(CatHeadShape().stroke(Self.outline, lineWidth: 1.2))
                .frame(width: 20, height: 18)
                .offset(y: 1 + earLift)
                .animation(.spring(response: 0.28, dampingFraction: 0.6), value: hovered)
            // Inner ear hints (small triangles inside each ear)
            Triangle()
                .fill(Self.outline.opacity(0.4))
                .frame(width: 2, height: 2.2)
                .offset(x: -5.5, y: -5.5 + earLift)
                .animation(.spring(response: 0.28, dampingFraction: 0.6), value: hovered)
            Triangle()
                .fill(Self.outline.opacity(0.4))
                .frame(width: 2, height: 2.2)
                .offset(x: 5.5, y: -5.5 + earLift)
                .animation(.spring(response: 0.28, dampingFraction: 0.6), value: hovered)
            // Nose (tiny triangle)
            Triangle()
                .rotation(.degrees(180))
                .fill(Self.outline)
                .frame(width: 2, height: 1.5)
                .offset(y: 3)
        }
    }

    private var headFill: Color {
        switch state {
        case .alert: return .orange.opacity(0.18)
        case .happy: return .green.opacity(0.18)
        case .busy:  return Self.cyan.opacity(0.20)
        default:     return Color.secondary.opacity(0.12)
        }
    }

    private func eyes(at t: TimeInterval) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 3.5)
        let blinking = state != .alert && cycle < 0.15
        let scaleY: CGFloat = blinking ? 0.15 : 1.0
        // While hovered, scale the left eye flat → looks like a wink.
        let leftScale: CGFloat = hovered ? 0.15 : scaleY
        return HStack(spacing: 5) {
            eyeShape.scaleEffect(x: 1, y: leftScale)
            eyeShape.scaleEffect(x: 1, y: scaleY)
        }
        .animation(.easeInOut(duration: 0.18), value: hovered)
        .animation(.easeInOut(duration: 0.08), value: blinking)
        .offset(y: -0.5)
    }

    private var staticEyes: some View {
        HStack(spacing: 5) {
            eyeShape.scaleEffect(x: 1, y: hovered ? 0.15 : 1)
            eyeShape
        }
        .animation(.easeInOut(duration: 0.18), value: hovered)
        .offset(y: -0.5)
    }

    @ViewBuilder
    private var eyeShape: some View {
        switch state {
        case .busy:
            Capsule().fill(Self.cyan).frame(width: 1.4, height: 4.5)  // slit
        case .alert:
            Circle().fill(Color.orange).frame(width: 4.5, height: 4.5)
        case .happy:
            Path { p in
                p.move(to: CGPoint(x: 0, y: 2.2))
                p.addQuadCurve(to: CGPoint(x: 4.5, y: 2.2),
                               control: CGPoint(x: 2.25, y: -0.6))
            }
            .stroke(Color.green, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .frame(width: 4.5, height: 3)
        case .watching:
            Circle().fill(Self.cyan).frame(width: 3.0, height: 3.0)
        case .idle:
            Circle().fill(Self.outline).frame(width: 2.4, height: 2.4)
        }
    }

    @ViewBuilder
    private var mouth: some View {
        switch state {
        case .happy:
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addQuadCurve(to: CGPoint(x: 5, y: 0),
                               control: CGPoint(x: 2.5, y: 2))
            }
            .stroke(Color.green, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .frame(width: 5, height: 2)
            .offset(y: 6)
        default:
            // Tiny "w" mouth: two arcs
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addQuadCurve(to: CGPoint(x: 2, y: 0), control: CGPoint(x: 1, y: 1.5))
                p.addQuadCurve(to: CGPoint(x: 4, y: 0), control: CGPoint(x: 3, y: 1.5))
            }
            .stroke(Self.outline, style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
            .frame(width: 4, height: 1.5)
            .offset(y: 5)
        }
    }

    private var whiskers: some View {
        HStack(spacing: 14) {
            VStack(spacing: 1.5) {
                Rectangle().fill(Self.outline).frame(width: 3.5, height: 0.5)
                Rectangle().fill(Self.outline).frame(width: 3.5, height: 0.5)
            }
            VStack(spacing: 1.5) {
                Rectangle().fill(Self.outline).frame(width: 3.5, height: 0.5)
                Rectangle().fill(Self.outline).frame(width: 3.5, height: 0.5)
            }
        }
        .opacity(0.45)
        .offset(y: 4.5)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

// Rounded face with two pointy ears that meet the face curve cleanly —
// drawn as one path so fill + stroke read as a single silhouette.
private struct CatHeadShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            let w = rect.width
            let h = rect.height
            let faceTop = rect.minY + h * 0.30
            let earBaseInnerLeft  = CGPoint(x: rect.minX + w * 0.30, y: faceTop - 1)
            let earBaseOuterLeft  = CGPoint(x: rect.minX + w * 0.10, y: faceTop + 2)
            let earTipLeft        = CGPoint(x: rect.minX + w * 0.05, y: rect.minY)
            let earBaseInnerRight = CGPoint(x: rect.minX + w * 0.70, y: faceTop - 1)
            let earBaseOuterRight = CGPoint(x: rect.minX + w * 0.90, y: faceTop + 2)
            let earTipRight       = CGPoint(x: rect.minX + w * 0.95, y: rect.minY)
            // Start at left ear inner-base, go up to tip, down to outer-base.
            p.move(to: earBaseInnerLeft)
            p.addLine(to: earTipLeft)
            p.addLine(to: earBaseOuterLeft)
            // Curve along the left/bottom of the face to the right ear.
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY + h * 0.15),
                           control: CGPoint(x: rect.minX, y: faceTop + 4))
            p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                           control: CGPoint(x: rect.minX, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY + h * 0.15),
                           control: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addQuadCurve(to: earBaseOuterRight,
                           control: CGPoint(x: rect.maxX, y: faceTop + 4))
            // Right ear
            p.addLine(to: earTipRight)
            p.addLine(to: earBaseInnerRight)
            // Curve between the two ear inner-bases (top of head dip).
            p.addQuadCurve(to: earBaseInnerLeft,
                           control: CGPoint(x: rect.midX, y: faceTop + 2))
            p.closeSubpath()
        }
    }
}

// Sentinel-style single eye: outer lens ring, inner pupil that moves
// horizontally when watching, contracts when busy, dilates red on alert.
private struct EyeMascot: View {

    let state: BotState
    let paused: Bool
    let hovered: Bool

    private static let cyan = Color(red: 0.4, green: 0.85, blue: 1.0)
    private static let outline = Color.secondary.opacity(0.7)

    var body: some View {
        if paused {
            ZStack { lens; staticPupil; eyebrow }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TimelineView(.animation(minimumInterval: 0.05)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                ZStack { lens; pupil(at: t); eyebrow }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // Hover-only eyebrow arc above the lens — gives the sentinel a
    // questioning, "oh hey you" expression when the cursor approaches.
    @ViewBuilder
    private var eyebrow: some View {
        if hovered {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 2))
                p.addQuadCurve(to: CGPoint(x: 9, y: 2),
                               control: CGPoint(x: 4.5, y: -1.5))
            }
            .stroke(Self.outline, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            .frame(width: 9, height: 3)
            .offset(y: -10)
            .transition(.scale.combined(with: .opacity))
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovered)
        }
    }

    private var lens: some View {
        ZStack {
            Circle()
                .stroke(Self.outline, lineWidth: 1.2)
                .background(Circle().fill(lensFill))
                .frame(width: 22, height: 22)
            // Inner ring
            Circle()
                .stroke(Self.outline.opacity(0.5), lineWidth: 0.8)
                .frame(width: 16, height: 16)
        }
        .offset(y: 1)
    }

    private var lensFill: Color {
        switch state {
        case .alert: return .red.opacity(0.18)
        case .happy: return .green.opacity(0.14)
        case .busy:  return Self.cyan.opacity(0.16)
        default:     return Color.secondary.opacity(0.10)
        }
    }

    private func pupil(at t: TimeInterval) -> some View {
        // Hovered: faster, wider dart — the eye is "tracking" the cursor.
        // Otherwise: the slow watching scan, or static.
        let scan: Double
        if hovered      { scan = sin(t * 6.0) * 4.5 }
        else if state == .watching { scan = sin(t * 1.5) * 3 }
        else            { scan = 0 }
        return Circle()
            .fill(pupilColor)
            .frame(width: pupilSize + (hovered ? 2.0 : 0),
                   height: pupilSize + (hovered ? 2.0 : 0))
            .offset(x: scan, y: 1)
            .animation(.easeInOut(duration: 0.18), value: hovered)
    }

    private var staticPupil: some View {
        Circle()
            .fill(pupilColor)
            .frame(width: pupilSize + (hovered ? 2.0 : 0),
                   height: pupilSize + (hovered ? 2.0 : 0))
            .offset(y: 1)
            .animation(.easeInOut(duration: 0.18), value: hovered)
    }

    private var pupilSize: CGFloat {
        switch state {
        case .busy:  return 4.5
        case .alert: return 7.5
        case .happy: return 5.5
        default:     return 5.5
        }
    }

    private var pupilColor: Color {
        switch state {
        case .alert: return .red
        case .happy: return .green
        case .busy:  return Self.cyan
        default:     return Self.outline
        }
    }
}

// Floaty ghost: rounded top with wavy bottom, two eye dots. Gentle bob.
private struct GhostMascot: View {

    let state: BotState
    let paused: Bool
    let hovered: Bool

    private static let cyan = Color(red: 0.4, green: 0.85, blue: 1.0)
    private static let outline = Color.secondary.opacity(0.7)

    var body: some View {
        if paused {
            ZStack {
                sparkles
                ZStack { body_; staticEyes; mouth }
                    .offset(y: hovered ? -4 : 0)
                    .scaleEffect(hovered ? 1.08 : 1.0)
                    .animation(.spring(response: 0.32, dampingFraction: 0.55), value: hovered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TimelineView(.animation(minimumInterval: 0.05)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                let bob = sin(t * 1.3) * 1.0
                ZStack {
                    sparkles
                    ZStack { body_; eyes(at: t); mouth }
                        .offset(y: bob + (hovered ? -4 : 0))
                        .scaleEffect(hovered ? 1.08 : 1.0)
                        .animation(.spring(response: 0.32, dampingFraction: 0.55), value: hovered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // Three little sparkles around the ghost on hover. They fade in via
    // transition, then a subtle pulse via TimelineView would be overkill
    // — keeping them static for clarity and frame budget.
    @ViewBuilder
    private var sparkles: some View {
        if hovered {
            ZStack {
                sparkle.offset(x: -10, y: -8)
                sparkle.offset(x: 10, y: -3).scaleEffect(0.7)
                sparkle.offset(x: 8,  y: 9).scaleEffect(0.85)
            }
            .transition(.scale.combined(with: .opacity))
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: hovered)
        }
    }

    private var sparkle: some View {
        // Four-point star drawn as two crossed thin capsules.
        ZStack {
            Capsule().fill(Self.cyan).frame(width: 1.2, height: 4)
            Capsule().fill(Self.cyan).frame(width: 4, height: 1.2)
        }
    }

    private var body_: some View {
        GhostShape()
            .stroke(Self.outline, lineWidth: 1.2)
            .background(GhostShape().fill(headFill))
            .frame(width: 18, height: 22)
    }

    private var headFill: Color {
        switch state {
        case .alert: return .orange.opacity(0.18)
        case .happy: return .green.opacity(0.18)
        case .busy:  return Self.cyan.opacity(0.20)
        default:     return Color.secondary.opacity(0.12)
        }
    }

    private func eyes(at t: TimeInterval) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 3.0)
        let blinking = state != .alert && cycle < 0.15
        let scaleY: CGFloat = blinking ? 0.15 : 1.0
        return HStack(spacing: 4) { eyeShape; eyeShape }
            .scaleEffect(x: 1, y: scaleY)
            .animation(.easeInOut(duration: 0.08), value: blinking)
            .offset(y: -2)
    }

    private var staticEyes: some View {
        HStack(spacing: 4) { eyeShape; eyeShape }.offset(y: -2)
    }

    @ViewBuilder
    private var eyeShape: some View {
        switch state {
        case .busy:
            Capsule().fill(Self.cyan).frame(width: 4, height: 1.6)
        case .alert:
            Circle().fill(Color.orange).frame(width: 4, height: 4)
        case .happy:
            Path { p in
                p.move(to: CGPoint(x: 0, y: 2))
                p.addQuadCurve(to: CGPoint(x: 4, y: 2),
                               control: CGPoint(x: 2, y: -0.4))
            }
            .stroke(Color.green, style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            .frame(width: 4, height: 2.5)
        case .watching:
            Circle().fill(Self.cyan).frame(width: 3, height: 3)
        case .idle:
            Circle().fill(Self.outline).frame(width: 2.4, height: 2.4)
        }
    }

    @ViewBuilder
    private var mouth: some View {
        switch state {
        case .happy:
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addQuadCurve(to: CGPoint(x: 4, y: 0), control: CGPoint(x: 2, y: 2))
            }
            .stroke(Color.green, style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            .frame(width: 4, height: 2)
            .offset(y: 4)
        case .alert:
            Capsule().fill(Color.orange.opacity(0.8))
                .frame(width: 2.4, height: 3.5)
                .offset(y: 4)
        default:
            if hovered {
                // Yawning "boo" while hovered — open oval mouth.
                Capsule()
                    .fill(Self.outline.opacity(0.85))
                    .frame(width: 3, height: 4)
                    .offset(y: 4)
                    .transition(.scale.combined(with: .opacity))
            } else {
                EmptyView()
            }
        }
    }
}

// Rounded top + three wavy humps on the bottom edge.
private struct GhostShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            let r = rect.width / 2
            // Rounded top: semicircle on top
            p.addArc(center: CGPoint(x: rect.midX, y: rect.minY + r),
                     radius: r,
                     startAngle: .degrees(180),
                     endAngle: .degrees(360),
                     clockwise: false)
            // Down the right side
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 3))
            // Three humps along the bottom (right -> left)
            let humpW = rect.width / 3
            for i in (0..<3).reversed() {
                let x0 = rect.minX + CGFloat(i) * humpW
                let xMid = x0 + humpW / 2
                p.addQuadCurve(
                    to: CGPoint(x: x0, y: rect.maxY - 3),
                    control: CGPoint(x: xMid, y: rect.maxY + 3))
            }
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            p.closeSubpath()
        }
    }
}

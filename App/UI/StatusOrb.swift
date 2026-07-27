import SwiftUI

/// Animated status indicator: each state has its own tiny motion signature.
/// - running: three dots orbiting (agent thinking/working)
/// - waitingForPermission / waitingForInput: pulsing glow (needs the human)
/// - completed: calm solid dot with a soft ring
/// - idle / terminated: static dim dot
struct StatusOrb: View {
    let status: AgentSessionStatus
    var size: CGFloat = 12

    var body: some View {
        switch status {
        case .running, .thinking:
            OrbitingDots(color: status.color, size: size)
        case .waitingForPermission, .waitingForInput:
            PulsingOrb(color: status.color, size: size)
        case .completed:
            ZStack {
                Circle()
                    .strokeBorder(status.color.opacity(0.35), lineWidth: 1)
                Circle()
                    .fill(status.color)
                    .frame(width: size * 0.45, height: size * 0.45)
            }
            .frame(width: size, height: size)
        case .idle, .terminated:
            Circle()
                .fill(status.color.opacity(0.7))
                .frame(width: size * 0.42, height: size * 0.42)
                .frame(width: size, height: size)
        }
    }
}

/// Three dots circling a common center — the "agent at work" signature.
private struct OrbitingDots: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 15.0,
            paused: LaunchConfig.shared.disableAnimations
        )) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let radius = canvasSize.width * 0.32
                for index in 0..<3 {
                    let angle = t * 2.4 + Double(index) * (.pi * 2 / 3)
                    let position = CGPoint(
                        x: center.x + cos(angle) * radius,
                        y: center.y + sin(angle) * radius
                    )
                    let dotSize = canvasSize.width * 0.24
                    let rect = CGRect(
                        x: position.x - dotSize / 2,
                        y: position.y - dotSize / 2,
                        width: dotSize,
                        height: dotSize
                    )
                    canvas.fill(
                        Path(ellipseIn: rect),
                        with: .color(color.opacity(index == 0 ? 1 : 0.55))
                    )
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Breathing glow — attention needed, without being a notification banner.
private struct PulsingOrb: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 15.0,
            paused: LaunchConfig.shared.disableAnimations
        )) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * 3.4) + 1) / 2  // 0…1
            ZStack {
                Circle()
                    .fill(color.opacity(0.18 + phase * 0.25))
                    .frame(width: size, height: size)
                    .scaleEffect(0.8 + phase * 0.5)
                Circle()
                    .fill(color)
                    .frame(width: size * 0.42, height: size * 0.42)
            }
            .frame(width: size, height: size)
        }
    }
}

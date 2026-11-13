import SwiftUI

/// The Uncoil mark, as the website draws it: the same four contours, in the
/// same 512-point space, read from `uncoil-mark-contours.json` (extracted from
/// the site's `uncoil-mark.json`, so the two can never drift into different
/// logos).
enum UncoilMarkShape {
    struct Contour: Decodable {
        let closed: Bool
        /// `[x, y, inX, inY, outX, outY]`, tangents relative to the vertex —
        /// Lottie's own encoding.
        let points: [[Double]]
    }

    private struct File: Decodable {
        let size: Double
        let contours: [Contour]
    }

    /// Parsed once; nil only if the resource is missing from the bundle.
    static let path: (path: Path, size: CGFloat)? = {
        guard let url = Bundle.main.url(forResource: "uncoil-mark-contours", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        var path = Path()
        for contour in file.contours {
            let points = contour.points.filter { $0.count == 6 }
            guard let first = points.first else { continue }
            path.move(to: CGPoint(x: first[0], y: first[1]))
            let count = points.count
            let segments = contour.closed ? count : count - 1
            for index in 0..<segments {
                let from = points[index]
                let to = points[(index + 1) % count]
                path.addCurve(
                    to: CGPoint(x: to[0], y: to[1]),
                    control1: CGPoint(x: from[0] + from[4], y: from[1] + from[5]),
                    control2: CGPoint(x: to[0] + to[2], y: to[1] + to[3])
                )
            }
            if contour.closed { path.closeSubpath() }
        }
        return (path, CGFloat(file.size))
    }()
}

/// The mark drawing itself: a light stroke unspools around the coil, the brand
/// gradient fills in under it, and the stroke fades — the website's splash,
/// frame for frame in spirit (its Lottie runs 96 frames at 60 fps).
struct UncoilMarkAnimation: View {
    var size: CGFloat = 132
    /// 0…1 through the whole animation.
    var progress: Double

    // Timings, as fractions of the 96-frame Lottie.
    private func segment(_ start: Double, _ end: Double) -> Double {
        let t = min(1, max(0, (progress - start) / (end - start)))
        // ease-in-out, close to the file's bezier handles
        return t * t * (3 - 2 * t)
    }

    var body: some View {
        if let mark = UncoilMarkShape.path {
            let scale = size / mark.size
            let draw = segment(0, 52.0 / 96)
            let fill = segment(34.0 / 96, 62.0 / 96)
            let strokeFade = 1 - segment(54.0 / 96, 80.0 / 96)
            let grow = 0.96 + 0.04 * segment(0, 66.0 / 96)
            ZStack {
                mark.path
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color(hex: 0xA77CFF), location: 0),
                                .init(color: Color(hex: 0x8156F6), location: 0.48),
                                .init(color: Color(hex: 0x4F2EC9), location: 1),
                            ],
                            startPoint: UnitPoint(x: 128.0 / 512, y: 112.0 / 512),
                            endPoint: UnitPoint(x: 384.0 / 512, y: 416.0 / 512)
                        )
                    )
                    .opacity(fill)
                mark.path
                    .trim(from: 0, to: draw)
                    .stroke(Color(hex: 0xC9A9FF), style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
                    .opacity(strokeFade)
            }
            .frame(width: mark.size, height: mark.size)
            .scaleEffect(scale * grow)
            .frame(width: size, height: size)
        } else {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: size, height: size)
                .opacity(progress > 0 ? 1 : 0)
        }
    }
}

/// The launch curtain: the website's splash, in front of the first window while
/// the stores, the runtime daemon and the sidebar come up behind it.
struct SplashView: View {
    @ObservedObject var gate: SplashGate

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(hex: 0x15044C), location: 0),
                    .init(color: Color(hex: 0x2A0B84), location: 0.46),
                    .init(color: Color(hex: 0x5C31D2), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            TimelineView(.animation(paused: gate.isLifting)) { context in
                UncoilMarkAnimation(size: 132, progress: gate.progress(at: context.date))
                    .offset(y: gate.isLifting ? 34 : 0)
                    .scaleEffect(gate.isLifting ? 0.62 : 1)
                    .opacity(gate.isLifting ? 0 : 1)
            }
        }
        .ignoresSafeArea()
        .opacity(gate.isLifting ? 0 : 1)
        .scaleEffect(gate.isLifting ? 1.06 : 1)
        .offset(y: gate.isLifting ? -12 : 0)
        .animation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.4), value: gate.isLifting)
        .allowsHitTesting(!gate.isLifting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Uncoil is starting")
        .accessibilityIdentifier("splash")
    }
}

/// When the launch curtain lifts: after the mark has finished drawing *and* the
/// app is ready behind it — or after a ceiling, so a slow daemon never leaves
/// the user looking at a logo.
@MainActor
final class SplashGate: ObservableObject {
    static let shared = SplashGate()

    /// Seconds the mark takes to draw — the Lottie's 96 frames played a little
    /// under speed, as the website does.
    static let drawDuration: TimeInterval = 1.0
    /// Never longer than this, ready or not.
    static let ceiling: TimeInterval = 2.2

    @Published private(set) var isShowing: Bool
    @Published private(set) var isLifting = false
    private var startedAt = Date()
    private var started = false

    private init() {
        let config = LaunchConfig.shared
        // Tests and screenshots want the window, not a curtain.
        isShowing = !config.isUITesting && !config.disableAnimations
    }

    func progress(at date: Date) -> Double {
        min(1, max(0, date.timeIntervalSince(startedAt) / Self.drawDuration))
    }

    /// Called by the first window. `isReady` is polled until it answers yes.
    func start(isReady: @escaping @MainActor () -> Bool) {
        guard isShowing, !started else { return }
        started = true
        startedAt = Date()
        Task { @MainActor in
            // A short hold on the finished mark, like the site's 420 ms.
            try? await Task.sleep(for: .seconds(Self.drawDuration + 0.12))
            while !isReady(), Date().timeIntervalSince(startedAt) < Self.ceiling {
                try? await Task.sleep(for: .milliseconds(100))
            }
            lift()
        }
    }

    func lift() {
        guard isShowing, !isLifting else { return }
        isLifting = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            isShowing = false
        }
    }
}

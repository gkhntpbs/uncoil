import AppKit
import SwiftUI
import XCTest
@testable import Uncoil

/// Proves a settings text field is visible against the row it sits on, rather
/// than assuming it.
///
/// This exists because the field was reported invisible twice. A plain
/// `TextField` in a grouped form loses AppKit's bezel and inherits the row's
/// colour, so "there is a text field here" was true in the view tree and false
/// on screen. Worse, the palette's `bg`, `panel` and `border` sit within 5–16
/// of each other in the dark theme, so a field built from them is a rectangle
/// nobody can see — which is exactly what the first two attempts drew.
///
/// The assertions are about *contrast*, not about which colour was used: an
/// exact-colour check would pass on a field drawn in two indistinguishable
/// greys, and would fail spuriously because a bitmap round-trip shifts values
/// by a few units. Set `TEST_RUNNER_UNCOIL_SETTINGS_SAMPLE_DIR` to write the PNG.
@MainActor
final class SettingsFieldRenderTests: XCTestCase {
    private let width = 420
    private let height = 120

    /// Renders one field on a panel-coloured backdrop, the way a settings row
    /// draws it.
    private func render(text: String = "") throws -> NSBitmapImageRep {
        let view = SettingsTextField(
            title: "Ad",
            detail: "Hesap için görünen ad.",
            prompt: "ör. İş",
            text: .constant(text)
        )
        .padding(16)
        // The grouped row's surface. The field has to be distinguishable from
        // exactly this.
        .background(Theme.panel)

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        if let directory = ProcessInfo.processInfo.environment["UNCOIL_SETTINGS_SAMPLE_DIR"] {
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("settings-field.png")
            )
        }
        return rep
    }

    /// Perceived brightness, 0…1.
    private func luma(_ colour: NSColor) -> CGFloat {
        guard let rgb = colour.usingColorSpace(.deviceRGB) else { return 0 }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    }

    /// Every colour drawn in the lower half of the frame, where the field lives
    /// (the label occupies the top), with how often each appears.
    private func fieldColours(_ rep: NSBitmapImageRep) -> [(luma: CGFloat, count: Int)] {
        var histogram: [Int: Int] = [:]
        let bottom = Int(rep.size.height) / 2
        for y in stride(from: bottom, to: Int(rep.size.height) - 2, by: 1) {
            for x in stride(from: 2, to: Int(rep.size.width) - 2, by: 1) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                // Bucket to 1/255 so anti-aliasing noise collapses.
                histogram[Int(luma(colour) * 255), default: 0] += 1
            }
        }
        // Merge neighbouring buckets: a flat fill lands on two or three
        // adjacent values once the bitmap has been through a colour space, and
        // counting those as separate surfaces made a solid field look like two
        // shades 3/255 apart.
        var clusters: [(luma: CGFloat, count: Int)] = []
        for key in histogram.keys.sorted() {
            let value = CGFloat(key) / 255
            let count = histogram[key] ?? 0
            if let last = clusters.last, value - last.luma <= 3.0 / 255 {
                clusters[clusters.count - 1] = (
                    // Weighted mean, so the cluster sits on its dominant tone.
                    luma: (last.luma * CGFloat(last.count) + value * CGFloat(count))
                        / CGFloat(last.count + count),
                    count: last.count + count
                )
            } else {
                clusters.append((luma: value, count: count))
            }
        }
        return clusters.sorted { $0.count > $1.count }
    }

    func testTheFieldIsDistinguishableFromTheRowBehindIt() throws {
        let rep = try render()
        let colours = fieldColours(rep)
        XCTAssertGreaterThan(colours.count, 2, "the field did not render")

        // The two surfaces that cover most of the lower half: the row's panel
        // and the field's well.
        let surfaces = Array(colours.prefix(2))
        let separation = abs(surfaces[0].luma - surfaces[1].luma)
        XCTAssertGreaterThan(
            separation, 0.015,
            "the well and the row are the same shade — the field blends in"
        )
    }

    func testTheEdgeIsVisibleAgainstBothSurfaces() throws {
        let rep = try render()
        let colours = fieldColours(rep)
        let surfaces = Array(colours.prefix(2).map(\.luma))

        // The border has to stand off *both* surfaces, which is the failure the
        // first two attempts shipped: an edge 5/255 from the panel is not an
        // edge. Anti-aliased pixels are excluded by requiring a real population.
        let edge = colours.first { candidate in
            candidate.count > 40
                && surfaces.allSatisfy { abs(candidate.luma - $0) > 0.08 }
        }
        XCTAssertNotNil(
            edge,
            "no clearly visible border: brightest surfaces \(surfaces), "
                + "colours \(colours.prefix(6).map { ($0.luma, $0.count) })"
        )
    }

    func testTypedTextLandsInsideTheWell() throws {
        let empty = try render()
        let filled = try render(text: "Kişisel")
        // Text has to change what is on screen; if the two renders match, the
        // field is not showing its contents.
        XCTAssertNotEqual(
            empty.representation(using: .png, properties: [:]),
            filled.representation(using: .png, properties: [:]),
            "typing changed nothing on screen"
        )
    }
}

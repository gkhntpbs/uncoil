import AppKit
import SwiftUI
import XCTest
@testable import Uncoil

/// Renders both palettes offscreen so a change to the theme can be looked at,
/// not just asserted about.
///
/// The app's own window is not a reliable place to check a palette — the theme
/// is per-user state and the fixture launch path has its own problems — while a
/// hosting view renders the same SwiftUI with the same tokens and needs nothing
/// but a process. Set `UNCOIL_THEME_SAMPLE_DIR` to write the PNGs somewhere.
@MainActor
final class ThemeSamplerRenderTests: XCTestCase {
    private struct Sampler: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Uncoil")
                    .font(Theme.mono(15, .bold))
                    .foregroundStyle(Theme.brand)

                HStack(spacing: 8) {
                    swatch("bg", Theme.bg)
                    swatch("panel", Theme.panel)
                    swatch("hover", Theme.panelHover)
                    swatch("active", Theme.panelActive)
                    swatch("border", Theme.border)
                }
                HStack(spacing: 8) {
                    swatch("highlight", Theme.highlight)
                    swatch("hover", Theme.highlightHover)
                    swatch("active", Theme.highlightActive)
                    swatch("muted", Theme.highlightMuted)
                    swatch("hl border", Theme.highlightBorder)
                }
                HStack(spacing: 8) {
                    swatch("ok", Theme.ok)
                    swatch("warn", Theme.warn)
                    swatch("danger", Theme.danger)
                    swatch("info", Theme.info)
                    swatch("claude", Theme.claude)
                    swatch("codex", Theme.codex)
                }

                // The pairs that have to stay readable.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Birincil metin").font(Theme.mono(12)).foregroundStyle(Theme.text)
                    Text("İkincil metin").font(Theme.mono(11)).foregroundStyle(Theme.textDim)
                    Text("Soluk metin").font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    Text("Birincil eylem")
                        .font(Theme.mono(11, .semibold))
                        .foregroundStyle(Theme.textOnHighlight)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.highlight, in: RoundedRectangle(cornerRadius: 7))
                    Text("Seçili satır")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.highlightMuted, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Theme.highlightBorder, lineWidth: 1)
                        )
                }

                HStack(spacing: 6) {
                    StatusBadge(text: "Tamam", level: .success)
                    StatusBadge(text: "Warning", level: .warning)
                    StatusBadge(text: "Hata", level: .danger)
                    StatusBadge(text: "Vurgu", level: .accent(Theme.highlight))
                }
            }
            .padding(16)
            .frame(width: 520, alignment: .leading)
            .background(Theme.bg)
        }

        private func swatch(_ label: String, _ color: Color) -> some View {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(color)
                    .frame(width: 62, height: 26)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
                Text(label).font(Theme.mono(8)).foregroundStyle(Theme.textDim)
            }
        }
    }

    func testBothPalettesRender() throws {
        guard let directory = ProcessInfo.processInfo.environment["UNCOIL_THEME_SAMPLE_DIR"] else {
            throw XCTSkip("Set UNCOIL_THEME_SAMPLE_DIR to write palette samples")
        }
        let original = ThemeStore.shared.palette
        defer { ThemeStore.shared.palette = original }

        for (name, palette) in [("dark", ThemePalette.dark), ("light", ThemePalette.light)] {
            ThemeStore.shared.palette = palette
            let host = NSHostingView(rootView: Sampler())
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("theme-\(name).png")
            try png.write(to: url)
        }
    }
}

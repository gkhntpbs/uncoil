import SwiftUI

/// An accent colour and a Tabler icon — what anything in Uncoil that a user
/// names gets to choose.
///
/// Projects had this inline; blueprints want the same control, and the
/// new-project sheet wants it a third time.
///
/// Two things it used to get wrong. The palette was eight swatches and nothing
/// else, so "the colour I actually want" was not on offer at all — there is now
/// a full picker beside a wider set of ready-made ones. And the icon grid was a
/// wall of three hundred glyphs in search order, which is not browsable: they
/// are grouped now, and the grid opens on a handful of likely ones rather than
/// on everything.
struct IconColorPicker: View {
    @Binding var iconName: String?
    @Binding var colorHex: UInt32?
    /// Height of the icon grid. The sheets have different room for it.
    var gridHeight: CGFloat = 150

    @State private var search = ""

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 6), count: 12)

    private var accent: Color {
        colorHex.map { Color(hex: $0) } ?? Theme.textDim
    }

    /// What the grid shows: matches while searching, a curated starting set
    /// otherwise. Three hundred icons in alphabetical order is a list nobody
    /// reads to the end of.
    private var icons: [String] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else {
            return ProjectPalette.suggestedIcons.filter { TablerIcons.map[$0] != nil }
        }
        return TablerIcons.sortedNames.filter { $0.contains(query) }.prefix(180).map { $0 }
    }

    /// A binding the system colour picker can drive. Reading gives the current
    /// accent; writing stores it back as 0xRRGGBB.
    private var customColor: Binding<Color> {
        Binding(
            get: { colorHex.map { Color(hex: $0) } ?? Color(hex: ProjectPalette.colors[0]) },
            set: { colorHex = $0.rgbHex }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            SheetField(label: String(localized: "Colour")) {
                HStack(spacing: Theme.Space.tight) {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(20), spacing: 7), count: 9
                        ),
                        spacing: 7
                    ) {
                        ForEach(ProjectPalette.colors, id: \.self) { hex in
                            Button {
                                colorHex = colorHex == hex ? nil : hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        Circle().strokeBorder(
                                            colorHex == hex ? Theme.text : .clear,
                                            lineWidth: 2
                                        )
                                    )
                                    .padding(1)
                            }
                            .buttonStyle(.plain)
                            .help(String(format: "#%06X", hex))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Anything not on the row above.
                    ColorPicker("", selection: customColor, supportsOpacity: false)
                        .labelsHidden()
                        .help(String(localized: "Any other colour"))

                    if iconName != nil || colorHex != nil {
                        Button(String(localized: "Reset")) {
                            iconName = nil
                            colorHex = nil
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
            }

            SheetField(label: String(localized: "Icon")) {
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    SheetTextField(
                        placeholder: String(localized: "Search \(TablerIcons.map.count) icons"),
                        text: $search
                    )

                    ScrollView {
                        if icons.isEmpty {
                            Text("No icon matches “\(search)”.")
                                .font(Theme.ui(.small))
                                .foregroundStyle(Theme.textFaint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, Theme.Space.tight)
                        } else {
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(icons, id: \.self) { name in
                                    Button {
                                        iconName = iconName == name ? nil : name
                                    } label: {
                                        TablerIcon(
                                            name: name, size: 15,
                                            color: iconName == name ? accent : Theme.textDim
                                        )
                                        .frame(width: 28, height: 28)
                                        .background(
                                            iconName == name
                                                ? accent.opacity(0.16) : Theme.panel,
                                            in: RoundedRectangle(
                                                cornerRadius: Theme.Radius.chip
                                            )
                                        )
                                        .overlay(
                                            RoundedRectangle(
                                                cornerRadius: Theme.Radius.chip
                                            )
                                            .strokeBorder(
                                                iconName == name
                                                    ? accent.opacity(0.7) : .clear,
                                                lineWidth: 1
                                            )
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .help(name)
                                }
                            }
                            .padding(1)
                        }
                    }
                    .uncoilScrollers()
                    .frame(height: gridHeight)
                }
            }
        }
    }
}

extension Color {
    /// The colour as 0xRRGGBB, for the stores that keep one.
    ///
    /// Converted through sRGB rather than read raw: a colour that came from the
    /// system picker may be in a wider space, and its raw components would
    /// round-trip to something the user did not choose.
    var rgbHex: UInt32 {
        let converted = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let red = UInt32((converted.redComponent * 255).rounded())
        let green = UInt32((converted.greenComponent * 255).rounded())
        let blue = UInt32((converted.blueComponent * 255).rounded())
        return red << 16 | green << 8 | blue
    }
}

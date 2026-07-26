import SwiftUI

/// Type-erased button style, so a button can swap styles based on state
/// (`isInstalled ? Ghost : Accent`) without duplicating its whole body.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

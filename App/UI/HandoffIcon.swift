import SwiftUI

struct HandoffIcon: View {
    var size: CGFloat = 15
    var color: Color = Theme.textDim

    var body: some View {
        HandoffSymbol()
            .stroke(color, style: StrokeStyle(lineWidth: size / 14, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct HandoffSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 1.5, y: 4, width: 7, height: 16),
                            cornerSize: CGSize(width: 1.5, height: 1.5))
        path.addRoundedRect(in: CGRect(x: 15.5, y: 4, width: 7, height: 16),
                            cornerSize: CGSize(width: 1.5, height: 1.5))
        path.move(to: CGPoint(x: 4, y: 8))
        path.addLine(to: CGPoint(x: 6, y: 8))
        path.move(to: CGPoint(x: 18, y: 16))
        path.addLine(to: CGPoint(x: 20, y: 16))
        path.move(to: CGPoint(x: 8.5, y: 12))
        path.addLine(to: CGPoint(x: 15.5, y: 12))
        path.move(to: CGPoint(x: 12, y: 8.5))
        path.addLine(to: CGPoint(x: 15.5, y: 12))
        path.addLine(to: CGPoint(x: 12, y: 15.5))
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

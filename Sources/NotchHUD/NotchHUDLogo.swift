import SwiftUI

/// A miniature screen notch with a terminal prompt and an agent activity light.
/// The two marks are cutouts, so the logo works on glass in either appearance.
struct NotchHUDLogo: View {
    var size: CGFloat = 22

    var body: some View {
        NotchHUDMark()
            .fill(style: FillStyle(eoFill: true))
            .frame(width: size, height: size * 18 / 22)
            .accessibilityHidden(true)
    }
}

private struct NotchHUDMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Small shoulders suggest the display edge; the lower bowl is the notch.
        path.move(to: CGPoint(x: 0, y: 3))
        path.addLine(to: CGPoint(x: 22, y: 3))
        path.addCurve(to: CGPoint(x: 20, y: 5),
                      control1: CGPoint(x: 20.8, y: 3),
                      control2: CGPoint(x: 20, y: 3.8))
        path.addLine(to: CGPoint(x: 20, y: 10))
        path.addCurve(to: CGPoint(x: 15, y: 15),
                      control1: CGPoint(x: 20, y: 13.1),
                      control2: CGPoint(x: 18.1, y: 15))
        path.addLine(to: CGPoint(x: 7, y: 15))
        path.addCurve(to: CGPoint(x: 2, y: 10),
                      control1: CGPoint(x: 3.9, y: 15),
                      control2: CGPoint(x: 2, y: 13.1))
        path.addLine(to: CGPoint(x: 2, y: 5))
        path.addCurve(to: CGPoint(x: 0, y: 3),
                      control1: CGPoint(x: 2, y: 3.8),
                      control2: CGPoint(x: 1.2, y: 3))
        path.closeSubpath()

        // A compact > prompt and a steady activity light remain legible at 18pt.
        path.move(to: CGPoint(x: 6, y: 6))
        path.addLine(to: CGPoint(x: 10, y: 9))
        path.addLine(to: CGPoint(x: 6, y: 12))
        path.addLine(to: CGPoint(x: 6, y: 10))
        path.addLine(to: CGPoint(x: 7.4, y: 9))
        path.addLine(to: CGPoint(x: 6, y: 8))
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: 13, y: 7.5, width: 3, height: 3))

        return path.applying(CGAffineTransform(scaleX: rect.width / 22,
                                              y: rect.height / 18)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

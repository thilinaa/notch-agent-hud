import SwiftUI

/// Keep native wheel, trackpad, keyboard and thumb-drag behavior, but render
/// only a quiet capsule rather than the legacy scrollbar's opaque gutter.
private final class HUDScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor(white: dark ? 0.48 : 0.38, alpha: 0.65).setFill()
        let knob = rect(for: .knob)
        let capsule = NSRect(x: knob.midX - 2.5, y: knob.minY + 2, width: 5, height: max(0, knob.height - 4))
        NSBezierPath(roundedRect: capsule, xRadius: 2.5, yRadius: 2.5).fill()
    }
}

struct HUDScrollStyle: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        func configure() {
            DispatchQueue.main.async { [weak self] in
                var ancestor = self?.superview
                while let view = ancestor {
                    if let scroll = view as? NSScrollView {
                        scroll.drawsBackground = false
                        scroll.scrollerStyle = .overlay
                        scroll.autohidesScrollers = true
                        scroll.hasHorizontalScroller = false
                        if !(scroll.verticalScroller is HUDScroller) {
                            scroll.verticalScroller = HUDScroller()
                        }
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.configure() }
}

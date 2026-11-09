import Cocoa

@MainActor
final class ProgressSlot {
    let bar = NSProgressIndicator()
    let busyIndicator = NSProgressIndicator()
    let label = NSTextField(labelWithString: "")

    init() {
        bar.style = .bar
        bar.isIndeterminate = false
        bar.maxValue = 100
        bar.isHidden = true
        busyIndicator.style = .bar
        busyIndicator.isIndeterminate = true
        busyIndicator.isHidden = true
        label.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.alignment = .right
    }

    func show(_ fraction: Double?) {
        busyIndicator.isHidden = fraction != nil
        bar.isHidden = fraction == nil
        if let fraction {
            busyIndicator.stopAnimation(nil)
            bar.doubleValue = min(max(fraction, 0), 1) * 100
            label.stringValue = "\(Int(bar.doubleValue))%"
        } else {
            busyIndicator.startAnimation(nil)
            reset()
        }
    }

    func hide() {
        busyIndicator.stopAnimation(nil)
        busyIndicator.isHidden = true
        bar.isHidden = true
        reset()
    }

    private func reset() {
        bar.doubleValue = 0
        label.stringValue = ""
    }
}

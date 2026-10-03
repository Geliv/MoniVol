import AppKit
import SwiftUI

/// 使用原生滑块交互，为磨砂背景绘制对比度更高的音量轨道。
struct VolumeSlider: NSViewRepresentable {
    @Binding var value: Float
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.cell = VolumeSliderCell()
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.valueChanged(_:))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.doubleValue = Double(value)
        slider.setAccessibilityLabel(accessibilityLabel)
        slider.needsDisplay = true
    }

    final class Coordinator: NSObject {
        var value: Binding<Float>

        init(value: Binding<Float>) {
            self.value = value
        }

        @objc func valueChanged(_ slider: NSSlider) {
            value.wrappedValue = Float(slider.doubleValue)
        }
    }
}

private final class VolumeSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        let path = NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2)

        // labelColor 随浅色／深色外观切换，避免轨道融入透明卡片背景。
        NSColor.labelColor.withAlphaComponent(0.3).setFill()
        path.fill()

        // 按原生滑块中心定位填充终点，保留系统滑块的绘制与交互。
        let fillWidth = min(track.width, max(0, knobRect(flipped: flipped).midX - track.minX))
        guard doubleValue > minValue, fillWidth > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        path.addClip()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(
            x: track.minX, y: track.minY, width: fillWidth, height: track.height
        )).fill()
    }
}

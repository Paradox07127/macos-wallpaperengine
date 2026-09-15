import AppKit
import LiveWallpaperCore
import SwiftUI

struct NativePropertySlider: NSViewRepresentable {
    @Binding var value: Double
    let property: WallpaperEngineProjectPropertySchema.Property
    var onCommit: () -> Void = {}
    func makeNSView(context: Context) -> PrecisionSlider {
        let slider = PrecisionSlider()
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        return slider
    }

    func updateNSView(_ slider: PrecisionSlider, context: Context) {
        context.coordinator.parent = self
        let range = PropertyValueLogic.sliderRange(for: property)
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.authoredStep = PropertyValueLogic.sliderStep(for: property)
        slider.setAccessibilityLabel(property.displayText)
        slider.commit = onCommit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: NativePropertySlider
        init(_ parent: NativePropertySlider) {
            self.parent = parent
        }

        @objc func changed(_ sender: NSSlider) {
            parent.value = PropertyValueLogic.normalizedSliderValue(sender.doubleValue, for: parent.property)
        }
    }
}

final class PrecisionSlider: NSSlider {
    var authoredStep = 1.0
    var commit: () -> Void = {}
    func advance(_ direction: Double) {
        doubleValue = min(max(doubleValue + direction * authoredStep, minValue), maxValue)
        sendAction(action, to: target)
        commit()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: advance(-1)
        case 124, 126: advance(1)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        advance(1); return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        advance(-1); return true
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event); commit()
    }
}

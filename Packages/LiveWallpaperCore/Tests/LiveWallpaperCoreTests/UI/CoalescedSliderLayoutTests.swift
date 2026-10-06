import AppKit
@testable import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Coalesced slider form layout", .serialized)
@MainActor
struct CoalescedSliderLayoutTests {
    private final class Measurements {
        var referenceHeight: CGFloat = 0
        var sliderHeight: CGFloat = 0
        var readoutSize: CGSize = .zero
    }

    private struct SettingsForm: View {
        let value: Double
        let measurements: Measurements
        var boundedNumber = false

        var body: some View {
            Form {
                Section("Widgets") {
                    SettingRow(icon: "paintpalette", iconColor: .teal, title: "Widget tint") {
                        ColorPicker("", selection: .constant(Color.black), supportsOpacity: false)
                            .labelsHidden()
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { measurements.referenceHeight = $0 }
                    SettingRow(icon: "circle.lefthalf.filled", iconColor: .teal, title: "Widget opacity") {
                        CoalescedSlider(
                            value: value, in: boundedNumber ? -100000...100000 : 0...1, owner: "value",
                            sizing: .fixed(DesignTokens.Settings.sliderWidth),
                            accessibilityLabel: Text("Widget opacity"),
                            accessibilityValue: { Text(verbatim: "\(Int($0 * 100))%") },
                            write: { _ in },
                            readout: { live in
                                Group {
                                    if boundedNumber {
                                        Text(verbatim: String(format: "%.2f", live))
                                            .font(DesignTokens.Typography.metric)
                                            .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
                                    } else {
                                        Text(verbatim: "\(Int(live * 100))%")
                                    }
                                }
                                .onGeometryChange(for: CGSize.self, of: \.size) { measurements.readoutSize = $0 }
                            }
                        )
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { measurements.sliderHeight = $0 }
                }
            }
            .formStyle(.grouped)
        }
    }

    @Test("Percentage readouts stay visible and do not grow a settings row at 100%", arguments: [CGFloat(760), 1040])
    func percentageDoesNotChangeRowHeight(width: CGFloat) {
        checkRowHeight(width: width, boundedNumber: false, values: [0.5, 0.99, 1, 0.5])
    }

    @Test("Long signed numeric values in inspector-sized readout boxes do not wrap", arguments: [CGFloat(760), 1040])
    func boundedNumbersDoNotChangeRowHeight(width: CGFloat) {
        checkRowHeight(width: width, boundedNumber: true, values: [0, -12345.67, 99999.99, 0])
    }

    private func checkRowHeight(width: CGFloat, boundedNumber: Bool, values: [Double]) {
        _ = NSApplication.shared
        let measurements = Measurements()
        let host = NSHostingView(rootView: SettingsForm(value: values[0], measurements: measurements, boundedNumber: boundedNumber))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for value in values {
            host.rootView = SettingsForm(value: value, measurements: measurements, boundedNumber: boundedNumber)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            #expect(measurements.referenceHeight > 0)
            #expect(abs(measurements.sliderHeight - measurements.referenceHeight) < 1,
                    "\(value) grew the slider row to \(measurements.sliderHeight)pt")
            #expect(measurements.readoutSize.width > 0, "value must have space to render")
            #expect(measurements.readoutSize.height <= measurements.referenceHeight - 2 * DesignTokens.Spacing.xs,
                    "value must fit inside the row's content height")
        }
    }

    private struct OtherSettings: View {
        let value: Double
        let measurements: Measurements

        var body: some View {
            Form {
                Section("Memory") {
                    SettingRow(icon: "memorychip", iconColor: .pink, title: "Video preload (RAM)") {
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
                                Text("Off").font(DesignTokens.Typography.caption)
                                CoalescedSlider(
                                    value: value, in: 0...1024, step: 32, owner: "preload",
                                    sizing: .flexible(minimum: 0, maximum: .infinity),
                                    accessibilityLabel: Text("Video preload (RAM)"),
                                    accessibilityValue: { Text(verbatim: "\(Int($0)) MB") },
                                    write: { _ in },
                                    readout: { _ in Text("1 GB").font(DesignTokens.Typography.caption) }
                                )
                            }
                            .frame(width: DesignTokens.Settings.sliderWidth)
                            Text(verbatim: value == 0 ? "Streaming only" : "\(Int(value)) MB · \(Int(value) * 2) MB total")
                                .font(DesignTokens.Typography.metric)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { measurements.sliderHeight = $0 }
                    SettingRow(icon: "gauge", iconColor: .teal, title: "Frame Rate") {
                        FrameRateControl(
                            value: .constant(value == 0 ? .matchDisplay : .fps120),
                            displayFramesPerSecond: 120, layout: .presets,
                            accessibilityLabel: Text("Default frame rate")
                        )
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { measurements.referenceHeight = $0 }
                }
            }
            .formStyle(.grouped)
        }
    }

    @Test("Preload budget and frame-rate settings keep their own heights at the limits")
    func otherSettingsKeepTheirHeight() {
        let measurements = Measurements()
        let host = NSHostingView(rootView: OtherSettings(value: 0, measurements: measurements))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        var baseline: (CGFloat, CGFloat)?
        for value in [0.0, 32, 1024, 0] {
            host.rootView = OtherSettings(value: value, measurements: measurements)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            #expect(measurements.sliderHeight > 0 && measurements.referenceHeight > 0)
            if let baseline {
                #expect(abs(measurements.sliderHeight - baseline.0) < 1, "preload readout wrapped at \(value) MB")
                #expect(abs(measurements.referenceHeight - baseline.1) < 1, "frame-rate row changed height")
            } else {
                baseline = (measurements.sliderHeight, measurements.referenceHeight)
            }
        }
    }
}

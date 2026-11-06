import HushCore
import SwiftUI

/// Six vertical sliders: Clear Bass and five frequency bands, -10...+10.
/// Moving any of them switches the headphones to the Custom preset.
struct BandEditor: View {
    let headphones: Headphones

    private static let labels = ["Bass", "400", "1k", "2.5k", "6.3k", "16k"]
    private static let spokenLabels = ["Clear Bass", "400 hertz", "1 kilohertz", "2.5 kilohertz", "6.3 kilohertz", "16 kilohertz"]

    var body: some View {
        let bands = currentBands

        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(bands.indices, id: \.self) { index in
                    VStack(spacing: 6) {
                        Text(offsetText(bands[index]))
                            .font(.readout)
                            .foregroundStyle(bands[index] == Equalizer.flat ? .tertiary : .primary)
                            .contentTransition(.numericText(value: Double(bands[index])))
                            .animation(.snappy(duration: 0.2), value: bands[index])
                        BandSlider(value: bands[index], label: spokenLabel(index)) { headphones.setBand(index, to: $0) }
                            .frame(height: 112)
                        Text(index < Self.labels.count ? Self.labels[index] : "\(index + 1)")
                            .font(.detail)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            HStack {
                Text(isCustom ? "Custom" : "Moving a band switches to Custom")
                    .font(.detail)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                Spacer()
                Button("Flat") { headphones.resetBands() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(bands.allSatisfy { $0 == Equalizer.flat })
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: .rect(cornerRadius: Layout.tileRadius, style: .continuous))
    }

    private var currentBands: [Int] {
        let bands = headphones.equalizer?.bands ?? []
        return bands.count >= 6 ? bands : Array(repeating: Equalizer.flat, count: 6)
    }

    private var isCustom: Bool {
        headphones.equalizer?.presetID == EqualizerPreset.custom
    }

    private func spokenLabel(_ index: Int) -> String {
        index < Self.spokenLabels.count ? Self.spokenLabels[index] : "Band \(index + 1)"
    }

    private func offsetText(_ value: Int) -> String {
        let offset = value - Equalizer.flat
        return offset > 0 ? "+\(offset)" : "\(offset)"
    }
}

/// A vertical fader. The fill grows from the middle (flat) toward the knob;
/// the knob is a solid cap at rest and turns into a glass lens while dragged.
private struct BandSlider: View {
    let value: Int
    let label: String
    let onChange: (Int) -> Void

    @GestureState private var isDragging = false

    private let range = Equalizer.bandRange
    private let knob = CGSize(width: 22, height: 14)

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let travel = height - knob.height
            let fraction = CGFloat(value - range.lowerBound) / CGFloat(range.count - 1)
            let knobY = knob.height / 2 + (1 - fraction) * travel
            let midY = knob.height / 2 + travel / 2

            ZStack(alignment: .top) {
                Capsule()
                    .fill(.fill.secondary)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)

                // Flat mark.
                Capsule()
                    .fill(.tertiary)
                    .frame(width: 10, height: 1.5)
                    .offset(y: midY - 0.75)

                Capsule()
                    .fill(.tint)
                    .frame(width: 4, height: abs(knobY - midY))
                    .offset(y: min(knobY, midY))

                Capsule()
                    .fill(.white.opacity(isDragging ? 0 : 1))
                    .shadow(color: .black.opacity(isDragging ? 0 : 0.22), radius: 1.5, y: 0.5)
                    .frame(width: knob.width, height: knob.height)
                    .glassEffect(isDragging ? .regular.interactive() : .identity, in: .capsule)
                    .scaleEffect(isDragging ? 1.2 : 1)
                    .offset(y: knobY - knob.height / 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .animation(.snappy(duration: 0.18), value: value)
            .animation(.snappy(duration: 0.25, extraBounce: 0.1), value: isDragging)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { drag in
                        let position = (drag.location.y - knob.height / 2) / travel
                        let raw = (1 - position) * CGFloat(range.count - 1) + CGFloat(range.lowerBound)
                        let next = Int(raw.rounded()).clamped(to: range)
                        if next != value { onChange(next) }
                    }
            )
            .onTapGesture(count: 2) { onChange(Equalizer.flat) }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(value - Equalizer.flat)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(value + 1, range.upperBound))
            case .decrement: onChange(max(value - 1, range.lowerBound))
            @unknown default: break
            }
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

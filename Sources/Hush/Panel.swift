import AppKit
import HushCore
import SwiftUI

/// The menu bar panel. One screen, no navigation. Three tiers:
///
/// 1. What you glance at or change most: battery, noise mode (and the
///    ambient level when it applies).
/// 2. Listening: the equalizer preset, with the bands one click away.
/// 3. Set-and-forget device settings, folded under "Settings" so the default
///    view stays short. It expands in place and remembers its state.
struct Panel: View {
    @Bindable var headphones: Headphones

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.section) {
            Header(headphones: headphones)

            Group {
                switch headphones.status {
                case .searching:
                    EmptyState(
                        symbol: "headphones.slash",
                        title: "Not Connected",
                        detail: "Turn on your \(headphones.name) or connect it in Bluetooth settings."
                    ) {
                        Button("Bluetooth Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                        }
                        .buttonStyle(.glass)
                    }
                case .unsupported:
                    EmptyState(
                        symbol: "exclamationmark.triangle",
                        title: "Model Not Supported",
                        detail: "Hush speaks the protocol used by the WH-1000XM4. Newer models use a different one."
                    ) { EmptyView() }
                case .unreachable(let reason):
                    EmptyState(symbol: "antenna.radiowaves.left.and.right.slash", title: "Can’t Reach Your Headphones", detail: reason) {
                        Button("Try Again") { headphones.retry() }
                            .buttonStyle(.glassProminent)
                    }
                case .connecting where headphones.noise == nil:
                    ConnectingState()
                case .connecting, .connected, .resting:
                    Controls(headphones: headphones)
                        .disabled(headphones.status == .connecting)
                        .opacity(headphones.status == .connecting ? 0.5 : 1)
                }
            }
            .transition(.opacity)
        }
        .padding(Layout.margin)
        .frame(width: 320)
        .animation(.smooth(duration: 0.3), value: headphones.status)
        .onAppear { headphones.panelOpened() }
    }
}

// MARK: - Design tokens

/// One 8pt rhythm for the whole panel.
enum Layout {
    static let margin: CGFloat = 16
    static let section: CGFloat = 16
    static let rowHeight: CGFloat = 28
    static let iconColumn: CGFloat = 20
    static let iconGap: CGFloat = 8
    static let tileRadius: CGFloat = 16
    /// How far a row's hover highlight bleeds past the content edge.
    static let rowInset: CGFloat = 8
}

/// Two text sizes plus the title: 13pt for rows, 11pt for anything secondary.
extension Font {
    static let rowTitle = Font.body
    static let detail = Font.subheadline
    static let readout = Font.subheadline.weight(.medium).monospacedDigit()
}

extension Animation {
    /// Expanding and collapsing sections.
    static let disclose = Animation.smooth(duration: 0.32)
    /// Selection moving between mode tiles.
    static let select = Animation.snappy(duration: 0.32, extraBounce: 0.06)
}

// MARK: - Header

private struct Header: View {
    @Bindable var headphones: Headphones

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headphones.name)
                    .font(.headline)
                Text(statusText)
                    .font(.detail)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 0)

            if let battery = headphones.battery {
                BatteryPill(battery: battery)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            MoreMenu(headphones: headphones)
        }
        .animation(.smooth(duration: 0.3), value: headphones.battery == nil)
    }

    private var statusText: String {
        switch headphones.status {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .resting: "Idle"
        case .searching: "Not connected"
        case .unsupported: "Unsupported"
        case .unreachable: "Unavailable"
        }
    }
}

private struct BatteryPill: View {
    let battery: Battery

    private var isLow: Bool { battery.level <= 15 && !battery.isCharging }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .symbolRenderingMode(isLow ? .monochrome : .hierarchical)
                .foregroundStyle(isLow ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .contentTransition(.symbolEffect(.replace))
            Text("\(battery.level)%")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(battery.level)))
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .glassEffect(.regular, in: .capsule)
        .animation(.smooth, value: battery)
        .help(battery.isCharging ? "Charging" : isLow ? "Battery low" : "Battery")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue(battery.isCharging ? "\(battery.level) percent, charging" : "\(battery.level) percent")
    }

    private var symbol: String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

private struct MoreMenu: View {
    @Bindable var headphones: Headphones

    var body: some View {
        Menu {
            if headphones.status != .searching {
                Button("Turn Off Headphones", systemImage: "power") { headphones.turnOff() }
                Divider()
                Button("Reconnect", systemImage: "arrow.clockwise") { headphones.retry() }
            }
            Button("Show Log", systemImage: "doc.text") {
                NSWorkspace.shared.activateFileViewerSelecting([Log.url])
            }
            Divider()
            Button("Quit Hush") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .frame(width: 28, height: 28)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        // Same height and glass as the battery pill beside it.
        .glassEffect(.regular.interactive(), in: .circle)
        .help("More")
        .accessibilityLabel("More")
    }
}

// MARK: - Controls

private struct Controls: View {
    @Bindable var headphones: Headphones
    @AppStorage("showBands") private var showBands = false
    @AppStorage("showSettings") private var showSettings = false

    private var isAmbient: Bool { headphones.noise?.mode == .ambient }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.section) {
            // Tier 1: noise control.
            VStack(alignment: .leading, spacing: 12) {
                ModeSwitcher(headphones: headphones)

                if isAmbient {
                    AmbientControls(headphones: headphones)
                        .transition(.disclosure)
                }
            }

            // Tier 2: listening.
            VStack(alignment: .leading, spacing: 4) {
                EqualizerRow(headphones: headphones, showBands: $showBands)

                if showBands {
                    BandEditor(headphones: headphones)
                        .padding(.top, 4)
                        .transition(.disclosure)
                }
            }

            // Tier 3: set-and-forget settings, folded away.
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                    .padding(.bottom, 8)

                DisclosureRow(title: "Settings", isExpanded: $showSettings)

                if showSettings {
                    SettingsSection(headphones: headphones)
                        .transition(.disclosure)
                }
            }
        }
        .animation(.disclose, value: isAmbient)
        .animation(.disclose, value: showBands)
        .animation(.disclose, value: showSettings)
    }
}

private struct SettingsSection: View {
    @Bindable var headphones: Headphones

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let speakToChat = headphones.speakToChat {
                ToggleRow(symbol: "bubble.left.and.text.bubble.right", title: "Speak-to-Chat", isOn: speakToChat) {
                    headphones.setSpeakToChat($0)
                }
            }
            if let pause = headphones.pauseWhenTakenOff {
                ToggleRow(symbol: "pause.circle", title: "Pause When Taken Off", isOn: pause) {
                    headphones.setPauseWhenTakenOff($0)
                }
            }
            if headphones.touchPanel != nil, let enabled = headphones.touchPanelEnabled {
                ToggleRow(symbol: "hand.tap", title: "Touch Controls", isOn: enabled) {
                    headphones.setTouchPanel($0)
                }
            }
            AutoOffRow(headphones: headphones)
        }
    }
}

// MARK: - Mode switcher

private struct ModeSwitcher: View {
    let headphones: Headphones
    @Namespace private var selection

    private var current: NoiseMode? { headphones.noise?.mode }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(NoiseMode.selectable, id: \.self) { mode in
                        ModeTile(mode: mode, isSelected: current == mode, selection: selection) {
                            headphones.setMode(mode)
                        }
                    }
                }
            }
            .animation(.select, value: current)

            if current == .windReduction {
                Label("Wind noise reduction is on (set on the headphones).", systemImage: "wind")
                    .font(.detail)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ModeTile: View {
    let mode: NoiseMode
    let isSelected: Bool
    let selection: Namespace.ID
    let action: () -> Void

    @ViewState private var bounce = 0
    @ViewState private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle { .rect(cornerRadius: Layout.tileRadius, style: .continuous) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .symbolEffect(.bounce, value: bounce)
                    .frame(height: 22)
                Text(mode.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 4)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, minHeight: 64)
            .background {
                if isSelected {
                    // One highlight that slides between tiles.
                    shape
                        .fill(Color.accentColor.gradient)
                        .matchedGeometryEffect(id: "selection", in: selection)
                } else if isHovering && isEnabled {
                    shape.fill(Color.primary.opacity(0.05))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: shape)
        .onHover { isHovering = $0 }
        .onChange(of: isSelected) { _, selected in
            if selected { bounce += 1 }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AmbientControls: View {
    let headphones: Headphones

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SliderRow(
                symbol: "ear",
                label: "Ambient Sound Level",
                value: Binding(
                    get: { Double(headphones.ambientLevel) },
                    set: { headphones.setAmbientLevel(Int($0.rounded())) }
                ),
                range: Double(NoiseControl.levelRange.lowerBound)...Double(NoiseControl.levelRange.upperBound),
                valueText: "\(headphones.ambientLevel)"
            )

            ToggleRow(symbol: "person.wave.2", title: "Focus on Voice", isOn: headphones.noise?.focusOnVoice ?? false) {
                headphones.setFocusOnVoice($0)
            }
        }
    }
}

// MARK: - Rows

private struct RowIcon: View {
    let symbol: String

    init(_ symbol: String) { self.symbol = symbol }

    var body: some View {
        Image(systemName: symbol)
            .font(.body)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(width: Layout.iconColumn)
            .accessibilityHidden(true)
    }
}

/// Lays a row out on the shared grid and, when the whole row is clickable,
/// gives it a quiet hover highlight that bleeds slightly past the content edge.
private struct RowChrome: ViewModifier {
    var isClickable = false
    @ViewState private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .frame(minHeight: Layout.rowHeight)
            .padding(.horizontal, Layout.rowInset)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isClickable && isHovering && isEnabled ? 0.06 : 0))
            }
            .padding(.horizontal, -Layout.rowInset)
            .onHover { hovering in
                guard isClickable else { return }
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
    }
}

private extension View {
    func rowChrome(clickable: Bool = false) -> some View {
        modifier(RowChrome(isClickable: clickable))
    }
}

private struct SliderRow: View {
    let symbol: String
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueText: String

    var body: some View {
        HStack(spacing: Layout.iconGap) {
            RowIcon(symbol)
            Slider(value: $value, in: range)
                .controlSize(.small)
                .accessibilityLabel(label)
            Text(valueText)
                .font(.readout)
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: valueText)
                .accessibilityHidden(true)
        }
        .rowChrome()
    }
}

private struct ToggleRow: View {
    let symbol: String
    let title: String
    let isOn: Bool
    let onChange: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack(spacing: Layout.iconGap) {
            // Clicking anywhere on the row flips the switch, like a menu item.
            Button { onChange(!isOn) } label: {
                HStack(spacing: Layout.iconGap) {
                    RowIcon(symbol)
                    Text(title).font(.rowTitle)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            Toggle(title, isOn: Binding(get: { isOn }, set: onChange))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .rowChrome(clickable: true)
    }
}

/// A row that folds a section open or closed: title with a rotating chevron.
private struct DisclosureRow: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: Layout.iconGap) {
                Text(title)
                    .font(.detail.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Chevron(isExpanded: isExpanded)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .rowChrome(clickable: true)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides \(title.lowercased())" : "Shows \(title.lowercased())")
    }
}

private struct Chevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}

private struct EqualizerRow: View {
    let headphones: Headphones
    @Binding var showBands: Bool

    var body: some View {
        HStack(spacing: Layout.iconGap) {
            // The title doubles as the disclosure for the band editor.
            Button {
                showBands.toggle()
            } label: {
                HStack(spacing: Layout.iconGap) {
                    RowIcon("slider.vertical.3")
                    Text("Equalizer").font(.rowTitle)
                    Chevron(isExpanded: showBands)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(showBands ? "Hide bands" : "Edit bands")
            .accessibilityLabel("Equalizer Bands")
            .accessibilityValue(showBands ? "Shown" : "Hidden")

            Menu(currentName) {
                ForEach(headphones.presets) { preset in
                    Button {
                        headphones.selectPreset(preset.id)
                    } label: {
                        if preset.id == headphones.equalizer?.presetID {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Equalizer Preset")
        }
        .rowChrome(clickable: true)
    }

    private var currentName: String {
        guard let id = headphones.equalizer?.presetID else { return "—" }
        return headphones.presets.first { $0.id == id }?.name ?? EqualizerPreset.fallbackName(id)
    }
}

/// Turn the headphones off after this long with no audio playing.
private struct AutoOffRow: View {
    @Bindable var headphones: Headphones

    var body: some View {
        HStack(spacing: Layout.iconGap) {
            RowIcon("moon.zzz")
            Text("Auto Power Off").font(.rowTitle)
            Spacer(minLength: 0)
            Menu(headphones.autoPowerOff.shortTitle) {
                Picker("Auto Power Off", selection: $headphones.autoPowerOff) {
                    ForEach(AutoPowerOff.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Auto Power Off")
        }
        .rowChrome()
        .help("Turns the headphones off after this long with no audio playing on this Mac")
    }
}

// MARK: - States

private struct ConnectingState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "headphones")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating)
        }
        // The header already says "Connecting…"; this just breathes.
        .frame(maxWidth: .infinity, minHeight: 140)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connecting")
    }
}

private struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(height: 36)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions().padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

private extension AnyTransition {
    /// Content folding open below its header.
    static var disclosure: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    }
}

// MARK: - Labels

extension NoiseMode {
    var title: String {
        switch self {
        case .noiseCancelling: "Noise Cancelling"
        case .windReduction: "Wind"
        case .ambient: "Ambient"
        case .off: "Off"
        }
    }

    var symbol: String {
        switch self {
        case .noiseCancelling: "headphones"
        case .windReduction: "wind"
        case .ambient: "ear.and.waveform"
        case .off: "circle.slash"
        }
    }
}

/// The `State` property wrapper, named so it doesn't resolve to the `@State`
/// macro, whose compiler plugin the Command Line Tools don't ship.
typealias ViewState<Value> = State<Value>

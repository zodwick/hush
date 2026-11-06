// Payload formats for the WH-1000XM4 ("protocol v1"). Cross-checked against
// three independent implementations: Gadgetbridge (Android), Plutoberth's
// SonyHeadphonesClient, and tanat's sony-connect-osx (tested on the XM4).

// MARK: - Settings

public enum NoiseMode: Equatable, Sendable {
    case noiseCancelling
    /// Wind noise reduction. The XM4 can report it, but Sony's app no longer
    /// offers it, so Hush shows it and doesn't let you pick it.
    case windReduction
    case ambient
    case off

    public static let selectable: [NoiseMode] = [.noiseCancelling, .ambient, .off]
}

public struct NoiseControl: Equatable, Sendable {
    public static let levelRange: ClosedRange<Int> = 1...20

    public var mode: NoiseMode
    /// Ambient sound level. Only meaningful in ambient mode.
    public var level: Int
    public var focusOnVoice: Bool
    /// Setting-type bytes as the device reported them. Firmware revisions
    /// differ here, so we echo back what the device uses.
    public var ncSettingType: UInt8 = 0x02
    public var asmSettingType: UInt8 = 0x01

    public init(mode: NoiseMode, level: Int, focusOnVoice: Bool, ncSettingType: UInt8 = 0x02, asmSettingType: UInt8 = 0x01) {
        self.mode = mode
        self.level = level
        self.focusOnVoice = focusOnVoice
        self.ncSettingType = ncSettingType
        self.asmSettingType = asmSettingType
    }
}

public struct Battery: Equatable, Sendable {
    public var level: Int
    public var isCharging: Bool

    public init(level: Int, isCharging: Bool) {
        self.level = level
        self.isCharging = isCharging
    }
}

public struct EqualizerPreset: Equatable, Hashable, Sendable, Identifiable {
    public static let off: UInt8 = 0x00
    /// The preset the band sliders edit.
    public static let custom: UInt8 = 0xA0
    /// Sending bands under this id makes them persist (0xA0 is a preview
    /// the device forgets on the next connection). Per tanat's notes on
    /// what Sony's app does.
    static let unspecified: UInt8 = 0xFF

    public var id: UInt8
    public var name: String

    public init(id: UInt8, name: String) {
        self.id = id
        self.name = name
    }

    public init(id: UInt8) {
        self.init(id: id, name: Self.fallbackName(id))
    }

    public static func fallbackName(_ id: UInt8) -> String {
        switch id {
        case 0x00: "Off"
        case 0x01: "Rock"
        case 0x02: "Pop"
        case 0x03: "Jazz"
        case 0x04: "Dance"
        case 0x05: "EDM"
        case 0x06: "R&B / Hip-Hop"
        case 0x07: "Acoustic"
        case 0x10: "Bright"
        case 0x11: "Excited"
        case 0x12: "Mellow"
        case 0x13: "Relaxed"
        case 0x14: "Vocal"
        case 0x15: "Treble Boost"
        case 0x16: "Bass Boost"
        case 0x17: "Speech"
        case 0xA0: "Custom"
        case 0xA1...0xA5: "User \(id - 0xA0)"
        default: "Preset \(id)"
        }
    }

    /// The XM4's fallback list, used until the device sends its own.
    public static let defaults: [EqualizerPreset] = [0x00, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0xA0]
        .map { EqualizerPreset(id: $0) }
}

public struct Equalizer: Equatable, Sendable {
    /// Band values 0...20 where 10 is flat. On the XM4: Clear Bass, then
    /// 400 Hz, 1 kHz, 2.5 kHz, 6.3 kHz, 16 kHz.
    public static let bandRange: ClosedRange<Int> = 0...20
    public static let flat = 10

    public var presetID: UInt8
    public var bands: [Int]

    public init(presetID: UInt8, bands: [Int]) {
        self.presetID = presetID
        self.bands = bands
    }
}

/// A "general setting" slot. The XM4 keeps its touch-panel switch in one of
/// these, and which slot it is varies by firmware, so it's discovered by name.
public struct GeneralSetting: Equatable, Sendable {
    public static let slots: [UInt8] = [0xD1, 0xD2, 0xD3]
    public static let touchPanelName = "TOUCH_PANEL_SETTING"

    public var slot: UInt8
    public var name: String
    public var isList: Bool

    public init(slot: UInt8, name: String, isList: Bool) {
        self.slot = slot
        self.name = name
        self.isList = isList
    }
}

// MARK: - Outgoing commands

public enum Command: Equatable, Sendable {
    case initialize
    case getBattery
    case getNoiseControl
    case setNoiseControl(NoiseControl)
    case getEqualizerPresets
    case getEqualizer
    case setEqualizerPreset(UInt8)
    case setEqualizerBands([Int])
    case getSpeakToChat
    case setSpeakToChat(Bool)
    case getPauseWhenTakenOff
    case setPauseWhenTakenOff(Bool)
    case getGeneralSettingInfo(slot: UInt8)
    case getGeneralSetting(slot: UInt8)
    case setGeneralSetting(GeneralSetting, enabled: Bool)
    case powerOff
    /// Arbitrary payload, for exploring the protocol from the debug CLI.
    case raw([UInt8])

    public var payload: [UInt8] {
        switch self {
        case .raw(let bytes):
            return bytes
        case .initialize:
            return [0x00, 0x00]
        case .getBattery:
            return [0x10, 0x00]
        case .getNoiseControl:
            return [0x66, 0x02]
        case .setNoiseControl(let nc):
            let effect: UInt8 = nc.mode == .off ? 0x00 : 0x11
            let value: UInt8 = switch nc.mode {
            case .noiseCancelling: 0x02
            case .windReduction: 0x01
            case .ambient, .off: 0x00
            }
            let level: UInt8 = switch nc.mode {
            case .ambient, .off: UInt8(nc.level.clamped(to: NoiseControl.levelRange))
            case .noiseCancelling, .windReduction: 0x00
            }
            return [0x68, 0x02, effect, nc.ncSettingType, value, nc.asmSettingType, nc.focusOnVoice ? 0x01 : 0x00, level]
        case .getEqualizerPresets:
            return [0x50, 0x01, 0x00]
        case .getEqualizer:
            return [0x56, 0x01]
        case .setEqualizerPreset(let id):
            return [0x58, 0x01, id, 0x00]
        case .setEqualizerBands(let bands):
            return [0x58, 0x01, EqualizerPreset.unspecified, UInt8(bands.count)]
                + bands.map { UInt8($0.clamped(to: Equalizer.bandRange)) }
        case .getSpeakToChat:
            return [0xF6, 0x05]
        case .setSpeakToChat(let enabled):
            return [0xF8, 0x05, 0x01, enabled ? 0x01 : 0x00]
        case .getPauseWhenTakenOff:
            return [0xF6, 0x03]
        case .setPauseWhenTakenOff(let enabled):
            return [0xF8, 0x03, 0x00, enabled ? 0x01 : 0x00]
        case .getGeneralSettingInfo(let slot):
            return [0xD0, slot, 0x00]
        case .getGeneralSetting(let slot):
            return [0xD6, slot]
        case .setGeneralSetting(let setting, let enabled):
            return [0xD8, setting.slot, setting.isList ? 0x02 : 0x01, enabled ? 0x01 : 0x00]
        case .powerOff:
            return [0x22, 0x00, 0x01]
        }
    }

    /// Settings commands of the same kind replace each other in the queue, so
    /// dragging a slider sends the latest value instead of every step.
    func supersedes(_ other: Command) -> Bool {
        switch (self, other) {
        case (.setNoiseControl, .setNoiseControl),
             (.setEqualizerPreset, .setEqualizerPreset), (.setEqualizerPreset, .setEqualizerBands),
             (.setEqualizerBands, .setEqualizerBands), (.setEqualizerBands, .setEqualizerPreset),
             (.setSpeakToChat, .setSpeakToChat), (.setPauseWhenTakenOff, .setPauseWhenTakenOff):
            true
        case (.setGeneralSetting(let a, _), .setGeneralSetting(let b, _)):
            a.slot == b.slot
        default:
            false
        }
    }
}

// MARK: - Incoming payloads

public enum HeadphoneEvent: Equatable, Sendable {
    /// Reply to `.initialize`. `supported` is false for newer models that
    /// speak protocol v2 (for example the XM5).
    case initialized(supported: Bool)
    case battery(Battery)
    case noiseControl(NoiseControl)
    case equalizerPresets([EqualizerPreset])
    case equalizer(Equalizer)
    case speakToChat(Bool)
    /// Pause playback when the headphones come off your head.
    case pauseWhenTakenOff(Bool)
    case generalSettingInfo(GeneralSetting)
    case generalSetting(slot: UInt8, enabled: Bool)
    /// A payload Hush doesn't use. Kept so the log shows what the device sent.
    case unhandled(code: UInt8)
}

public enum PayloadParser {
    public static func parse(_ p: [UInt8]) -> HeadphoneEvent? {
        guard let code = p.first else { return nil }

        switch code {
        case 0x01:
            // v1 devices (XM3, XM4) answer with 4 bytes, v2 devices with 8.
            return .initialized(supported: p.count != 8)

        case 0x11, 0x13:
            guard p.count >= 4, p[1] == 0x00, p[2] <= 100 else { return nil }
            return .battery(Battery(level: Int(p[2]), isCharging: p[3] == 0x01))

        case 0x67, 0x69:
            return parseNoiseControl(p)

        case 0x51:
            return parseEqualizerPresets(p)

        case 0x57, 0x59:
            guard p.count >= 4, p[1] == 0x01 else { return nil }
            let count = Int(p[3])
            let bands = p.count >= 4 + count ? p[4..<(4 + count)].map(Int.init) : []
            return .equalizer(Equalizer(presetID: p[2], bands: bands))

        case 0xF7, 0xF9:
            // System settings, by sub-type in p[1]. The middle byte is 0x00
            // in replies and 0x01 in notifications; other values are
            // unrelated status pushes.
            guard p.count >= 4, p[2] <= 0x01 else { return .unhandled(code: code) }
            switch p[1] {
            case 0x05: return .speakToChat(p[3] != 0x00)
            case 0x03: return .pauseWhenTakenOff(p[3] != 0x00)
            default: return .unhandled(code: code)
            }

        case 0xD1:
            return parseGeneralSettingInfo(p)

        case 0xD7, 0xD9:
            guard p.count >= 4 else { return nil }
            return .generalSetting(slot: p[1], enabled: p[3] != 0x00)

        default:
            return .unhandled(code: code)
        }
    }

    // [67|69] 02 effect ncType ncValue asmType asmId asmLevel
    private static func parseNoiseControl(_ p: [UInt8]) -> HeadphoneEvent? {
        guard p.count >= 8, p[1] == 0x02, Int(p[7]) <= NoiseControl.levelRange.upperBound else { return nil }

        let mode: NoiseMode
        if p[2] == 0x00 {
            mode = .off
        } else if p[3] == 0x02 {
            // Dual/single/off: 2 is full noise cancelling, 1 is wind.
            switch p[4] {
            case 0x00: mode = .ambient
            case 0x01: mode = .windReduction
            default: mode = .noiseCancelling
            }
        } else {
            mode = p[4] == 0x00 ? .ambient : .noiseCancelling
        }

        return .noiseControl(NoiseControl(
            mode: mode, level: Int(p[7]), focusOnVoice: p[6] == 0x01,
            ncSettingType: p[3], asmSettingType: p[5]
        ))
    }

    // 51 01 bandCount levelSteps presetCount { id nameLength name… }*
    private static func parseEqualizerPresets(_ p: [UInt8]) -> HeadphoneEvent? {
        guard p.count >= 5, p[1] == 0x01 else { return nil }
        var presets: [EqualizerPreset] = []
        var i = 5
        for _ in 0..<Int(p[4]) {
            guard i + 1 < p.count else { break }
            let id = p[i]
            let end = i + 2 + Int(p[i + 1])
            guard end <= p.count else { break }
            let decoded = String(decoding: p[(i + 2)..<end], as: UTF8.self)
            presets.append(EqualizerPreset(id: id, name: decoded.isEmpty ? EqualizerPreset.fallbackName(id) : decoded))
            i = end
        }
        // The five "user" slots aren't editable here, and Custom goes last
        // because it's the one the band sliders write to.
        presets.removeAll { (0xA1...0xA5).contains($0.id) }
        if let custom = presets.firstIndex(where: { $0.id == EqualizerPreset.custom }) {
            presets.append(presets.remove(at: custom))
        }
        return presets.isEmpty ? nil : .equalizerPresets(presets)
    }

    // D1 slot nameFormat nameLength name… descLength desc… settingType
    private static func parseGeneralSettingInfo(_ p: [UInt8]) -> HeadphoneEvent? {
        guard p.count >= 5 else { return nil }
        let nameEnd = 4 + Int(p[3])
        guard nameEnd < p.count else { return nil }
        let descEnd = nameEnd + 1 + Int(p[nameEnd])
        guard descEnd < p.count else { return nil }
        let name = String(decoding: p[4..<nameEnd], as: UTF8.self)
        return .generalSettingInfo(GeneralSetting(slot: p[1], name: name, isList: p[descEnd] == 0x02))
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

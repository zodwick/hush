import Foundation
import HushCore

/// Lets `hushctl` query and drive a running Hush from the terminal.
///
/// Off unless Hush was started with `-DebugControl YES` (or the default is
/// set), because any local process can post distributed notifications.
@MainActor
final class DebugControl {
    static let commandName = Notification.Name("com.zodwick.hush.debug.command")
    static let replyName = Notification.Name("com.zodwick.hush.debug.reply")

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "DebugControl") }

    private let headphones: Headphones
    private var observer: NSObjectProtocol?

    init(headphones: Headphones) {
        self.headphones = headphones
    }

    func start() {
        Log.info("debug", "debug control enabled")
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.commandName, object: nil, queue: .main
        ) { [weak self] note in
            let id = note.object as? String ?? ""
            let args = note.userInfo?["args"] as? [String] ?? []
            MainActor.assumeIsolated { self?.handle(id: id, args: args) }
        }
    }

    private func handle(id: String, args: [String]) {
        Log.info("debug", "command: \(args.joined(separator: " "))")
        let result = run(args)
        switch result {
        case .now(let text):
            reply(id, text)
        case .afterSettling:
            // Give the headphones a moment to confirm, then report state.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1200))
                guard let self else { return }
                self.reply(id, self.status())
            }
        case .failure(let text):
            Log.info("debug", "rejected: \(text)")
            reply(id, "error: \(text)", ok: false)
        }
    }

    private enum Result {
        case now(String)
        case afterSettling
        case failure(String)
    }

    private func run(_ args: [String]) -> Result {
        guard let verb = args.first else { return .now(status()) }
        let value = args.count > 1 ? args[1] : nil
        let h = headphones

        switch verb {
        case "status":
            return .now(status())

        case "mode":
            switch value {
            case "nc", "noise": h.setMode(.noiseCancelling)
            case "ambient": h.setMode(.ambient)
            case "off": h.setMode(.off)
            default: return .failure("mode nc|ambient|off")
            }
            return .afterSettling

        case "ambient":
            guard let level = value.flatMap(Int.init), NoiseControl.levelRange.contains(level) else {
                return .failure("ambient 1-20")
            }
            if h.noise?.mode != .ambient { h.setMode(.ambient) }
            h.setAmbientLevel(level)
            return .afterSettling

        case "voice", "stc", "touch", "pause":
            guard let on = value.flatMap(parseBool) else { return .failure("\(verb) on|off") }
            switch verb {
            case "voice": h.setFocusOnVoice(on)
            case "stc": h.setSpeakToChat(on)
            case "pause": h.setPauseWhenTakenOff(on)
            default: h.setTouchPanel(on)
            }
            return .afterSettling

        case "eq":
            guard let value else {
                return .now(h.presets.map { String(format: "%02X  %@", $0.id, $0.name) }.joined(separator: "\n"))
            }
            let preset = h.presets.first { $0.name.lowercased() == value.lowercased() }
                ?? UInt8(value, radix: 16).map { EqualizerPreset(id: $0) }
            guard let preset else { return .failure("unknown preset; run `hushctl eq` for the list") }
            h.selectPreset(preset.id)
            return .afterSettling

        case "bands":
            let offsets = args.dropFirst().compactMap(Int.init)
            guard offsets.count == 6, offsets.allSatisfy({ (-10...10).contains($0) }) else {
                return .failure("bands takes 6 values from -10 to 10 (Clear Bass, 400, 1k, 2.5k, 6.3k, 16k)")
            }
            for (index, offset) in offsets.enumerated() { h.setBand(index, to: offset + Equalizer.flat) }
            return .afterSettling

        case "autooff":
            let minutes = value == "never" ? 0 : value.flatMap(Int.init)
            guard let minutes, let option = AutoPowerOff(rawValue: minutes) else {
                return .failure("autooff never|5|30|60|180")
            }
            h.autoPowerOff = option
            return .now(status())

        case "send":
            let bytes = args.dropFirst().joined().replacingOccurrences(of: " ", with: "")
            guard bytes.count.isMultiple(of: 2), !bytes.isEmpty,
                  let payload = parseHex(bytes) else { return .failure("send <hex payload>, e.g. send 66 02") }
            h.sendRaw(payload)
            return .now("sent [\(Log.hex(payload))]; replies are in the log (hushctl log)")

        case "rest":
            h.rest()
            return .now(status())

        case "reconnect":
            h.retry()
            return .afterSettling

        case "poweroff":
            h.turnOff()
            return .now("power off sent")

        default:
            return .failure("unknown command \(verb)")
        }
    }

    private func status() -> String {
        let h = headphones
        var lines = ["status:       \(describe(h.status))", "device:       \(h.name)"]
        if let b = h.battery { lines.append("battery:      \(b.level)%\(b.isCharging ? " (charging)" : "")") }
        if let nc = h.noise {
            var mode = "\(nc.mode)"
            if nc.mode == .ambient { mode += " level \(h.ambientLevel)\(nc.focusOnVoice ? ", focus on voice" : "")" }
            lines.append("noise:        \(mode)")
        }
        if let eq = h.equalizer {
            let name = h.presets.first { $0.id == eq.presetID }?.name ?? EqualizerPreset.fallbackName(eq.presetID)
            let bands = eq.bands.map { String(format: "%+d", $0 - Equalizer.flat) }.joined(separator: " ")
            lines.append("equalizer:    \(name) [\(bands)]")
        }
        if let stc = h.speakToChat { lines.append("speakToChat:  \(stc ? "on" : "off")") }
        if let touch = h.touchPanelEnabled { lines.append("touch:        \(touch ? "on" : "off")") }
        if let pause = h.pauseWhenTakenOff { lines.append("pauseOnRemove: \(pause ? "on" : "off")") }
        lines.append("autoPowerOff: \(h.autoPowerOff.title)")
        return lines.joined(separator: "\n")
    }

    private func describe(_ status: Headphones.Status) -> String {
        switch status {
        case .unreachable(let reason): "unreachable (\(reason))"
        default: "\(status)"
        }
    }

    private func reply(_ id: String, _ text: String, ok: Bool = true) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.replyName, object: id, userInfo: ["output": text, "ok": ok], deliverImmediately: true)
    }

    private func parseBool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "on", "yes", "true", "1": true
        case "off", "no", "false", "0": false
        default: nil
        }
    }

    private func parseHex(_ text: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

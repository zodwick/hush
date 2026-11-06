import CoreAudio
import Foundation
import HushCore
@preconcurrency import IOBluetooth
import Observation

enum AutoPowerOff: Int, CaseIterable, Identifiable {
    case never = 0
    case fiveMinutes = 5
    case thirtyMinutes = 30
    case oneHour = 60
    case threeHours = 180

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .never: "Never"
        case .fiveMinutes: "After 5 min idle"
        case .thirtyMinutes: "After 30 min idle"
        case .oneHour: "After 1 hour idle"
        case .threeHours: "After 3 hours idle"
        }
    }

    /// Compact label for the panel's picker.
    var shortTitle: String {
        switch self {
        case .never: "Never"
        case .fiveMinutes: "5 min"
        case .thirtyMinutes: "30 min"
        case .oneHour: "1 hour"
        case .threeHours: "3 hours"
        }
    }
}

/// Everything the UI shows and does. Owns the Bluetooth link and drives the
/// HushCore session.
///
/// Lifecycle:
///
///     searching ──headphones connect──▶ connecting ──init──▶ connected
///         ▲                                ▲   │                 │
///         └──────headphones disconnect─────┼───┴──── link drops ─┤
///                                          │  (retry 1s,2s,4s,8s, then unreachable)
///                                          │                     │
///                                          └── panel opened / ── resting
///                                              audio starts      (idle 5 min)
@MainActor
@Observable
final class Headphones {
    enum Status: Equatable {
        /// The headphones aren't connected to this Mac.
        case searching
        case connecting
        case connected
        /// Data channel closed after a quiet spell to save headphone
        /// battery. Reopens when the panel opens or audio starts.
        case resting
        /// A newer Sony model that speaks a protocol Hush doesn't support.
        case unsupported
        /// Gave up after the retries. The panel offers a manual retry.
        case unreachable(String)
    }

    // MARK: State shown in the UI

    private(set) var status: Status = .searching
    private(set) var name = "WH-1000XM4"
    private(set) var battery: Battery?
    private(set) var noise: NoiseControl?
    /// Ambient level to restore when switching back to ambient mode. The
    /// device reports 0 while noise cancelling is on.
    private(set) var ambientLevel = 10
    private(set) var presets = EqualizerPreset.defaults
    private(set) var equalizer: Equalizer?
    private(set) var speakToChat: Bool?
    private(set) var pauseWhenTakenOff: Bool?
    private(set) var touchPanel: GeneralSetting?
    private(set) var touchPanelEnabled: Bool?

    var autoPowerOff: AutoPowerOff {
        didSet {
            UserDefaults.standard.set(autoPowerOff.rawValue, forKey: Self.autoPowerOffKey)
            idleSince = nil
            Log.info("policy", "auto power off: \(autoPowerOff.title)")
        }
    }

    var isLive: Bool { status == .connected }

    // MARK: Tuning

    static let ackTimeout: Duration = .milliseconds(1500)
    static let initTimeout: Duration = .seconds(2)
    /// The first write right after the channel opens tends to get lost.
    static let settleDelay: Duration = .milliseconds(200)
    static let openTimeout: Duration = .seconds(5)
    static let reopenDelay: Duration = .seconds(1)
    static let reconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]
    static let restAfter: Duration = .seconds(5 * 60)
    static let policyInterval: Duration = .seconds(30)
    /// After a local change, ignore device reports for this long so a slow
    /// echo can't snap a slider back, then ask the device for the truth.
    static let echoGrace: Duration = .milliseconds(700)
    private static let autoPowerOffKey = "autoPowerOff"

    // MARK: Plumbing

    private let link = BluetoothLink()
    private let watcher = DeviceWatcher()
    private var session = Session()
    private var parser = FrameParser()
    private var device: IOBluetoothDevice?
    private var output: AudioOutput?

    /// Bumped on every new connection, so timers from an old one do nothing.
    private var generation = 0
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var policyTask: Task<Void, Never>?
    private var confirmTasks: [String: Task<Void, Never>] = [:]
    private var lastLocalChange: [String: ContinuousClock.Instant] = [:]
    private var lastActivity = ContinuousClock.now
    private var idleSince: ContinuousClock.Instant?
    /// Commands asked for while the link was closed, sent once it's ready.
    private var pending: [Command] = []
    /// True between asking IOBluetooth to open the channel and hearing back.
    private var opening = false

    init() {
        autoPowerOff = AutoPowerOff(rawValue: UserDefaults.standard.integer(forKey: Self.autoPowerOffKey)) ?? .never
    }

    func start() {
        Log.info("app", "Hush started")
        link.onEvent = { [weak self] in self?.handle($0) }
        watcher.onConnect = { [weak self] in self?.headphonesAppeared($0) }
        watcher.onDisconnect = { [weak self] _ in self?.headphonesGone() }
        watcher.start()

        if let device = DeviceWatcher.connectedHeadphones() {
            headphonesAppeared(device)
        }

        policyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.policyInterval)
                self?.runPolicy()
            }
        }
    }

    // MARK: User intents

    func panelOpened() {
        noteActivity()
        attachAudioOutput()
        switch status {
        case .resting, .unreachable:
            reconnectAttempt = 0
            connect()
        case .connected:
            // Cheap resync in case something changed while we weren't looking.
            enqueue(.getBattery)
            enqueue(.getNoiseControl)
        default:
            break
        }
    }

    func setMode(_ mode: NoiseMode) {
        var nc = noise ?? NoiseControl(mode: mode, level: ambientLevel, focusOnVoice: false)
        nc.mode = mode
        nc.level = ambientLevel
        noise = nc
        sendSetting("noise", .setNoiseControl(nc), confirmWith: .getNoiseControl)
    }

    func setAmbientLevel(_ level: Int) {
        guard var nc = noise, level != ambientLevel else { return }
        ambientLevel = level
        guard nc.mode == .ambient else { return }
        nc.level = level
        noise = nc
        sendSetting("noise", .setNoiseControl(nc), confirmWith: .getNoiseControl)
    }

    func setFocusOnVoice(_ on: Bool) {
        guard var nc = noise else { return }
        nc.focusOnVoice = on
        nc.level = ambientLevel
        noise = nc
        sendSetting("noise", .setNoiseControl(nc), confirmWith: .getNoiseControl)
    }

    func selectPreset(_ id: UInt8) {
        equalizer = Equalizer(presetID: id, bands: equalizer?.bands ?? [])
        sendSetting("eq", .setEqualizerPreset(id), confirmWith: .getEqualizer)
    }

    func setBand(_ index: Int, to value: Int) {
        var bands = equalizer?.bands ?? []
        if bands.count < 6 { bands = Array(repeating: Equalizer.flat, count: 6) }
        guard bands.indices.contains(index), bands[index] != value else { return }
        bands[index] = value
        equalizer = Equalizer(presetID: EqualizerPreset.custom, bands: bands)
        sendSetting("eq", .setEqualizerBands(bands), confirmWith: .getEqualizer)
    }

    func resetBands() {
        let bands = Array(repeating: Equalizer.flat, count: max(equalizer?.bands.count ?? 6, 6))
        equalizer = Equalizer(presetID: EqualizerPreset.custom, bands: bands)
        sendSetting("eq", .setEqualizerBands(bands), confirmWith: .getEqualizer)
    }

    func setSpeakToChat(_ on: Bool) {
        speakToChat = on
        sendSetting("stc", .setSpeakToChat(on), confirmWith: .getSpeakToChat)
    }

    func setPauseWhenTakenOff(_ on: Bool) {
        pauseWhenTakenOff = on
        sendSetting("pause", .setPauseWhenTakenOff(on), confirmWith: .getPauseWhenTakenOff)
    }

    func setTouchPanel(_ on: Bool) {
        guard let touchPanel else { return }
        touchPanelEnabled = on
        sendSetting("touch", .setGeneralSetting(touchPanel, enabled: on), confirmWith: .getGeneralSetting(slot: touchPanel.slot))
    }

    func turnOff() {
        Log.info("cmd", "power off requested")
        MediaPause.pause()
        enqueue(.powerOff)
    }

    /// Debug CLI: send an arbitrary payload and see the reply in the log.
    func sendRaw(_ payload: [UInt8]) {
        Log.info("cmd", "raw [\(Log.hex(payload))]")
        enqueue(.raw(payload))
    }

    func retry() {
        Log.info("app", "manual reconnect")
        reconnectTask?.cancel()
        closeLink()
        reconnectAttempt = 0
        if device == nil { device = DeviceWatcher.connectedHeadphones() }
        // Reopening the instant after a close hangs: give the channel a
        // moment to really close first.
        status = .connecting
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reopenDelay)
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    // MARK: Connection

    private func headphonesAppeared(_ device: IOBluetoothDevice) {
        if self.device == device, status == .connecting || status == .connected { return }
        self.device = device
        name = device.name ?? name
        reconnectAttempt = 0
        attachAudioOutput()
        connect()
    }

    private func headphonesGone() {
        reconnectTask?.cancel()
        closeLink()
        pending.removeAll()
        device = nil
        detachAudioOutput()
        battery = nil
        status = .searching
    }

    private func connect() {
        guard let device, device.isConnected() else {
            status = .searching
            return
        }
        guard !link.isOpen, !opening else { return }
        reconnectTask = nil
        opening = true
        status = .connecting
        parser = FrameParser()
        session = Session()
        generation += 1
        Log.info("link", "connecting to \(name)")
        link.open(device)

        // IOBluetooth sometimes never reports back on an open. Don't wait
        // forever: treat it as a dropped link, which retries with backoff.
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(for: Self.openTimeout)
            guard let self, self.generation == gen, self.opening else { return }
            Log.info("link", "open timed out after \(Self.openTimeout)")
            self.link.close()
            self.linkLost("timed out opening the data channel")
        }
    }

    /// Closes the data channel to save headphone battery. Internal so the
    /// debug CLI can trigger it without waiting five idle minutes.
    func rest() {
        Log.info("policy", "idle for \(Self.restAfter), closing data channel to save battery")
        closeLink()
        status = .resting
    }

    private func closeLink() {
        link.close()
        opening = false
        session = Session()
    }

    private func linkLost(_ reason: String) {
        opening = false
        session = Session()
        guard status != .resting, status != .unsupported else { return }
        guard let device, device.isConnected() else {
            status = .searching
            return
        }
        guard reconnectAttempt < Self.reconnectDelays.count else {
            Log.info("link", "giving up: \(reason)")
            status = .unreachable(reason)
            return
        }
        let delay = Self.reconnectDelays[reconnectAttempt]
        reconnectAttempt += 1
        status = .connecting
        Log.info("link", "retry \(reconnectAttempt)/\(Self.reconnectDelays.count) in \(delay): \(reason)")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func handle(_ event: BluetoothLink.Event) {
        switch event {
        case .opened:
            opening = false
            let gen = generation
            Task { [weak self] in
                try? await Task.sleep(for: Self.settleDelay)
                guard let self, self.generation == gen else { return }
                self.perform(self.session.start())
                try? await Task.sleep(for: Self.initTimeout)
                guard self.generation == gen else { return }
                self.perform(self.session.initTimedOut())
            }

        case .received(let bytes):
            for result in parser.feed(bytes) {
                switch result {
                case .success(let frame):
                    Log.info("rx", "\(frame.type) seq \(frame.sequence) [\(Log.hex(frame.payload))]")
                    perform(session.receive(frame))
                case .failure(let error):
                    Log.info("rx", "dropped bad frame: \(error)")
                }
            }

        case .closed(let reason):
            linkLost(reason)
        }
    }

    // MARK: Session plumbing

    private func perform(_ outputs: [Session.Output]) {
        for output in outputs {
            switch output {
            case .send(let bytes, let awaitsAck, let token):
                if awaitsAck { Log.info("tx", "[\(Log.hex(bytes))]") }
                link.write(bytes)
                if awaitsAck { scheduleAckTimeout(token) }

            case .phase(.ready):
                status = .connected
                reconnectAttempt = 0
                noteActivity()
                Log.info("session", "ready")
                for command in initialQueries + pending { perform(session.enqueue(command)) }
                pending.removeAll()

            case .phase(.unsupported):
                Log.info("session", "unsupported model")
                status = .unsupported
                closeLink()

            case .phase:
                break

            case .event(let event):
                apply(event)

            case .unresponsive(let command):
                Log.info("session", "no ACK for \(command) after \(Session.maxAttempts) tries")
                closeLink()
                linkLost("headphones stopped responding")
            }
        }
    }

    private var initialQueries: [Command] {
        [.getNoiseControl, .getBattery, .getSpeakToChat, .getPauseWhenTakenOff, .getEqualizerPresets, .getEqualizer]
            + GeneralSetting.slots.map { .getGeneralSettingInfo(slot: $0) }
    }

    private func scheduleAckTimeout(_ token: Int) {
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(for: Self.ackTimeout)
            guard let self, self.generation == gen else { return }
            self.perform(self.session.ackTimedOut(token: token))
        }
    }

    private func enqueue(_ command: Command) {
        switch session.phase {
        case .initializing, .ready:
            perform(session.enqueue(command))
        case .idle:
            // Link closed (resting or between retries): send once it's back.
            pending.removeAll { $0 == command }
            pending.append(command)
            if status == .resting { connect() }
        case .unsupported:
            break
        }
    }

    private func sendSetting(_ key: String, _ command: Command, confirmWith confirm: Command) {
        noteActivity()
        lastLocalChange[key] = .now
        enqueue(command)
        confirmTasks[key]?.cancel()
        confirmTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: Self.echoGrace)
            guard !Task.isCancelled else { return }
            self?.enqueue(confirm)
        }
    }

    private func recentlyChanged(_ key: String) -> Bool {
        guard let last = lastLocalChange[key] else { return false }
        return ContinuousClock.now - last < Self.echoGrace
    }

    private func apply(_ event: HeadphoneEvent) {
        switch event {
        case .battery(let value):
            battery = value
        case .noiseControl(var value):
            guard !recentlyChanged("noise") else { return }
            if value.mode == .ambient || value.mode == .off, value.level > 0 { ambientLevel = value.level }
            value.level = ambientLevel
            noise = value
        case .equalizerPresets(let value):
            presets = value
        case .equalizer(let value):
            guard !recentlyChanged("eq") else { return }
            equalizer = value.bands.isEmpty ? Equalizer(presetID: value.presetID, bands: equalizer?.bands ?? []) : value
        case .speakToChat(let value):
            guard !recentlyChanged("stc") else { return }
            speakToChat = value
        case .pauseWhenTakenOff(let value):
            guard !recentlyChanged("pause") else { return }
            pauseWhenTakenOff = value
        case .generalSettingInfo(let setting):
            Log.info("session", "setting slot \(String(format: "%02X", setting.slot)) is \(setting.name)")
            if setting.name == GeneralSetting.touchPanelName {
                touchPanel = setting
                enqueue(.getGeneralSetting(slot: setting.slot))
            }
        case .generalSetting(let slot, let enabled):
            guard slot == touchPanel?.slot, !recentlyChanged("touch") else { return }
            touchPanelEnabled = enabled
        case .initialized:
            break
        case .unhandled(let code):
            Log.info("session", "ignored payload type \(String(format: "%02X", code))")
        }
    }

    // MARK: Mac audio and policy

    private func noteActivity() {
        lastActivity = .now
    }

    private func attachAudioOutput() {
        guard output == nil, device != nil, let found = AudioOutput.named(name) else { return }
        output = found
        Log.info("audio", "found output device \(found.id)")
    }

    private func detachAudioOutput() {
        output = nil
    }

    /// Runs every 30 s: keeps the link open while audio plays, rests it when
    /// idle, and powers the headphones off if the user asked for that.
    private func runPolicy() {
        guard device != nil else { return }
        attachAudioOutput()
        let now = ContinuousClock.now
        let playing = output?.isPlaying ?? false

        if playing {
            idleSince = nil
            noteActivity()
            if status == .resting { connect() }
            return
        }

        let idleStart = idleSince ?? now
        idleSince = idleStart

        if autoPowerOff != .never, now - idleStart >= .seconds(autoPowerOff.rawValue * 60) {
            Log.info("policy", "idle for \(autoPowerOff.rawValue) min, powering off")
            idleSince = nil
            turnOff()
            return
        }

        if status == .connected, now - lastActivity >= Self.restAfter {
            rest()
        }
    }
}

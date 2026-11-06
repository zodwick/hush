/// The conversation with the headphones, as a pure state machine.
///
/// Rules of the protocol:
/// - Only one command may wait for an ACK at a time; the rest queue up.
/// - The headphones ACK with sequence `1 - ours`, and we adopt that number for
///   the next command.
/// - Every command the headphones send us must be ACKed with `1 - theirs`.
/// - The session starts with `.initialize`; the reply tells us whether the
///   model speaks the protocol Hush supports.
///
/// The session never touches Bluetooth or timers. It returns `Output`s, and the
/// caller performs them. That keeps every rule here testable without hardware.
public struct Session: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case initializing
        case ready
        case unsupported
    }

    public enum Output: Equatable, Sendable {
        /// Write these bytes. If `awaitsAck`, call `ackTimedOut(token:)` with
        /// `token` if no ACK arrives in time.
        case send(bytes: [UInt8], awaitsAck: Bool, token: Int)
        case event(HeadphoneEvent)
        case phase(Phase)
        /// A command got no ACK after every retry. The link is likely dead.
        case unresponsive(Command)
    }

    public static let maxAttempts = 3

    public private(set) var phase: Phase = .idle
    private var sequence: UInt8 = 0
    private var queue: [Command] = []
    private var inFlight: (command: Command, frame: [UInt8], attempts: Int, token: Int)?
    private var nextToken = 0
    private var initDeadlinePassed = false

    public init() {}

    public var isAwaitingAck: Bool { inFlight != nil }

    // MARK: Inputs

    public mutating func start() -> [Output] {
        // Tokens keep counting across restarts so a timer left over from the
        // previous connection can never match a command in this one.
        let token = nextToken
        self = Session()
        nextToken = token
        phase = .initializing
        return [.phase(.initializing)] + transmit(.initialize)
    }

    public mutating func enqueue(_ command: Command) -> [Output] {
        guard phase == .initializing || phase == .ready else { return [] }
        queue.removeAll { command.supersedes($0) }
        queue.append(command)
        return pump()
    }

    public mutating func receive(_ frame: Frame) -> [Output] {
        switch frame.type {
        case .ack:
            // An ACK that repeats our own number is a duplicate. Ignore it.
            guard inFlight != nil, frame.sequence != sequence else { return [] }
            sequence = frame.sequence
            inFlight = nil
            if phase == .initializing && initDeadlinePassed {
                phase = .ready
                return [.phase(.ready)] + pump()
            }
            return pump()

        case .command1, .command2:
            var outputs: [Output] = [.send(bytes: ack(for: frame.sequence), awaitsAck: false, token: 0)]
            let event = PayloadParser.parse(frame.payload)

            if phase == .initializing {
                // Some firmware skips the init reply and just starts sending
                // state. Any message means the device is listening.
                if case .initialized(supported: false) = event {
                    phase = .unsupported
                    queue.removeAll()
                } else {
                    phase = .ready
                }
                outputs.append(.phase(phase))
            }
            if let event { outputs.append(.event(event)) }
            return outputs + pump()

        case .other:
            return []
        }
    }

    /// Call a couple of seconds after `start()`. If the device ACKed the init
    /// request but never replied, carry on anyway, as tanat's client does.
    public mutating func initTimedOut() -> [Output] {
        guard phase == .initializing else { return [] }
        initDeadlinePassed = true
        // Still waiting for the init ACK: decide when it arrives.
        guard inFlight == nil else { return [] }
        phase = .ready
        return [.phase(.ready)] + pump()
    }

    /// Call when the ACK for `token` didn't arrive in time.
    public mutating func ackTimedOut(token: Int) -> [Output] {
        guard let current = inFlight, current.token == token else { return [] }

        guard current.attempts < Self.maxAttempts else {
            inFlight = nil
            queue.removeAll()
            return [.unresponsive(current.command)]
        }

        nextToken += 1
        inFlight = (current.command, current.frame, current.attempts + 1, nextToken)
        return [.send(bytes: current.frame, awaitsAck: true, token: nextToken)]
    }

    // MARK: Internals

    /// Commands wait until the init reply arrives, so nothing is sent to a
    /// model we don't support.
    private mutating func pump() -> [Output] {
        guard inFlight == nil, phase == .ready, !queue.isEmpty else { return [] }
        return transmit(queue.removeFirst())
    }

    private mutating func transmit(_ command: Command) -> [Output] {
        let frame = FrameCodec.encode(Frame(type: .command1, sequence: sequence, payload: command.payload))
        nextToken += 1
        inFlight = (command, frame, 1, nextToken)
        return [.send(bytes: frame, awaitsAck: true, token: nextToken)]
    }

    private func ack(for theirSequence: UInt8) -> [UInt8] {
        FrameCodec.encode(Frame(type: .ack, sequence: 1 &- theirSequence, payload: []))
    }
}

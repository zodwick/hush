/// Sony's headphone protocol wraps every message in a frame:
///
///     0x3E  escape( type · sequence · length(4, big endian) · payload · checksum )  0x3C
///
/// The checksum is the byte sum of everything between the markers, before
/// escaping. Inside the markers, the three marker bytes (0x3C, 0x3D, 0x3E) are
/// written as 0x3D followed by the byte with bit 4 cleared.
public struct Frame: Equatable, Sendable {
    public var type: MessageType
    public var sequence: UInt8
    public var payload: [UInt8]

    public init(type: MessageType, sequence: UInt8, payload: [UInt8]) {
        self.type = type
        self.sequence = sequence
        self.payload = payload
    }
}

public enum MessageType: Equatable, Sendable {
    case ack
    case command1
    case command2
    case other(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0x01: self = .ack
        case 0x0C: self = .command1
        case 0x0E: self = .command2
        default: self = .other(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .ack: 0x01
        case .command1: 0x0C
        case .command2: 0x0E
        case .other(let value): value
        }
    }
}

public enum FrameError: Error, Equatable, Sendable {
    case tooShort
    case danglingEscape
    case badChecksum
    case lengthMismatch
}

public enum FrameCodec {
    static let startMarker: UInt8 = 0x3E
    static let endMarker: UInt8 = 0x3C
    static let escapeByte: UInt8 = 0x3D
    static let escapeMask: UInt8 = 0b1110_1111

    public static func encode(_ frame: Frame) -> [UInt8] {
        var body: [UInt8] = [frame.type.rawValue, frame.sequence]
        let length = UInt32(frame.payload.count)
        body += [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        body += frame.payload
        body.append(checksum(body))
        return [startMarker] + escape(body) + [endMarker]
    }

    /// Decodes the bytes found between a start and an end marker (markers excluded).
    public static func decode(body escaped: [UInt8]) -> Result<Frame, FrameError> {
        let body: [UInt8]
        switch unescape(escaped) {
        case .success(let bytes): body = bytes
        case .failure(let error): return .failure(error)
        }

        // type + sequence + 4 length bytes + checksum
        guard body.count >= 7 else { return .failure(.tooShort) }

        let content = body.dropLast()
        guard checksum(content) == body.last else { return .failure(.badChecksum) }

        let length = Int(body[2]) << 24 | Int(body[3]) << 16 | Int(body[4]) << 8 | Int(body[5])
        guard length == body.count - 7 else { return .failure(.lengthMismatch) }

        return .success(Frame(
            type: MessageType(rawValue: body[0]),
            sequence: body[1],
            payload: Array(body[6..<(6 + length)])
        ))
    }

    static func checksum<C: Collection<UInt8>>(_ bytes: C) -> UInt8 {
        bytes.reduce(0, &+)
    }

    static func escape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for byte in bytes {
            if byte == startMarker || byte == endMarker || byte == escapeByte {
                out.append(escapeByte)
                out.append(byte & escapeMask)
            } else {
                out.append(byte)
            }
        }
        return out
    }

    static func unescape(_ bytes: [UInt8]) -> Result<[UInt8], FrameError> {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var iterator = bytes.makeIterator()
        while let byte = iterator.next() {
            if byte == escapeByte {
                guard let next = iterator.next() else { return .failure(.danglingEscape) }
                out.append(next | ~escapeMask)
            } else {
                out.append(byte)
            }
        }
        return .success(out)
    }
}

/// Reassembles frames from the raw Bluetooth byte stream. Data can arrive split
/// across several reads or with several frames in one read.
public struct FrameParser: Sendable {
    /// Bounded so a misbehaving device can't grow memory without limit.
    public static let maxBufferedBytes = 4096

    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [Result<Frame, FrameError>] {
        buffer += bytes
        var results: [Result<Frame, FrameError>] = []

        while true {
            guard let start = buffer.firstIndex(of: FrameCodec.startMarker) else {
                buffer.removeAll()
                break
            }
            if start > 0 { buffer.removeFirst(start) }

            guard let end = buffer.firstIndex(of: FrameCodec.endMarker) else {
                if buffer.count > Self.maxBufferedBytes { buffer.removeAll() }
                break
            }

            results.append(FrameCodec.decode(body: Array(buffer[1..<end])))
            buffer.removeFirst(end + 1)
        }

        return results
    }
}

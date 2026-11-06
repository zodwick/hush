import Testing
@testable import HushCore

@Suite struct FrameTests {
    @Test func encodesInitRequestExactly() {
        let bytes = FrameCodec.encode(Frame(type: .command1, sequence: 0, payload: [0x00, 0x00]))
        #expect(bytes == [0x3E, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x0E, 0x3C])
    }

    @Test func encodesAckExactly() {
        let bytes = FrameCodec.encode(Frame(type: .ack, sequence: 1, payload: []))
        #expect(bytes == [0x3E, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x02, 0x3C])
    }

    @Test func escapesMarkerBytesInsideTheFrame() {
        let frame = Frame(type: .command1, sequence: 0, payload: [0x3C, 0x3D, 0x3E])
        let bytes = FrameCodec.encode(frame)
        let inner = Array(bytes.dropFirst().dropLast())

        #expect(!inner.contains(0x3C) && !inner.contains(0x3E))
        #expect(bytes.suffix(8).prefix(6) == [0x3D, 0x2C, 0x3D, 0x2D, 0x3D, 0x2E])
        #expect(FrameCodec.decode(body: inner) == .success(frame))
    }

    @Test func escapesAChecksumThatLandsOnAMarker() {
        // 0x0C + 0x01 (length) + 0x2F = 0x3C, the end marker.
        let frame = Frame(type: .command1, sequence: 0, payload: [0x2F])
        let bytes = FrameCodec.encode(frame)
        #expect(bytes.suffix(3) == [0x3D, 0x2C, 0x3C])
        #expect(FrameCodec.decode(body: Array(bytes.dropFirst().dropLast())) == .success(frame))
    }

    @Test(arguments: [
        [], [0x00], [0x67, 0x02, 0x01, 0x02, 0x02, 0x01, 0x00, 0x00], (0...255).map { UInt8($0) },
    ] as [[UInt8]])
    func roundTrips(payload: [UInt8]) {
        let frame = Frame(type: .command2, sequence: 1, payload: payload)
        let bytes = FrameCodec.encode(frame)
        #expect(FrameCodec.decode(body: Array(bytes.dropFirst().dropLast())) == .success(frame))
    }

    @Test func rejectsCorruptFrames() {
        var body = Array(FrameCodec.encode(Frame(type: .command1, sequence: 0, payload: [0x10, 0x00])).dropFirst().dropLast())
        #expect(FrameCodec.decode(body: [0x0C, 0x00]) == .failure(.tooShort))
        #expect(FrameCodec.decode(body: body + [0x3D]) == .failure(.danglingEscape))

        body[body.count - 2] ^= 0xFF
        #expect(FrameCodec.decode(body: body) == .failure(.badChecksum))
    }

    @Test func rejectsWrongLength() {
        // Claims 3 payload bytes, carries 2. Checksum is valid.
        var body: [UInt8] = [0x0C, 0x00, 0x00, 0x00, 0x00, 0x03, 0x10, 0x00]
        body.append(FrameCodec.checksum(body))
        #expect(FrameCodec.decode(body: body) == .failure(.lengthMismatch))
    }

    @Test func parserReassemblesSplitAndMergedReads() {
        let a = Frame(type: .command1, sequence: 0, payload: [0x11, 0x00, 0x50, 0x00])
        let b = Frame(type: .ack, sequence: 1, payload: [])
        let stream = [0xAA, 0xBB] + FrameCodec.encode(a) + FrameCodec.encode(b)

        var parser = FrameParser()
        var frames: [Frame] = []
        for chunk in stride(from: 0, to: stream.count, by: 3).map({ Array(stream[$0..<min($0 + 3, stream.count)]) }) {
            frames += parser.feed(chunk).compactMap { try? $0.get() }
        }
        #expect(frames == [a, b])
    }

    @Test func parserDropsGarbageWithoutGrowingForever() {
        var parser = FrameParser()
        #expect(parser.feed([0x3E] + Array(repeating: 0x00, count: FrameParser.maxBufferedBytes + 10)).isEmpty)

        let good = Frame(type: .command1, sequence: 0, payload: [0x13, 0x00, 0x40, 0x00])
        #expect(parser.feed(FrameCodec.encode(good)).compactMap { try? $0.get() } == [good])
    }
}

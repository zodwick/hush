import Testing
@testable import HushCore

/// Plays the headphones' side of the conversation.
private struct FakeHeadphones {
    var sequence: UInt8 = 0

    func ack(_ sent: [UInt8]) -> Frame {
        let frame = decode(sent)
        return Frame(type: .ack, sequence: 1 &- frame.sequence, payload: [])
    }

    mutating func say(_ payload: [UInt8]) -> Frame {
        defer { sequence = 1 &- sequence }
        return Frame(type: .command1, sequence: sequence, payload: payload)
    }
}

private func decode(_ bytes: [UInt8]) -> Frame {
    try! FrameCodec.decode(body: Array(bytes.dropFirst().dropLast())).get()
}

private func commandsSent(_ outputs: [Session.Output]) -> [[UInt8]] {
    outputs.compactMap {
        if case .send(let bytes, true, _) = $0 { decode(bytes).payload } else { nil }
    }
}

private func acksSent(_ outputs: [Session.Output]) -> [Frame] {
    outputs.compactMap {
        if case .send(let bytes, false, _) = $0 { decode(bytes) } else { nil }
    }
}

private func lastSentBytes(_ outputs: [Session.Output]) -> [UInt8] {
    outputs.compactMap { if case .send(let bytes, true, _) = $0 { bytes } else { nil } }.last!
}

/// Runs init to `.ready` and returns the session with nothing in flight.
private func readySession() -> (Session, FakeHeadphones) {
    var session = Session()
    var device = FakeHeadphones()
    let initBytes = lastSentBytes(session.start())
    _ = session.receive(device.ack(initBytes))
    _ = session.receive(device.say([0x01, 0x00, 0x40, 0x10]))
    return (session, device)
}

@Suite struct SessionTests {
    @Test func startsWithInitAndHoldsCommandsUntilReady() {
        var session = Session()
        var device = FakeHeadphones()

        let started = session.start()
        #expect(started.first == .phase(.initializing))
        #expect(commandsSent(started) == [[0x00, 0x00]])

        #expect(session.enqueue(.getBattery).isEmpty)
        #expect(session.receive(device.ack(lastSentBytes(started))).isEmpty, "must not send before the init reply")

        let reply = session.receive(device.say([0x01, 0x00, 0x40, 0x10]))
        #expect(reply.contains(.phase(.ready)))
        #expect(reply.contains(.event(.initialized(supported: true))))
        #expect(commandsSent(reply) == [[0x10, 0x00]])
        #expect(session.phase == .ready)
    }

    @Test func acksEveryDeviceMessageWithTheFlippedSequence() {
        var (session, device) = readySession()
        let first = session.receive(device.say([0x13, 0x00, 0x40, 0x00]))
        let second = session.receive(device.say([0x13, 0x00, 0x3F, 0x00]))

        #expect(acksSent(first) == [Frame(type: .ack, sequence: 0, payload: [])])
        #expect(acksSent(second) == [Frame(type: .ack, sequence: 1, payload: [])])
        #expect(first.contains(.event(.battery(.init(level: 64, isCharging: false)))))
    }

    @Test func sendsOneCommandAtATimeAndAdoptsTheAckSequence() {
        var (session, device) = readySession()

        let a = session.enqueue(.getBattery)
        #expect(session.enqueue(.getNoiseControl).isEmpty, "second command waits for the first ACK")
        #expect(decode(lastSentBytes(a)).sequence == 1, "init ACK set our sequence to 1")

        let b = session.receive(device.ack(lastSentBytes(a)))
        #expect(commandsSent(b) == [[0x66, 0x02]])
        #expect(decode(lastSentBytes(b)).sequence == 0)

        #expect(session.receive(device.ack(lastSentBytes(b))).isEmpty)
        #expect(!session.isAwaitingAck)
    }

    @Test func ignoresDuplicateAcks() {
        var (session, device) = readySession()
        let sent = lastSentBytes(session.enqueue(.getBattery))
        _ = session.enqueue(.getNoiseControl)

        let ack = device.ack(sent)
        #expect(commandsSent(session.receive(ack)) == [[0x66, 0x02]])
        #expect(session.receive(ack).isEmpty, "same ACK again must not release the next command")
        #expect(session.isAwaitingAck)
    }

    @Test func newerSettingsReplaceQueuedOnes() {
        var (session, device) = readySession()
        let first = lastSentBytes(session.enqueue(.getBattery))

        for level in 1...10 {
            _ = session.enqueue(.setNoiseControl(.init(mode: .ambient, level: level, focusOnVoice: false)))
        }
        _ = session.enqueue(.setEqualizerPreset(0x12))
        _ = session.enqueue(.setEqualizerPreset(0x14))

        let next = session.receive(device.ack(first))
        #expect(commandsSent(next) == [[0x68, 0x02, 0x11, 0x02, 0x00, 0x01, 0x00, 10]])

        let last = session.receive(device.ack(lastSentBytes(next)))
        #expect(commandsSent(last) == [[0x58, 0x01, 0x14, 0x00]])
    }

    @Test func retriesThenReportsUnresponsive() {
        var (session, _) = readySession()
        let first = session.enqueue(.getBattery)
        guard case .send(let bytes, true, var token) = first.last! else { Issue.record(); return }

        for _ in 2...Session.maxAttempts {
            let retry = session.ackTimedOut(token: token)
            guard case .send(let again, true, let newToken) = retry.first! else { Issue.record(); return }
            #expect(again == bytes, "retry resends the identical frame")
            token = newToken
        }

        #expect(session.ackTimedOut(token: token) == [.unresponsive(.getBattery)])
        #expect(!session.isAwaitingAck)
    }

    @Test func staleTimeoutsAreIgnored() {
        var (session, device) = readySession()
        let first = session.enqueue(.getBattery)
        guard case .send(let bytes, true, let token) = first.last! else { Issue.record(); return }

        _ = session.receive(device.ack(bytes))
        #expect(session.ackTimedOut(token: token).isEmpty)
    }

    @Test func restartingNeverReusesTokens() {
        var session = Session()
        guard case .send(_, true, let oldToken) = session.start().last! else { Issue.record(); return }
        guard case .send(_, true, let newToken) = session.start().last! else { Issue.record(); return }
        #expect(newToken != oldToken)
        #expect(session.ackTimedOut(token: oldToken).isEmpty)
    }

    @Test func unsupportedModelsGetNoCommands() {
        var session = Session()
        var device = FakeHeadphones()
        let initBytes = lastSentBytes(session.start())
        _ = session.enqueue(.getBattery)
        _ = session.receive(device.ack(initBytes))

        let reply = session.receive(device.say([0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00]))
        #expect(reply.contains(.phase(.unsupported)))
        #expect(commandsSent(reply).isEmpty)
        #expect(session.enqueue(.getNoiseControl).isEmpty)
    }

    @Test func anyDeviceMessageCompletesInit() {
        var session = Session()
        var device = FakeHeadphones()
        let initBytes = lastSentBytes(session.start())
        _ = session.enqueue(.getBattery)
        _ = session.receive(device.ack(initBytes))

        // A state push instead of the canonical init reply.
        let push = session.receive(device.say([0x69, 0x02, 0x01, 0x02, 0x02, 0x01, 0x00, 0x00]))
        #expect(push.contains(.phase(.ready)))
        #expect(push.contains(.event(.noiseControl(.init(mode: .noiseCancelling, level: 0, focusOnVoice: false)))))
        #expect(commandsSent(push) == [[0x10, 0x00]])
    }

    @Test func initTimeoutCompletesInitAfterAck() {
        var session = Session()
        var device = FakeHeadphones()
        let initBytes = lastSentBytes(session.start())
        _ = session.enqueue(.getBattery)

        // Deadline passes while the init ACK is still outstanding.
        #expect(session.initTimedOut().isEmpty)
        let acked = session.receive(device.ack(initBytes))
        #expect(acked.contains(.phase(.ready)))
        #expect(commandsSent(acked) == [[0x10, 0x00]])
    }

    @Test func initTimeoutIsIgnoredOnceReady() {
        var (session, _) = readySession()
        #expect(session.initTimedOut().isEmpty)
    }

    @Test func touchPanelSetsOnlyReplaceTheSameSlot() {
        var (session, device) = readySession()
        let a = GeneralSetting(slot: 0xD1, name: "A", isList: false)
        let b = GeneralSetting(slot: 0xD2, name: "B", isList: false)
        let first = lastSentBytes(session.enqueue(.getBattery))
        _ = session.enqueue(.setGeneralSetting(a, enabled: true))
        _ = session.enqueue(.setGeneralSetting(b, enabled: true))
        _ = session.enqueue(.setGeneralSetting(a, enabled: false))

        let next = session.receive(device.ack(first))
        #expect(commandsSent(next) == [[0xD8, 0xD2, 0x01, 0x01]])
        #expect(commandsSent(session.receive(device.ack(lastSentBytes(next)))) == [[0xD8, 0xD1, 0x01, 0x00]])
    }
}

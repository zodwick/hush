import Testing
@testable import HushCore

@Suite struct ProtocolTests {
    @Test func setNoiseControlPayloads() {
        #expect(Command.setNoiseControl(.init(mode: .noiseCancelling, level: 12, focusOnVoice: false)).payload
            == [0x68, 0x02, 0x11, 0x02, 0x02, 0x01, 0x00, 0x00])
        #expect(Command.setNoiseControl(.init(mode: .ambient, level: 12, focusOnVoice: true)).payload
            == [0x68, 0x02, 0x11, 0x02, 0x00, 0x01, 0x01, 0x0C])
        #expect(Command.setNoiseControl(.init(mode: .off, level: 7, focusOnVoice: false)).payload
            == [0x68, 0x02, 0x00, 0x02, 0x00, 0x01, 0x00, 0x07])
    }

    @Test func noiseControlEchoesDeviceSettingTypes() {
        let nc = NoiseControl(mode: .ambient, level: 5, focusOnVoice: false, ncSettingType: 0x01, asmSettingType: 0x00)
        #expect(Command.setNoiseControl(nc).payload == [0x68, 0x02, 0x11, 0x01, 0x00, 0x00, 0x00, 0x05])
    }

    @Test func ambientLevelIsClamped() {
        #expect(Command.setNoiseControl(.init(mode: .ambient, level: 99, focusOnVoice: false)).payload.last == 20)
        #expect(Command.setNoiseControl(.init(mode: .ambient, level: -3, focusOnVoice: false)).payload.last == 1)
    }

    @Test func otherCommandPayloads() {
        #expect(Command.initialize.payload == [0x00, 0x00])
        #expect(Command.getBattery.payload == [0x10, 0x00])
        #expect(Command.getNoiseControl.payload == [0x66, 0x02])
        #expect(Command.getEqualizerPresets.payload == [0x50, 0x01, 0x00])
        #expect(Command.getEqualizer.payload == [0x56, 0x01])
        #expect(Command.setEqualizerPreset(0x16).payload == [0x58, 0x01, 0x16, 0x00])
        #expect(Command.getSpeakToChat.payload == [0xF6, 0x05])
        #expect(Command.setSpeakToChat(true).payload == [0xF8, 0x05, 0x01, 0x01])
        #expect(Command.getGeneralSettingInfo(slot: 0xD2).payload == [0xD0, 0xD2, 0x00])
        #expect(Command.getGeneralSetting(slot: 0xD1).payload == [0xD6, 0xD1])
        #expect(Command.powerOff.payload == [0x22, 0x00, 0x01])
        #expect(Command.getPauseWhenTakenOff.payload == [0xF6, 0x03])
        #expect(Command.setPauseWhenTakenOff(true).payload == [0xF8, 0x03, 0x00, 0x01])
        #expect(Command.setPauseWhenTakenOff(false).payload == [0xF8, 0x03, 0x00, 0x00])
    }

    @Test func customBandsPersistUnderUnspecifiedPreset() {
        #expect(Command.setEqualizerBands([10, 12, 8, 30, -1, 10]).payload
            == [0x58, 0x01, 0xFF, 0x06, 10, 12, 8, 20, 0, 10])
    }

    @Test func touchPanelPayloadFollowsSlotType() {
        let bool = GeneralSetting(slot: 0xD1, name: GeneralSetting.touchPanelName, isList: false)
        let list = GeneralSetting(slot: 0xD2, name: GeneralSetting.touchPanelName, isList: true)
        #expect(Command.setGeneralSetting(bool, enabled: false).payload == [0xD8, 0xD1, 0x01, 0x00])
        #expect(Command.setGeneralSetting(list, enabled: true).payload == [0xD8, 0xD2, 0x02, 0x01])
    }

    @Test func parsesInitReplies() {
        #expect(PayloadParser.parse([0x01, 0x00, 0x40, 0x10]) == .initialized(supported: true))
        #expect(PayloadParser.parse([0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00]) == .initialized(supported: false))
    }

    @Test func parsesNoiseControlModes() {
        #expect(PayloadParser.parse([0x67, 0x02, 0x01, 0x02, 0x02, 0x01, 0x00, 0x00])
            == .noiseControl(.init(mode: .noiseCancelling, level: 0, focusOnVoice: false)))
        #expect(PayloadParser.parse([0x69, 0x02, 0x11, 0x02, 0x00, 0x01, 0x01, 0x0F])
            == .noiseControl(.init(mode: .ambient, level: 15, focusOnVoice: true)))
        #expect(PayloadParser.parse([0x69, 0x02, 0x01, 0x02, 0x01, 0x01, 0x00, 0x00])
            == .noiseControl(.init(mode: .windReduction, level: 0, focusOnVoice: false)))
        #expect(PayloadParser.parse([0x67, 0x02, 0x00, 0x02, 0x00, 0x01, 0x00, 0x05])
            == .noiseControl(.init(mode: .off, level: 5, focusOnVoice: false)))
        #expect(PayloadParser.parse([0x67, 0x02, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00])
            == .noiseControl(.init(mode: .noiseCancelling, level: 0, focusOnVoice: false, ncSettingType: 0x01, asmSettingType: 0x00)))
    }

    @Test func rejectsMalformedNoiseControl() {
        #expect(PayloadParser.parse([0x67, 0x02, 0x01]) == nil)
        #expect(PayloadParser.parse([0x67, 0x01, 0x01, 0x02, 0x00, 0x01, 0x00, 0x00]) == nil)
        #expect(PayloadParser.parse([0x67, 0x02, 0x01, 0x02, 0x00, 0x01, 0x00, 0x30]) == nil)
    }

    @Test func parsesBattery() {
        #expect(PayloadParser.parse([0x11, 0x00, 0x50, 0x00]) == .battery(.init(level: 80, isCharging: false)))
        #expect(PayloadParser.parse([0x13, 0x00, 0x46, 0x01]) == .battery(.init(level: 70, isCharging: true)))
        #expect(PayloadParser.parse([0x11, 0x00, 0xFF, 0x00]) == nil)
    }

    @Test func parsesEqualizerState() {
        #expect(PayloadParser.parse([0x57, 0x01, 0x16, 0x06, 10, 12, 10, 10, 8, 10])
            == .equalizer(.init(presetID: 0x16, bands: [10, 12, 10, 10, 8, 10])))
        #expect(PayloadParser.parse([0x59, 0x01, 0xA0, 0x06, 10])
            == .equalizer(.init(presetID: 0xA0, bands: [])), "truncated bands keep the preset")
    }

    @Test func parsesEqualizerPresetNames() {
        let payload: [UInt8] = [0x51, 0x01, 0x06, 0x15, 0x04,
                                0x00, 0x00,                       // Off, no name
                                0xA0, 0x06] + Array("Custom".utf8) +
                               [0xA1, 0x00,                       // user slot, dropped
                                0x16, 0x04] + Array("Bass".utf8)
        #expect(PayloadParser.parse(payload) == .equalizerPresets([
            .init(id: 0x00, name: "Off"), .init(id: 0x16, name: "Bass"), .init(id: 0xA0, name: "Custom"),
        ]))
    }

    @Test func parsesSpeakToChatRepliesAndNotifications() {
        #expect(PayloadParser.parse([0xF7, 0x05, 0x00, 0x01]) == .speakToChat(true), "reply form")
        #expect(PayloadParser.parse([0xF9, 0x05, 0x01, 0x00]) == .speakToChat(false), "notify form")
        #expect(PayloadParser.parse([0xF9, 0x05, 0x02, 0x00]) == .unhandled(code: 0xF9))
    }

    @Test func parsesPauseWhenTakenOff() {
        #expect(PayloadParser.parse([0xF7, 0x03, 0x00, 0x01]) == .pauseWhenTakenOff(true))
        #expect(PayloadParser.parse([0xF9, 0x03, 0x01, 0x00]) == .pauseWhenTakenOff(false))
        #expect(PayloadParser.parse([0xF7, 0x04, 0x00, 0x01]) == .unhandled(code: 0xF7), "other sub-types stay unhandled")
    }

    @Test func parsesGeneralSettingDiscovery() {
        let name = Array(GeneralSetting.touchPanelName.utf8)
        let info: [UInt8] = [0xD1, 0xD2, 0x02, UInt8(name.count)] + name + [0x00, 0x01]
        #expect(PayloadParser.parse(info)
            == .generalSettingInfo(.init(slot: 0xD2, name: GeneralSetting.touchPanelName, isList: false)))
        #expect(PayloadParser.parse([0xD1, 0xD2, 0x02, 0x40]) == nil)

        #expect(PayloadParser.parse([0xD7, 0xD2, 0x01, 0x00]) == .generalSetting(slot: 0xD2, enabled: false))
        #expect(PayloadParser.parse([0xD9, 0xD2, 0x01, 0x01]) == .generalSetting(slot: 0xD2, enabled: true))
    }
}

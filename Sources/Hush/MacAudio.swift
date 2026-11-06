import AudioToolbox
import CoreAudio
import Foundation

/// The headphones as macOS sees them: an audio output device. Used to tell
/// whether anything is playing (for auto power off and idle rest). Public CoreAudio.
struct AudioOutput: Equatable {
    let id: AudioDeviceID

    /// The output device whose name contains `hint` (the Bluetooth name).
    static func named(_ hint: String) -> AudioOutput? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }

        return ids.lazy.map(AudioOutput.init).first { $0.hasOutput && ($0.name?.contains(hint) ?? false) }
    }

    var name: String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private var hasOutput: Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    /// True while any app is sending audio to the device.
    var isPlaying: Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}

/// Pauses whatever is playing, so audio doesn't jump to the Mac's speakers
/// when the headphones power off.
///
/// This uses MediaRemote, a private Apple framework, because there is no
/// public "pause" that works across apps (the play/pause key would start
/// playback if nothing is playing). It's loaded at runtime and simply skipped
/// if unavailable.
enum MediaPause {
    private typealias SendCommand = @convention(c) (Int, CFDictionary?) -> Bool

    private static let sendCommand: SendCommand? = {
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework") as CFURL
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url),
              let pointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString)
        else { return nil }
        return unsafeBitCast(pointer, to: SendCommand.self)
    }()

    static func pause() {
        guard let sendCommand else {
            Log.info("media", "pause unavailable")
            return
        }
        let pauseCommand = 1
        Log.info("media", "pause sent (\(sendCommand(pauseCommand, nil)))")
    }
}

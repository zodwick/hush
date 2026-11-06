import Foundation
@preconcurrency import IOBluetooth

/// The RFCOMM data channel to the headphones. Sony exposes its control
/// protocol as a serial-port service ("Serial HPC") next to the audio
/// profiles. This class only moves bytes; the protocol lives in HushCore.
///
/// IOBluetooth delivers every callback on the main run loop, which is why the
/// whole class is main-actor isolated.
@MainActor
final class BluetoothLink: NSObject {
    enum Event {
        case opened
        case received([UInt8])
        case closed(reason: String)
    }

    /// 96CC203E-5068-46AD-B32D-E316F5E069BA
    private static let serviceUUID: [UInt8] = [
        0x96, 0xCC, 0x20, 0x3E, 0x50, 0x68, 0x46, 0xAD,
        0xB3, 0x2D, 0xE3, 0x16, 0xF5, 0xE0, 0x69, 0xBA,
    ]

    var onEvent: ((Event) -> Void)?
    private(set) var isOpen = false
    private var channel: IOBluetoothRFCOMMChannel?
    private var awaitingSDP: IOBluetoothDevice?

    func open(_ device: IOBluetoothDevice) {
        close()
        if let record = serviceRecord(on: device) {
            openChannel(on: device, record: record)
            return
        }
        // The service record isn't cached yet: ask the device for its
        // services, then try once more in sdpQueryComplete.
        Log.info("link", "service record not cached, running SDP query")
        awaitingSDP = device
        let status = device.performSDPQuery(self)
        if status != kIOReturnSuccess {
            awaitingSDP = nil
            finish("SDP query failed (\(status))")
        }
    }

    func close() {
        awaitingSDP = nil
        guard let channel else { return }
        channel.setDelegate(nil)
        channel.close()
        self.channel = nil
        isOpen = false
    }

    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool {
        guard let channel, isOpen else { return false }
        var copy = bytes
        let status = copy.withUnsafeMutableBytes { buffer in
            channel.writeSync(buffer.baseAddress, length: UInt16(buffer.count))
        }
        if status != kIOReturnSuccess {
            Log.info("link", "write failed (\(status))")
            return false
        }
        return true
    }

    // MARK: Private

    private func serviceRecord(on device: IOBluetoothDevice) -> IOBluetoothSDPServiceRecord? {
        let uuid = Self.serviceUUID.withUnsafeBytes { IOBluetoothSDPUUID(bytes: $0.baseAddress, length: 16) }
        return device.getServiceRecord(for: uuid)
    }

    private func openChannel(on device: IOBluetoothDevice, record: IOBluetoothSDPServiceRecord) {
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            finish("Sony service has no RFCOMM channel")
            return
        }

        var opened: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
        guard status == kIOReturnSuccess, let opened else {
            finish("could not open RFCOMM channel \(channelID) (\(status))")
            return
        }
        channel = opened
        Log.info("link", "opening RFCOMM channel \(channelID)")
    }

    private func finish(_ reason: String) {
        let wasActive = channel != nil || isOpen
        close()
        Log.info("link", "closed: \(reason)\(wasActive ? "" : " (before open)")")
        onEvent?(.closed(reason: reason))
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard let pending = awaitingSDP, pending == device else { return }
        awaitingSDP = nil
        guard status == kIOReturnSuccess, let record = serviceRecord(on: pending) else {
            finish("Sony control service not found on this device")
            return
        }
        openChannel(on: pending, record: record)
    }
}

extension BluetoothLink: @preconcurrency IOBluetoothRFCOMMChannelDelegate {
    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard rfcommChannel === channel else { return }
        guard error == kIOReturnSuccess else {
            finish("RFCOMM open failed (\(error))")
            return
        }
        isOpen = true
        Log.info("link", "RFCOMM open, MTU \(rfcommChannel.getMTU())")
        onEvent?(.opened)
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard rfcommChannel === channel, let dataPointer else { return }
        onEvent?(.received(Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))))
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard rfcommChannel === channel else { return }
        finish("channel closed by device")
    }
}

/// Watches for the headphones connecting and disconnecting at the Bluetooth
/// level (the audio link), independent of our data channel.
@MainActor
final class DeviceWatcher: NSObject {
    static let nameHints = ["WH-1000XM4"]

    var onConnect: ((IOBluetoothDevice) -> Void)?
    var onDisconnect: ((IOBluetoothDevice) -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    static func isHeadphones(_ device: IOBluetoothDevice) -> Bool {
        guard let name = device.name else { return false }
        return nameHints.contains { name.contains($0) }
    }

    /// The paired headphones, if they're connected to this Mac right now.
    static func connectedHeadphones() -> IOBluetoothDevice? {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return paired.first { isHeadphones($0) && $0.isConnected() }
    }

    func start() {
        guard connectNotification == nil else { return }
        // Fires for every device that connects, and once at registration for
        // devices that are already connected.
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard Self.isHeadphones(device) else { return }
        let key = device.addressString ?? ""
        if disconnectNotifications[key] == nil {
            disconnectNotifications[key] = device.register(
                forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        }
        Log.info("watch", "\(device.name ?? "?") connected")
        onConnect?(device)
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        disconnectNotifications[device.addressString ?? ""] = nil
        Log.info("watch", "\(device.name ?? "?") disconnected")
        onDisconnect?(device)
    }
}

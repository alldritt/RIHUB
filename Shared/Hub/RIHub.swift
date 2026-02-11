//
//  RIHub.swift
//  RobotInventorHUB
//
//  Created by Mark Alldritt on 2020-03-02.
//  Copyright © 2020 Mark Alldritt. All rights reserved.
//

#if os(macOS)
import Cocoa

typealias RIColor = NSColor
typealias RIImage = NSImage
#else
import UIKit
import ExternalAccessory

typealias RIColor = UIColor
typealias RIImage = UIImage
#endif
import CoreBluetooth


extension Data {
    struct HexEncodingOptions: OptionSet {
        let rawValue: Int
        static let upperCase = HexEncodingOptions(rawValue: 1 << 0)
    }

    func hexEncodedString(options: HexEncodingOptions = []) -> String {
        let format = options.contains(.upperCase) ? "%02hhX" : "%02hhx"
        return map { String(format: format, $0) }.joined()
    }
}

//  Bluetooth UUID constants

let LEGOWirelessProtocolHubServiceUUIDString = "00001623-1212-EFDE-1623-785FEABCD123"
let LEGOWirelessProtocolHubCharacteristicUUIDString = "00001624-1212-EFDE-1623-785FEABCD123"

let LEGOHubServiceUUIDString = "FEED"

let SPIKEPrimeServiceUUIDString = "0000FD02-0000-1000-8000-00805F9B34FB"
let SPIKEPrimeRXCharacteristicUUIDString = "0000FD02-0001-1000-8000-00805F9B34FB"
let SPIKEPrimeTXCharacteristicUUIDString = "0000FD02-0002-1000-8000-00805F9B34FB"

let SerialServiceUUIDString = "2456e1b9-26e2-8f83-e744-f34f01e9d701"
let SerialCharacteristicUUIDString = "2456e1b9-26e2-8f83-e744-f34f01e9d703"

extension Date {
    static var usecTimestamp : Int64 {
        return Int64(Date().timeIntervalSince1970 * Double(USEC_PER_SEC) /* convert to Microseconds */)
    }
}


class RIHub : NSObject, CBPeripheralDelegate /*, Hashable */, ObservableObject {

    // MARK: - Transport

    enum Transport {
        case ble
        #if os(iOS)
        case externalAccessory
        #endif
    }

    enum State {
        case connected, connecting, disconnected, disconnecting

        var name: String {
            switch self {
            case .disconnected:
                return "Disconnected"

            case .disconnecting:
                return "Disconnecting"

            case .connected:
                return "Connected"

            case .connecting:
                return "Connecting"
            }
        }

        var color: RIColor {
            switch self {
            case .disconnected:
                return .gray

            case .disconnecting:
                return .orange

            case .connected:
                return .green

            case .connecting:
                return .orange
            }
        }
    }

    static let NameChangeNotification = Notification.Name("RIHub.nameChanged")
    static let TypeChangeNotification = Notification.Name("RIHub.typeChanged")
    static let StateChangeNotification = Notification.Name("RIHub.stateChanged")
    static let RSSIChangeNotification = Notification.Name("RIHub.rssiChanged")
    static let BatteryChangeNotification = Notification.Name("RIHub.batteryChanged")
    static let AttachedDevicesChangedNotification = Notification.Name("RIHub.attachedDevicesChanged")
    static let DeviceDataChangedNotification = Notification.Name("RIHub.deviceDataChanged")
    static let NoUsableProtocolNotification = Notification.Name("RIHub.noUsableProtocol")

    static let LEGOWirelessProtocolHubServiceUUID = CBUUID(string: LEGOWirelessProtocolHubServiceUUIDString)
    static let LEGOWirelessProtocolHubCharacteristicUUID = CBUUID(string: LEGOWirelessProtocolHubCharacteristicUUIDString)

    static let LEGOHubServiceUUID = CBUUID(string: LEGOHubServiceUUIDString)

    static let SPIKEPrimeServiceUUID = CBUUID(string: SPIKEPrimeServiceUUIDString)
    static let SPIKEPrimeRXCharacteristicUUID = CBUUID(string: SPIKEPrimeRXCharacteristicUUIDString)
    static let SPIKEPrimeTXCharacteristicUUID = CBUUID(string: SPIKEPrimeTXCharacteristicUUIDString)

    static let SerialServiceUUID = CBUUID(string: SerialServiceUUIDString)
    static let SerialCharacteristicUUID = CBUUID(string: SerialCharacteristicUUIDString)

    static let DeviceLostInterval = TimeInterval(10)
    static let BatteryChangeInterval = TimeInterval(120) // 2 minutes
    static let ConnectInterval = TimeInterval(10)
    static let RSSIReadInterval = TimeInterval(5)

    let transport: Transport

    // BLE properties (nil when using EA transport)
    private let centralManager: CBCentralManager?
    private let peripheral: CBPeripheral?
    let advertisementData: [String: Any]

    // EA properties (iOS only)
    #if os(iOS)
    private(set) var eaAccessory: EAAccessory?
    private var eaSession: EASession?
    private var eaProtocolString: String?
    private var eaReadBuffer = ""
    private var eaWriteBuffer = Data()
    /// Dedicated thread for EA RunLoop scheduling.
    private var eaThread: Thread?
    private var eaRunLoop: RunLoop?
    #endif

    var lastSeen: Date
    var rssi: Int {
        didSet {
            if rssi != oldValue {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.RSSIChangeNotification, object: self)
                }
            }
        }
    }

    /// Stored state — for BLE, updated from peripheral.state via broadcastStateChange().
    /// For EA, set directly by connect/disconnect methods.
    private(set) var state: State = .disconnected {
        didSet {
            if state != oldValue {
                #if DEBUG
                print("Hub \(deviceName): state \(oldValue.name) → \(state.name)")
                #endif
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.StateChangeNotification, object: self)
                }
            }
        }
    }

    var deviceName: String {
        #if os(iOS)
        if transport == .externalAccessory {
            return eaAccessory?.name ?? "SPIKE Hub (EA)"
        }
        #endif
        return peripheral?.name ?? "unknown"
    }
    var image: RIImage? {
        return nil
    }
    var largeImage: RIImage? {
        return nil
    }
    private var _eaIdentifier: UUID?
    var identifier: UUID {
        #if os(iOS)
        if transport == .externalAccessory {
            if let cached = _eaIdentifier { return cached }
            // Derive a stable UUID from the EA accessory's connection ID
            if let accessory = eaAccessory {
                let idString = "com.lego.ea.\(accessory.connectionID)"
                let bytes = Array(idString.utf8)
                var digest = [UInt8](repeating: 0, count: 16)
                for i in 0..<bytes.count {
                    digest[i % 16] ^= bytes[i]
                }
                let uuid = UUID(uuid: (digest[0], digest[1], digest[2], digest[3],
                                       digest[4], digest[5], digest[6], digest[7],
                                       digest[8], digest[9], digest[10], digest[11],
                                       digest[12], digest[13], digest[14], digest[15]))
                _eaIdentifier = uuid
                return uuid
            }
            return UUID()
        }
        #endif
        return peripheral?.identifier ?? UUID()
    }

    private var lastBatteryChange = Date.distantPast
    private var lastDroppedSamplesChange = Date.distantPast
    private var lastState = State.disconnected
    private var started: Date?
    private var connectDate = Date.distantPast
    private var rssiTimer: Timer?
    private var bleServicesProcessed = 0
    private var lwpCharacteristic: CBCharacteristic?
    private var spikeWriteCharacteristic: CBCharacteristic?   // FD02-0001 (writeNoResp)
    private var spikeNotifyCharacteristic: CBCharacteristic?  // FD02-0002 (notify)
    private(set) var spikeInfo: SPIKEInfoResponse?
    private(set) var usingSPIKEProtocol = false
    /// Attached devices: port ID → raw device type ID. (LWP3 or JSON telemetry)
    var attachedDevices: [UInt8: UInt16] = [:]
    /// LWP3 port value data: port ID → latest raw value bytes.
    private(set) var lwp3PortValues: [UInt8: Data] = [:]

    // SPIKE device state — updated from DeviceNotification (0x3C) or JSON telemetry.
    // Internal access needed by SPIKEJSONParser; guarded by dataLock.
    var spikeMotors: [UInt8: SPIKEDeviceNotification.Motor] = [:]
    var spikeDistances: [UInt8: SPIKEDeviceNotification.Distance] = [:]
    var spikeColors: [UInt8: SPIKEDeviceNotification.Color] = [:]
    var spikeForces: [UInt8: SPIKEDeviceNotification.Force] = [:]
    var spikeLightMatrices: [UInt8: SPIKEDeviceNotification.LightMatrix] = [:]

    /// Battery level as integer percentage (0–100), or nil if not yet received.
    var batteryLevel: Int? {
        batteryv > 0 ? Int(batteryv) : nil
    }

    /// Thread-safe snapshot of all current device data.
    func deviceDataSnapshot() -> DeviceDataSnapshot {
        dataLock.lock()
        defer { dataLock.unlock() }
        return DeviceDataSnapshot(
            motors: spikeMotors,
            distances: spikeDistances,
            colors: spikeColors,
            forces: spikeForces,
            lightMatrices: spikeLightMatrices,
            lwp3Devices: attachedDevices,
            lwp3PortValues: lwp3PortValues
        )
    }

    struct DeviceDataSnapshot {
        let motors: [UInt8: SPIKEDeviceNotification.Motor]
        let distances: [UInt8: SPIKEDeviceNotification.Distance]
        let colors: [UInt8: SPIKEDeviceNotification.Color]
        let forces: [UInt8: SPIKEDeviceNotification.Force]
        let lightMatrices: [UInt8: SPIKEDeviceNotification.LightMatrix]
        /// LWP3 attached devices: port ID → raw device type ID.
        let lwp3Devices: [UInt8: UInt16]
        /// LWP3 port value data: port ID → latest raw value bytes.
        let lwp3PortValues: [UInt8: Data]

        /// External ports with device data (SPIKE or LWP3).
        var activePorts: [UInt8] {
            let spikePorts = Set(motors.keys)
                .union(distances.keys)
                .union(colors.keys)
                .union(forces.keys)
                .union(lightMatrices.keys)
            // LWP3: include external ports (typically 0–5), skip hub-internal ports (≥50)
            let lwp3Ports = Set(lwp3Devices.keys.filter { $0 < 50 })
            return spikePorts.union(lwp3Ports).sorted()
        }
    }

    /// Convert port number to display name.
    static func portLetter(_ port: UInt8) -> String {
        guard port < 26, let scalar = UnicodeScalar(Int(port) + 65) else {
            return "Port(\(port))"
        }
        return String(Character(scalar))
    }
    private(set) var realSampleCount = 0
    var batteryv = Double(0) {
        didSet {
            let now = Date()
            if batteryv != oldValue && (oldValue == 0 || now.timeIntervalSince(lastBatteryChange) >= Self.BatteryChangeInterval) {
                lastBatteryChange = now
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.BatteryChangeNotification, object: self)
                }
            }
        }
    }
    private(set) var dataLock = NSLock()

    // MARK: - BLE Init

    init(centralManager: CBCentralManager, peripheral: CBPeripheral, advertisementData: [String : Any], rssi: Int) {
        self.transport = .ble
        self.centralManager = centralManager
        self.peripheral = peripheral
        self.advertisementData = advertisementData
        self.lastSeen = Date()
        self.rssi = rssi

        //print("advertisementData: \(advertisementData)")
    }

    // MARK: - ExternalAccessory Init (iOS only)

    #if os(iOS)
    init(accessory: EAAccessory, protocolString: String) {
        self.transport = .externalAccessory
        self.centralManager = nil
        self.peripheral = nil
        self.advertisementData = [:]
        self.lastSeen = Date()
        self.rssi = 0
        self.eaAccessory = accessory
        self.eaProtocolString = protocolString
    }
    #endif

    deinit {
        disconnect()
    }

    func connect() {
        guard state == .disconnected || state == .disconnecting else {
            #if DEBUG
            print("Hub \(deviceName): connect() skipped — state is \(state.name)")
            #endif
            return
        }

        #if DEBUG
        print("Hub \(deviceName): connect() initiated")
        #endif

        #if os(iOS)
        if transport == .externalAccessory {
            connectEA()
            return
        }
        #endif
        connectBLE()
    }

    func disconnect() {
        #if os(iOS)
        if transport == .externalAccessory {
            disconnectEA()
            return
        }
        #endif
        disconnectBLE()
    }

    // MARK: - BLE Connect/Disconnect

    private func disconnectBLE() {
        rssiTimer?.invalidate()
        rssiTimer = nil
        guard state == .connected || state == .connecting else { return }

        if let peripheral = peripheral, let centralManager = centralManager {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        lastSeen = Date()
        syncStateFromPeripheral()
    }

    /// Read current BLE peripheral state and update the stored state.
    func syncStateFromPeripheral() {
        guard transport == .ble, let peripheral = peripheral else { return }
        let newState: State
        switch peripheral.state {
        case .connected:     newState = .connected
        case .connecting:    newState = .connecting
        case .disconnected:  newState = .disconnected
        case .disconnecting: newState = .disconnecting
        @unknown default:    newState = .disconnected
        }
        state = newState
    }

    func broadcastStateChange() {
        assert(Thread.isMainThread)

        guard transport == .ble, let peripheral = peripheral else { return }

        let bleState: State
        switch peripheral.state {
        case .connected:     bleState = .connected
        case .connecting:    bleState = .connecting
        case .disconnected:  bleState = .disconnected
        case .disconnecting: bleState = .disconnecting
        @unknown default:    bleState = .disconnected
        }

        if bleState != lastState {
            if bleState == .connected {
                peripheral.discoverServices(nil)
            }
            lastState = bleState
            state = bleState  // triggers didSet → notification
        }
    }

    func isLost(_ now: Date) -> Bool {
        #if os(iOS)
        if transport == .externalAccessory {
            // EA hubs are either connected or removed — never "lost" from scanning
            return false
        }
        #endif
        guard let peripheral = peripheral else { return true }
        if peripheral.state == .connecting && Date().timeIntervalSince(connectDate) >= Self.ConnectInterval {
            #if DEBUG
            print("Hub \(deviceName): connect timeout after \(Self.ConnectInterval)s — disconnecting")
            #endif
            disconnect()
        }
        return peripheral.state == .disconnected && lastSeen.addingTimeInterval(Self.DeviceLostInterval) < now
    }

    private func resetConnection() {
        self.dataLock.lock()
        defer {
            self.dataLock.unlock()
        }

        lastSeen = Date()
        started = nil
        realSampleCount = 0
        batteryv = 0
        lastBatteryChange = Date.distantPast
        bleServicesProcessed = 0
        lwpCharacteristic = nil
        spikeWriteCharacteristic = nil
        spikeNotifyCharacteristic = nil
        spikeInfo = nil
        usingSPIKEProtocol = false
        attachedDevices.removeAll()
        lwp3PortValues.removeAll()
        spikeMotors.removeAll()
        spikeDistances.removeAll()
        spikeColors.removeAll()
        spikeForces.removeAll()
        spikeLightMatrices.removeAll()
        resetDevice()
    }

    func resetDevice() { // subclass responsibility
    }

    // MARK: - LWP3 Protocol

    /// Whether motor commands are available.
    var canControlMotors: Bool {
        #if os(iOS)
        if transport == .externalAccessory {
            return state == .connected
        }
        #endif
        return lwpCharacteristic != nil
    }

    /// Send an LWP3 command directly to the LWP3 characteristic (for motor control).
    /// For EA transport, translates to JSON scratch commands.
    func sendLWP3(_ command: Data) {
        #if os(iOS)
        if transport == .externalAccessory {
            // Translate LWP3 motor commands to JSON scratch commands
            translateLWP3ToEA(command)
            return
        }
        #endif
        guard let characteristic = lwpCharacteristic, let peripheral = peripheral else {
            #if DEBUG
            print("LWP3: Cannot send — no LWP characteristic (motor control unavailable)")
            #endif
            return
        }
        peripheral.writeValue(command, for: characteristic, type: .withResponse)
    }

    func send(_ command: Data) {
        #if os(iOS)
        if transport == .externalAccessory {
            return  // EA uses JSON protocol, not binary commands
        }
        #endif
        if usingSPIKEProtocol {
            sendSPIKE(command)
            return
        }
        guard let characteristic = lwpCharacteristic, let peripheral = peripheral else {
            #if DEBUG
            print("LWP3: Cannot send — no LWP characteristic")
            #endif
            return
        }
        peripheral.writeValue(command, for: characteristic, type: .withResponse)
    }

    // MARK: - SPIKE Prime Protocol

    /// Send a raw SPIKE Prime message (will be COBS-encoded and framed).
    func sendSPIKE(_ message: Data) {
        guard let writeChar = spikeWriteCharacteristic, let peripheral = peripheral else {
            #if DEBUG
            print("SPIKE: Cannot send — no write characteristic")
            #endif
            return
        }

        let frame = SPIKECOBS.pack(message)

        #if DEBUG
        print("SPIKE TX: \(message.hexEncodedString()) → framed \(frame.count) bytes")
        #endif

        // Respect max packet size from InfoResponse
        let packetSize = Int(spikeInfo?.maxPacketSize ?? UInt16(frame.count))
        var offset = 0
        while offset < frame.count {
            let end = min(offset + packetSize, frame.count)
            let packet = frame[offset..<end]
            peripheral.writeValue(Data(packet), for: writeChar, type: .withoutResponse)
            offset = end
        }
    }

    /// Handle an incoming COBS-framed notification from the SPIKE hub.
    private func handleSPIKENotification(_ data: Data) {
        // Frame must end with 0x02
        guard !data.isEmpty, data.last == 0x02 else {
            #if DEBUG
            print("SPIKE RX: incomplete frame (\(data.count) bytes)")
            #endif
            return
        }

        let decoded = SPIKECOBS.unpack(data)
        guard !decoded.isEmpty else {
            #if DEBUG
            print("SPIKE RX: empty after COBS decode")
            #endif
            return
        }

        let msgType = decoded[0]

        #if DEBUG
        print("SPIKE RX: type=0x\(String(format: "%02X", msgType)) (\(decoded.count) bytes): \(decoded.hexEncodedString())")
        #endif

        switch msgType {
        case 0x01: // InfoResponse
            if let info = SPIKEInfoResponse.parse(from: decoded) {
                spikeInfo = info
                #if DEBUG
                print("SPIKE: InfoResponse — FW \(info.firmwareMajor).\(info.firmwareMinor).\(info.firmwareBuild), maxPacket=\(info.maxPacketSize), maxChunk=\(info.maxChunkSize)")
                #endif
                // Now request device notifications (battery, motors, etc.)
                sendSPIKE(SPIKECommand.deviceNotificationRequest(intervalMS: 5000))
            }

        case 0x29: // DeviceNotificationResponse
            if decoded.count >= 2 {
                let success = decoded[1] == 0x00
                #if DEBUG
                print("SPIKE: DeviceNotificationResponse — success=\(success)")
                #endif
            }

        case 0x3C: // DeviceNotification
            if let notification = SPIKEDeviceNotification.parse(from: decoded) {
                if let battery = notification.battery {
                    batteryv = Double(battery.level)
                }
                // Each notification is a complete snapshot — replace all device state
                dataLock.lock()
                spikeMotors.removeAll()
                spikeDistances.removeAll()
                spikeColors.removeAll()
                spikeForces.removeAll()
                spikeLightMatrices.removeAll()
                for motor in notification.motors {
                    spikeMotors[motor.port] = motor
                }
                for dist in notification.distances {
                    spikeDistances[dist.port] = dist
                }
                for color in notification.colors {
                    spikeColors[color.port] = color
                }
                for force in notification.forces {
                    spikeForces[force.port] = force
                }
                for light in notification.lightMatrices {
                    spikeLightMatrices[light.port] = light
                }
                dataLock.unlock()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.DeviceDataChangedNotification, object: self)
                }
                #if DEBUG
                if let battery = notification.battery {
                    print("SPIKE: Battery=\(battery.level)%")
                }
                for motor in notification.motors {
                    print("SPIKE: Motor port=\(motor.port) type=\(motor.deviceType) speed=\(motor.speed) pos=\(motor.position)")
                }
                for dist in notification.distances {
                    print("SPIKE: Distance port=\(dist.port) distance=\(dist.distanceMM)mm")
                }
                for color in notification.colors {
                    print("SPIKE: Color port=\(color.port) id=\(color.colorID) rgb=(\(color.red),\(color.green),\(color.blue))")
                }
                for force in notification.forces {
                    print("SPIKE: Force port=\(force.port) force=\(force.force) pressed=\(force.pressed)")
                }
                for light in notification.lightMatrices {
                    print("SPIKE: Light port=\(light.port) pixels=\(light.pixels)")
                }
                print("SPIKE: Summary — motors=\(notification.motors.count) dist=\(notification.distances.count) color=\(notification.colors.count) force=\(notification.forces.count) light=\(notification.lightMatrices.count) battery=\(notification.battery != nil)")
                #endif
            }

        case 0x21: // ConsoleNotification
            if decoded.count > 1 {
                let textData = decoded[1...]
                if let text = String(data: textData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) {
                    print("SPIKE Console: \(text)")
                }
            }

        case 0x20: // ProgramFlowNotification
            if decoded.count >= 2 {
                let stopped = decoded[1] != 0
                #if DEBUG
                print("SPIKE: ProgramFlow — stopped=\(stopped)")
                #endif
            }

        default:
            #if DEBUG
            print("SPIKE RX: unhandled message type 0x\(String(format: "%02X", msgType))")
            #endif
        }
    }

    private func handleLWP3Message(_ data: Data) {
        guard let message = LWP3Message.parse(from: data) else {
            #if DEBUG
            print("LWP3: Failed to parse: \(data.hexEncodedString())")
            #endif
            return
        }

        #if DEBUG
        print("LWP3: \(message)")
        #endif

        switch message {
        case .hubAttachedIO(let portID, let event, _, let deviceTypeRaw, _, _, _, _):
            switch event {
            case .attached, .attachedVirtual:
                attachedDevices[portID] = deviceTypeRaw
                lwp3PortValues.removeValue(forKey: portID)
                // Subscribe to mode 0 value notifications for external ports
                if portID < 50 {
                    send(LWP3Command.setPortInputFormat(portID: portID, mode: 0,
                                                        deltaInterval: 1,
                                                        notificationEnabled: true))
                }
            case .detached:
                attachedDevices.removeValue(forKey: portID)
                lwp3PortValues.removeValue(forKey: portID)
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.AttachedDevicesChangedNotification, object: self)
            }

        case .portValueSingle(let portID, let value):
            dataLock.lock()
            lwp3PortValues[portID] = value
            dataLock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.DeviceDataChangedNotification, object: self)
            }

        case .hubProperty(let property, let operation, let payload):
            if property == .batteryVoltage && operation == .update {
                if let level = payload.first {
                    batteryv = Double(level)
                }
            }

        default:
            break
        }
    }

    private func connectBLE() {
        guard let peripheral = peripheral, let centralManager = centralManager else { return }
        rssiTimer = Timer.scheduledTimer(withTimeInterval: Self.RSSIReadInterval,
                                         repeats: true,
                                         block: { [weak self] (_) in
            if self?.state == .connected {
                self?.peripheral?.readRSSI()
            }
        })
        peripheral.delegate = self
        resetConnection()
        connectDate = Date()
        centralManager.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey:1])
        broadcastStateChange()
    }

    private func noteThisHub() {
        //  Update the list of device UUIDs for ehich we've added a type
        if let knownDeviceUUIDs = UserDefaults.standard.object(forKey: "EEGHeadband.uuids") as? [String] {
            if !knownDeviceUUIDs.contains(identifier.uuidString) {
                var deviceUUIDs = Array<String>(knownDeviceUUIDs)

                deviceUUIDs.append(identifier.uuidString)
                UserDefaults.standard.set(deviceUUIDs, forKey: "EEGHeadband.uuids")
            }
        }
        else {
            let deviceUUIDs = [identifier.uuidString]

            UserDefaults.standard.set(deviceUUIDs, forKey: "EEGHeadband.uuids")
        }
    }

    // MARK: - BLE Property Helpers

    private static func propertyNames(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.broadcast)            { names.append("broadcast") }
        if properties.contains(.read)                 { names.append("read") }
        if properties.contains(.writeWithoutResponse)  { names.append("writeNoResp") }
        if properties.contains(.write)                { names.append("write") }
        if properties.contains(.notify)               { names.append("notify") }
        if properties.contains(.indicate)             { names.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { names.append("authWrite") }
        if properties.contains(.extendedProperties)   { names.append("extended") }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    //  MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("Service discovery error: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else { return }

        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.NameChangeNotification, object: self)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        rssi = RSSI.intValue
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("Characteristic discovery error for \(service.uuid): \(error.localizedDescription)")
            return
        }

        guard let chars = service.characteristics else { return }

        for c in chars {
            // Subscribe to any notify/indicate characteristic
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
        }

        // Set up protocol based on service type
        if service.uuid == Self.SPIKEPrimeServiceUUID {
            // SPIKE Prime protocol — separate write and notify characteristics
            if let rxChar = chars.first(where: { $0.uuid == Self.SPIKEPrimeRXCharacteristicUUID }) {
                spikeWriteCharacteristic = rxChar
            }
            if let txChar = chars.first(where: { $0.uuid == Self.SPIKEPrimeTXCharacteristicUUID }) {
                spikeNotifyCharacteristic = txChar
            }

            if spikeWriteCharacteristic != nil && spikeNotifyCharacteristic != nil {
                usingSPIKEProtocol = true
                #if DEBUG
                print("SPIKE: Protocol active — sending InfoRequest")
                #endif
                sendSPIKE(SPIKECommand.infoRequest())
            }
        } else if service.uuid == Self.LEGOWirelessProtocolHubServiceUUID {
            // Standard LWP3 protocol
            if let hub = chars.first(where: { $0.uuid == Self.LEGOWirelessProtocolHubCharacteristicUUID }) {
                setupLWPCharacteristic(hub)
            }
        }

        bleServicesProcessed += 1

        #if DEBUG
        let services = peripheral.services?.map { $0.uuid.uuidString } ?? []
        print("Services discovered: \(services) | SPIKE=\(usingSPIKEProtocol) LWP3=\(lwpCharacteristic != nil) motorControl=\(canControlMotors) [\(bleServicesProcessed)/\(peripheral.services?.count ?? 0)]")
        #endif

        // Check if all services have been processed
        if bleServicesProcessed >= (peripheral.services?.count ?? 0),
           !usingSPIKEProtocol, lwpCharacteristic == nil {
            #if DEBUG
            print("BLE: No usable protocol found after discovering all services")
            #endif
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.NoUsableProtocolNotification, object: self)
            }
        }
    }

    private func setupLWPCharacteristic(_ characteristic: CBCharacteristic) {
        lwpCharacteristic = characteristic

        send(LWP3Command.requestHubProperty(.batteryVoltage))
        send(LWP3Command.enableHubPropertyUpdates(.batteryVoltage))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Notify failed for \(characteristic.uuid): \(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?) {
        if let included = service.includedServices {
            for inc in included {
                peripheral.discoverCharacteristics(nil, for: inc)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        #if DEBUG
        if let error = error {
            print("Write error for \(characteristic.uuid): \(error.localizedDescription)")
        }
        #endif
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }

        // Forward to appropriate protocol handler
        if usingSPIKEProtocol && characteristic === spikeNotifyCharacteristic {
            handleSPIKENotification(data)
        } else if characteristic === lwpCharacteristic {
            handleLWP3Message(data)
        }
    }

    //  Mark: - Equitable

    static func == (lhs: RIHub, rhs: RIHub) -> Bool {
        return lhs.identifier == rhs.identifier
    }

    // MARK: - ExternalAccessory Session Management (iOS only)

    #if os(iOS)

    private func connectEA() {
        guard transport == .externalAccessory,
              let accessory = eaAccessory,
              let proto = eaProtocolString else { return }

        resetConnection()
        state = .connecting

        // Create EA session
        guard let session = EASession(accessory: accessory, forProtocol: proto) else {
            #if DEBUG
            print("EA: Failed to create session for \(accessory.name) protocol \(proto)")
            #endif
            state = .disconnected
            return
        }

        eaSession = session

        // Start a dedicated thread for stream scheduling
        let thread = Thread { [weak self] in
            guard let self = self, let session = self.eaSession else { return }

            let runLoop = RunLoop.current
            self.eaRunLoop = runLoop

            session.inputStream?.delegate = self
            session.inputStream?.schedule(in: runLoop, forMode: .default)
            session.inputStream?.open()

            session.outputStream?.delegate = self
            session.outputStream?.schedule(in: runLoop, forMode: .default)
            session.outputStream?.open()

            // Keep the RunLoop alive
            while !Thread.current.isCancelled {
                runLoop.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            }
        }
        thread.name = "EA-\(accessory.name)"
        thread.qualityOfService = .userInitiated
        eaThread = thread
        thread.start()

        state = .connected

        #if DEBUG
        print("EA: Connected to \(accessory.name) via \(proto)")
        #endif
    }

    private func disconnectEA() {
        guard transport == .externalAccessory else { return }

        eaThread?.cancel()
        eaThread = nil
        eaRunLoop = nil

        if let session = eaSession {
            session.inputStream?.close()
            session.inputStream?.remove(from: .current, forMode: .default)
            session.inputStream?.delegate = nil

            session.outputStream?.close()
            session.outputStream?.remove(from: .current, forMode: .default)
            session.outputStream?.delegate = nil
        }
        eaSession = nil
        eaReadBuffer = ""
        eaWriteBuffer = Data()

        state = .disconnected

        #if DEBUG
        print("EA: Disconnected from \(eaAccessory?.name ?? "?")")
        #endif
    }

    /// Send a JSON command string over the EA session.
    /// Safe to call from any thread — dispatches the write to the EA stream thread.
    func sendEACommand(_ jsonString: String) {
        guard transport == .externalAccessory,
              let data = (jsonString + "\r").data(using: .utf8),
              let thread = eaThread, !thread.isCancelled else { return }

        #if DEBUG
        print("EA TX: \(jsonString)")
        #endif

        // Dispatch to the EA thread where streams are scheduled
        perform(#selector(eaEnqueueAndFlush(_:)), on: thread, with: data, waitUntilDone: false)
    }

    @objc private func eaEnqueueAndFlush(_ data: Data) {
        eaWriteBuffer.append(data)
        flushEAWriteBuffer()
    }

    private func flushEAWriteBuffer() {
        guard let outputStream = eaSession?.outputStream,
              outputStream.hasSpaceAvailable,
              !eaWriteBuffer.isEmpty else { return }

        let bytesWritten = eaWriteBuffer.withUnsafeBytes { ptr -> Int in
            guard let baseAddress = ptr.baseAddress else { return 0 }
            return outputStream.write(baseAddress.assumingMemoryBound(to: UInt8.self),
                                      maxLength: eaWriteBuffer.count)
        }

        if bytesWritten > 0 {
            eaWriteBuffer.removeFirst(bytesWritten)
        }
    }

    private func readEAData() {
        guard let inputStream = eaSession?.inputStream else { return }

        var buffer = [UInt8](repeating: 0, count: 4096)
        while inputStream.hasBytesAvailable {
            let bytesRead = inputStream.read(&buffer, maxLength: buffer.count)
            guard bytesRead > 0 else { break }

            if let chunk = String(bytes: buffer[0..<bytesRead], encoding: .utf8) {
                eaReadBuffer += chunk
                processEALines()
            }
        }
    }

    /// Split accumulated buffer on newlines and parse each complete JSON line.
    private func processEALines() {
        while let newlineRange = eaReadBuffer.range(of: "\r") ?? eaReadBuffer.range(of: "\n") {
            let line = String(eaReadBuffer[eaReadBuffer.startIndex..<newlineRange.lowerBound])
            eaReadBuffer = String(eaReadBuffer[newlineRange.upperBound...])

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            handleEAJSONLine(trimmed)
        }
    }

    /// Parse a single JSON line from the EA stream and update device state.
    private func handleEAJSONLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let m = json["m"] as? Int,
              let p = json["p"] as? [Any] else {
            #if DEBUG
            print("EA RX: unparseable line: \(line.prefix(120))")
            #endif
            return
        }

        switch m {
        case 0:
            SPIKEJSONParser.parseDeviceTelemetry(p, into: self)
        case 2:
            SPIKEJSONParser.parseBattery(p, into: self)
        default:
            #if DEBUG
            print("EA RX: unhandled m=\(m)")
            #endif
        }
    }

    // MARK: - EA Motor Command Translation

    /// Translate an LWP3 binary motor command into a JSON scratch command for EA transport.
    private func translateLWP3ToEA(_ command: Data) {
        // LWP3 port output command: [length, hubID, 0x81, portID, startup, subCmd, ...]
        // Find the port output command payload
        guard command.count >= 4 else { return }

        let headerSize: Int
        if command[0] & 0x80 != 0 {
            headerSize = 4  // 2-byte length
        } else {
            headerSize = 3  // 1-byte length
        }

        guard command.count > headerSize else { return }
        let messageType = command[headerSize - 1]
        guard messageType == 0x81 else { return }  // port output command

        let payloadStart = headerSize
        guard command.count > payloadStart + 2 else { return }
        let portID = command[payloadStart]
        // startup+completion at payloadStart+1
        let subCommand = command[payloadStart + 2]

        switch subCommand {
        case 0x01: // startPower (raw PWM — works for motors, lights, and other devices)
            guard command.count > payloadStart + 3 else { return }
            let power = Int8(bitPattern: command[payloadStart + 3])
            sendPWMCommandEA(port: portID, power: Int(power))

        case 0x07: // startSpeed (PID-controlled — motors only)
            guard command.count > payloadStart + 3 else { return }
            let speed = Int8(bitPattern: command[payloadStart + 3])
            sendMotorCommandEA(port: portID, speed: Int(speed))

        default:
            #if DEBUG
            print("EA: Unsupported LWP3 subcommand 0x\(String(format: "%02X", subCommand))")
            #endif
        }
    }

    /// Send a raw PWM power command (works for motors, lights, and other devices).
    private func sendPWMCommandEA(port: UInt8, power: Int) {
        let msgID = UUID().uuidString
        let portLetter = Self.portLetter(port)
        if power == 0 {
            let cmd = "{\"i\":\"\(msgID)\",\"m\":\"scratch.motor_stop\",\"p\":{\"port\":\"\(portLetter)\",\"stop\":1}}"
            sendEACommand(cmd)
        } else {
            let clampedPower = max(-100, min(100, power))
            let cmd = "{\"i\":\"\(msgID)\",\"m\":\"scratch.motor_pwm\",\"p\":{\"port\":\"\(portLetter)\",\"power\":\(clampedPower),\"stall\":false}}"
            sendEACommand(cmd)
        }
    }

    /// Send a PID-controlled speed command (motors only).
    private func sendMotorCommandEA(port: UInt8, speed: Int) {
        let msgID = UUID().uuidString
        let portLetter = Self.portLetter(port)
        if speed == 0 {
            let cmd = "{\"i\":\"\(msgID)\",\"m\":\"scratch.motor_stop\",\"p\":{\"port\":\"\(portLetter)\",\"stop\":1}}"
            sendEACommand(cmd)
        } else {
            let clampedSpeed = max(-100, min(100, speed))
            let cmd = "{\"i\":\"\(msgID)\",\"m\":\"scratch.motor_start\",\"p\":{\"port\":\"\(portLetter)\",\"speed\":\(clampedSpeed),\"stall\":true}}"
            sendEACommand(cmd)
        }
    }

    #endif  // os(iOS)
}

// MARK: - StreamDelegate (EA)

#if os(iOS)
extension RIHub: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            readEAData()

        case .hasSpaceAvailable:
            flushEAWriteBuffer()

        case .errorOccurred:
            #if DEBUG
            print("EA: Stream error — \(aStream.streamError?.localizedDescription ?? "unknown")")
            #endif
            disconnectEA()

        case .endEncountered:
            #if DEBUG
            print("EA: Stream ended")
            #endif
            disconnectEA()

        default:
            break
        }
    }
}
#endif

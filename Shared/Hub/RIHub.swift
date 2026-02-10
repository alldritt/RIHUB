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

    let centralManager: CBCentralManager
    let peripheral: CBPeripheral
    let advertisementData: [String: Any]
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
    
    var state: State {
        switch peripheral.state {
        case .connected:
            return .connected
            
        case .connecting:
            return .connecting
            
        case .disconnected:
            return .disconnected
            
        case .disconnecting:
            return .disconnecting
            
        @unknown default:
            fatalError()
        }
    }
    var deviceName: String {
        return peripheral.name ?? "unknown"
    }
    var image: RIImage? {
        return nil
    }
    var largeImage: RIImage? {
        return nil
    }
    var identifier: UUID {
        return peripheral.identifier
    }

    private var lastBatteryChange = Date.distantPast
    private var lastDroppedSamplesChange = Date.distantPast
    private var lastState = State.disconnected
    private var started: Date?
    private var connectDate = Date.distantPast
    private var rssiTimer: Timer?
    private var lwpCharacteristic: CBCharacteristic?
    private var spikeWriteCharacteristic: CBCharacteristic?   // FD02-0001 (writeNoResp)
    private var spikeNotifyCharacteristic: CBCharacteristic?  // FD02-0002 (notify)
    private(set) var spikeInfo: SPIKEInfoResponse?
    private(set) var usingSPIKEProtocol = false
    private(set) var attachedDevices: [UInt8: LWP3IODeviceType] = [:]
    private(set) var realSampleCount = 0
    private(set) var batteryv = Double(0) {
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

    init(centralManager: CBCentralManager, peripheral: CBPeripheral, advertisementData: [String : Any], rssi: Int) {
        self.centralManager = centralManager
        self.peripheral = peripheral
        self.advertisementData = advertisementData
        self.lastSeen = Date()
        self.rssi = rssi
        
        //print("advertisementData: \(advertisementData)")
    }
    
    deinit {
        disconnect()
    }
    
    func connect() {
        guard state == .disconnected || state == .disconnecting else { return }
        
        connectPart2()
    }

    func disconnect() {
        rssiTimer?.invalidate()
        rssiTimer = nil
        guard state == .connected || state == .connecting else { return }
        
        centralManager.cancelPeripheralConnection(peripheral)
        lastSeen = Date()
        broadcastStateChange()
    }
        
    func broadcastStateChange() {
        assert(Thread.isMainThread)
        
        if state != lastState {
            if state == .connected {
                peripheral.discoverServices(nil)
            }
            //print("broadcastStateChange: \(peripheral)")
            lastState = state
            NotificationCenter.default.post(name: Self.StateChangeNotification, object: self)
        }
    }
    
    func isLost(_ now: Date) -> Bool {
        if peripheral.state == .connecting && Date().timeIntervalSince(connectDate) >= Self.ConnectInterval {
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
        lwpCharacteristic = nil
        spikeWriteCharacteristic = nil
        spikeNotifyCharacteristic = nil
        spikeInfo = nil
        usingSPIKEProtocol = false
        attachedDevices.removeAll()
        resetDevice()
    }
    
    func resetDevice() { // subclass responsibility
    }

    // MARK: - LWP3 Protocol

    func send(_ command: Data) {
        if usingSPIKEProtocol {
            sendSPIKE(command)
            return
        }
        guard let characteristic = lwpCharacteristic else {
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
        guard let writeChar = spikeWriteCharacteristic else {
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

    // MARK: - BLE REPL Experiment

    /// Write raw bytes to the first writable characteristic (for REPL probing).
    func writeRaw(_ data: Data) {
        guard let service = peripheral.services?.first,
              let char = service.characteristics?.first(where: {
                  $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
              }) else {
            print("BLE REPL: No writable characteristic")
            return
        }
        let type: CBCharacteristicWriteType = char.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: char, type: type)
        print("BLE REPL: Wrote \(data.count) bytes: \(data.hexEncodedString())")
    }

    /// Send a string as UTF-8 + carriage return to the REPL characteristic.
    func writeREPL(_ command: String) {
        guard let data = (command + "\r").data(using: .utf8) else { return }
        writeRaw(data)
    }

    /// Probe the hub REPL: send Ctrl+C, then a command to show "HI" on the LED matrix.
    /// If the hub's display changes, we know we're talking to MicroPython.
    func probeREPL() {
        print("BLE REPL: ── Probing hub REPL ──")

        // Ctrl+C to break any running program
        writeRaw(Data([0x03]))

        // Small delay then try to show something on the display
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.writeREPL("import hub; hub.display.show('HI')")
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
        case .hubAttachedIO(let portID, let event, let deviceType, _, _, _, _):
            switch event {
            case .attached, .attachedVirtual:
                if let deviceType = deviceType {
                    attachedDevices[portID] = deviceType
                }
            case .detached:
                attachedDevices.removeValue(forKey: portID)
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.AttachedDevicesChangedNotification, object: self)
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
    
    private func connectPart2() {
        rssiTimer = Timer.scheduledTimer(withTimeInterval: Self.RSSIReadInterval,
                                         repeats: true,
                                         block: { [weak self] (_) in
            if self?.state == .connected {
                self?.peripheral.readRSSI()
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
}



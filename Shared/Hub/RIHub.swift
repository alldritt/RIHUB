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
typealias RIImage = NSIMage
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

    static let LEGOWirelessProtocolHubServiceUUID = CBUUID(string: LEGOWirelessProtocolHubServiceUUIDString)
    static let LEGOWirelessProtocolHubCharacteristicUUID = CBUUID(string: LEGOWirelessProtocolHubCharacteristicUUIDString)

    static let LEGOHubServiceUUID = CBUUID(string: LEGOHubServiceUUIDString)
    
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
    private (set) var realSampleCount = 0
    private (set) var batteryv = Double(0) {
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
    private (set) var dataLock = NSLock()

    init(centralManager: CBCentralManager, peripheral: CBPeripheral, advertisementData: [String : Any], rssi: Int) {
        self.centralManager = centralManager
        self.peripheral = peripheral
        self.advertisementData = advertisementData
        self.lastSeen = Date()
        self.rssi = rssi
        
        print("advertisementData: \(advertisementData)")
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
                peripheral.discoverServices([/* Self.MUSEServiceUUID */])
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
        resetDevice()
    }
    
    func resetDevice() { // subclass responsibility
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
    
    //  MARK: - CBPeripheralDelegate
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        #if DEBUG
        print("didDiscoverServices: \(String(describing: peripheral.services))")
        #endif
        
        if let legoWPHubService = peripheral.services?.first(where: { (service) -> Bool in
            return service.uuid == Self.LEGOWirelessProtocolHubServiceUUID
        }) {
            peripheral.discoverCharacteristics([Self.LEGOWirelessProtocolHubCharacteristicUUID], for: legoWPHubService)
        }
        if let serialService = peripheral.services?.first(where: { (service) -> Bool in
            return service.uuid == Self.LEGOHubServiceUUID
        }) {
            peripheral.discoverCharacteristics([Self.SerialCharacteristicUUID], for: serialService)
        }
    }
        
    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        #if DEBUG
        print("peripheralDidUpdateName: \(String(describing: peripheral.name))")
        #endif

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.NameChangeNotification, object: self)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        #if DEBUG
        print("didReadRSSI: \(RSSI)")
        #endif
        rssi = RSSI.intValue
    }
        
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        #if DEBUG
        print("didDiscoverCharacteristicsFor: \(service), \(String(describing: service.characteristics))")
        #endif
        
        if let hub = service.characteristics?.first(where: { (characteristic) -> Bool in
            return characteristic.uuid == Self.LEGOWirelessProtocolHubCharacteristicUUID
        }) {
            peripheral.setNotifyValue(true, for: hub)
        }
        if let serial = service.characteristics?.first(where: { (characteristic) -> Bool in
            return characteristic.uuid == Self.SerialCharacteristicUUID
        }) {
            peripheral.setNotifyValue(true, for: serial)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?) {
        #if DEBUG
        print("didDiscoverIncludedServicesFor: \(service)")
        #endif
    }
        
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        #if DEBUG
        print("didWriteValueFor: \(characteristic), error: \(String(describing: error))")
        #endif
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        #if DEBUG
        print("didUpdateValueFor: \(characteristic), error: \(String(describing: error))")
        #endif
        
        switch characteristic.uuid {
        case Self.LEGOWirelessProtocolHubCharacteristicUUID:
            if let data = characteristic.value {
                print(data.hexEncodedString())
            }
            
        case Self.SerialCharacteristicUUID:
            if let data = characteristic.value {
                print(data.hexEncodedString())
            }
            
        default:
            print("unknown characteristic...")
        }
    }
    
    //  Mark: - Equitable

    static func == (lhs: RIHub, rhs: RIHub) -> Bool {
        return lhs.identifier == rhs.identifier
    }
}



//
//  RIHubManager.swift
//  RobotInventorHUB
//
//  Created by Mark Alldritt on 2020-03-17.
//  Copyright © 2020 Mark Alldritt. All rights reserved.
//

#if os(iOS)
import UIKit
#endif
import CoreBluetooth


class RIHubManager: NSObject {
    
    //static let LEGOHubServiceUUIDString = "FEED"
    //static let LEGOHubServiceUUID = CBUUID(string: LEGOHubServiceUUIDString)

    static let DevicesChangedNotification = Notification.Name("RIHubManager.DevicesChangedNotification")
    static let BluetoothStateChangedNotification = Notification.Name("RIHubManager.BluetoothStateChangedNotification")
    
    private(set) var isRunning = false
    private(set) var devices: [UUID:RIHub] = [:] {
        didSet {
            if devices != oldValue {
                NotificationCenter.default.post(name: Self.DevicesChangedNotification, object: self)
            }
        }
    }
    var uuids: [UUID] {
        return devices.keys.sorted { (v1, v2) -> Bool in
            return v1.uuidString < v2.uuidString
        }
    }
    var hubs: [RIHub] {
        return uuids.map { (uuid) in return self.devices[uuid]! }
    }
    var state: CBManagerState {
        return centralManager?.state ?? .unknown
    }
    
    private let queue = DispatchQueue(label: "LEGO")
    private var centralManager: CBCentralManager!
    private var timer: Timer?
    
    static let shared = RIHubManager()
    
    override private init() {}
    
    deinit {
        stop()
    }
    
    func start() {
        guard !isRunning else { return }
        
        isRunning = true
        devices = devices.filter({ (arg0) -> Bool in
            let (_, hub) = arg0
            
            return hub.state == .connected
        })

        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: queue)
        }
        else {
            centralManagerDidUpdateState(centralManager)
        }
    }
    
    func stop() {
        guard isRunning else { return }
        
        isRunning = false
        devices = devices.filter({ (arg0) -> Bool in
            let (_, hub) = arg0
            
            return hub.state == .connected
        })
        
        timer?.invalidate()
        timer = nil
        centralManager.stopScan()
    }
    
    private func timerFired(_ timer: Timer) {
        assert(Thread.isMainThread)
        
        let now = Date()
        self.devices = self.devices.filter({ (arg0) -> Bool in
            let (_, hub) = arg0
            
            return !hub.isLost(now)
        })
    }
}


extension RIHubManager: CBCentralManagerDelegate {
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .unknown:
            print("central.state is .unknown")
            break

        case .resetting:
            print("central.state is .resetting")
            break

        case .unsupported:
            print("central.state is .unsupported")
            break
        
        case .unauthorized:
            print("central.state is .unauthorized")
            break

        case .poweredOff:
            print("central.state is .poweredOff")
            if isRunning {
                print("  - no longer listening for devices")
                centralManager.stopScan()
                DispatchQueue.main.async {
                    self.timer?.invalidate()
                    self.timer = nil
                    self.hubs.forEach { (hub) in
                        hub.disconnect()
                    }
                    self.devices.removeAll()
                }
            }
            break

        case .poweredOn:
            print("central.state is .poweredOn")
            if isRunning {
                print("  - listening for devices...")
                centralManager.scanForPeripherals(withServices: [RIHub.LEGOHubServiceUUID,
                                                                 RIHub.LEGOWirelessProtocolHubServiceUUID,
                                                                 RIHub.SerialServiceUUID],
                                                  options: [CBCentralManagerScanOptionAllowDuplicatesKey:1])
                DispatchQueue.main.async {
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true, block: self.timerFired)
                }
            }
            break

        @unknown default:
            fatalError()
        }
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.BluetoothStateChangedNotification, object: self)
        }
    }
    
    static var uuids: Set<UUID> = []
    static var lastuuids: Set<UUID> = []

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        Self.uuids.insert(peripheral.identifier)
        
        //if Self.uuids != Self.lastuuids {
        //    print("uuids: \(Self.uuids)")
            print("didDiscover: \(peripheral), advertisementData: \(advertisementData), rssi: \(RSSI), when: \(Date())")
        //    Self.lastuuids = Self.uuids
        //}
                
        DispatchQueue.main.async {
            //print("advertisementData: \(peripheral.name ?? "unknown") - \(advertisementData) - \(advertisementData["kCBAdvDataServiceUUIDs"] as? [CBUUID])")
            /*
            if let data = advertisementData["kCBAdvDataManufacturerData"] as? Data {
                print("kCBAdvDataManufacturerData: \(data.hexEncodedString())")
            }
            */
            
            if let hub = self.devices[peripheral.identifier] {
                hub.lastSeen = Date()
                hub.rssi = RSSI.intValue
                hub.broadcastStateChange()
            }
            else {
                print("didDiscover: \(peripheral), advertisementData: \(advertisementData), rssi: \(RSSI), when: \(Date())")
                
                self.devices[peripheral.identifier] = RIHub(centralManager: self.centralManager,
                                                            peripheral: peripheral,
                                                            advertisementData: advertisementData,
                                                            rssi: RSSI.intValue)

                /*
                if peripheral.name?.contains("LEGO") == true ||
                    (advertisementData["kCBAdvDataLocalName"] as? String)?.contains("LEGO") == true {
                    print("found it!")
                }
                if let serviceUUIDs = advertisementData["kCBAdvDataServiceUUIDs"] as? [CBUUID],
                    serviceUUIDs.contains(Self.LEGOHubServiceUUID) {
                    
                }
                */
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("didConnect: \(peripheral)")
        
        DispatchQueue.main.async {
            guard let hub = self.devices[peripheral.identifier] else { return }
            
            hub.lastSeen = Date()
            hub.broadcastStateChange()
        }
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("didFailToConnect: \(peripheral), error: \(String(describing: error))")

        DispatchQueue.main.async {
            guard let hub = self.devices[peripheral.identifier] else { return }
            
            hub.lastSeen = Date()
            hub.broadcastStateChange()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("didDisconnectPeripheral: \(peripheral), error: \(String(describing: error))")

        DispatchQueue.main.async {
            guard let hub = self.devices[peripheral.identifier] else { return }
            
            hub.lastSeen = Date()
            hub.broadcastStateChange()
        }
    }
}

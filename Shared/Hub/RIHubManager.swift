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

    /// LEGO's Bluetooth SIG company identifier (0x0397 = 919).
    static let legoCompanyID: UInt16 = 0x0397

    /// Service UUIDs that identify LEGO hubs.
    static let legoServiceUUIDs: Set<CBUUID> = [
        RIHub.LEGOWirelessProtocolHubServiceUUID,   // LWP3 (Technic Hub, City Hub, etc.)
        RIHub.LEGOHubServiceUUID,                    // Legacy LEGO hub service (0xFEED)
        RIHub.SPIKEPrimeServiceUUID                  // SPIKE Prime / Robot Inventor (0xFD02)
    ]

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

    // MARK: - LEGO Hub Identification

    /// Check whether a peripheral looks like a LEGO hub based on its advertisement.
    /// Matches on: advertised service UUIDs, LEGO manufacturer data, or device name.
    private static func isLEGOHub(peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        // Check advertised service UUIDs
        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           serviceUUIDs.contains(where: { legoServiceUUIDs.contains($0) }) {
            return true
        }

        // Check LEGO manufacturer data (company ID 0x0397 in first 2 bytes, little-endian)
        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           mfgData.count >= 2 {
            let companyID = UInt16(mfgData[0]) | (UInt16(mfgData[1]) << 8)
            if companyID == legoCompanyID {
                return true
            }
        }

        // Check device name
        if let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
           name.contains("LEGO") || name.contains("Technic") || name.contains("SPIKE") {
            return true
        }

        return false
    }

    /// Check for LEGO hubs that are already connected at the system level
    /// (paired via Bluetooth Settings — these won't appear in scan results).
    private func checkForConnectedHubs() {
        let connected = centralManager.retrieveConnectedPeripherals(withServices: Array(Self.legoServiceUUIDs))
        for peripheral in connected {
            DispatchQueue.main.async {
                guard self.devices[peripheral.identifier] == nil else { return }

                #if DEBUG
                print("Found already-connected LEGO hub: \(peripheral.name ?? "unknown") (\(peripheral.identifier))")
                #endif

                self.devices[peripheral.identifier] = RIHub(centralManager: self.centralManager,
                                                            peripheral: peripheral,
                                                            advertisementData: [:],
                                                            rssi: 0)
            }
        }
    }
}


extension RIHubManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .unknown:
            print("central.state is .unknown")

        case .resetting:
            print("central.state is .resetting")

        case .unsupported:
            print("central.state is .unsupported")

        case .unauthorized:
            print("central.state is .unauthorized")

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

        case .poweredOn:
            print("central.state is .poweredOn")
            if isRunning {
                print("  - listening for LEGO hubs...")

                // Pick up hubs already connected at the system level
                checkForConnectedHubs()

                // Scan for advertising hubs — use nil to catch all BLE advertisements,
                // then filter in didDiscover. This is more reliable than service UUID
                // filtering, which can miss hubs that don't include service UUIDs in
                // their advertisement packets.
                centralManager.scanForPeripherals(withServices: nil,
                                                  options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                DispatchQueue.main.async {
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true, block: self.timerFired)
                }
            }

        @unknown default:
            fatalError()
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.BluetoothStateChangedNotification, object: self)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Already tracking this device — just update it
        if let hub = devices[peripheral.identifier] {
            DispatchQueue.main.async {
                hub.lastSeen = Date()
                hub.rssi = RSSI.intValue
                hub.broadcastStateChange()
            }
            return
        }

        // Not yet tracked — check if it's a LEGO hub
        guard Self.isLEGOHub(peripheral: peripheral, advertisementData: advertisementData) else { return }

        #if DEBUG
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "unknown"
        print("Discovered LEGO hub: \(name) (\(peripheral.identifier)), ad: \(advertisementData)")
        #endif

        DispatchQueue.main.async {
            self.devices[peripheral.identifier] = RIHub(centralManager: self.centralManager,
                                                        peripheral: peripheral,
                                                        advertisementData: advertisementData,
                                                        rssi: RSSI.intValue)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        #if DEBUG
        print("didConnect: \(peripheral)")
        #endif

        DispatchQueue.main.async {
            guard let hub = self.devices[peripheral.identifier] else { return }

            hub.lastSeen = Date()
            hub.broadcastStateChange()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        #if DEBUG
        print("didFailToConnect: \(peripheral), error: \(String(describing: error))")
        #endif

        DispatchQueue.main.async {
            guard let hub = self.devices[peripheral.identifier] else { return }

            hub.lastSeen = Date()
            hub.broadcastStateChange()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        #if DEBUG
        print("didDisconnectPeripheral: \(peripheral), error: \(String(describing: error))")
        #endif

        DispatchQueue.main.async {
            guard let hub = self.devices[peripheral.identifier] else { return }

            hub.lastSeen = Date()
            hub.broadcastStateChange()
        }
    }
}

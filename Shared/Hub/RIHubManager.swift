//
//  RIHubManager.swift
//  RobotInventorHUB
//
//  Created by Mark Alldritt on 2020-03-17.
//  Copyright © 2020 Mark Alldritt. All rights reserved.
//

#if os(iOS)
import UIKit
import ExternalAccessory
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

    /// EA protocol string for LEGO hubs.
    static let legoEAProtocol = "com.lego.les"

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
    /// BLE peripheral UUIDs that connected but had no usable protocol (FD02/LWP3).
    /// Suppresses re-adding them from BLE scan — they should use EA instead.
    private var bleNoProtocolUUIDs = Set<UUID>()

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

        #if os(iOS)
        startEAMonitoring()
        #endif
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

        #if os(iOS)
        stopEAMonitoring()
        #endif
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

                self.devices[peripheral.identifier] = RIHub(centralManager: self.centralManager,
                                                            peripheral: peripheral,
                                                            advertisementData: [:],
                                                            rssi: 0)
            }
        }
    }

    // MARK: - ExternalAccessory Discovery (iOS only)

    #if os(iOS)

    private func startEAMonitoring() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(eaAccessoryDidConnect(_:)),
                                               name: .EAAccessoryDidConnect,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(eaAccessoryDidDisconnect(_:)),
                                               name: .EAAccessoryDidDisconnect,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(bleHubNoUsableProtocol(_:)),
                                               name: RIHub.NoUsableProtocolNotification,
                                               object: nil)

        EAAccessoryManager.shared().registerForLocalNotifications()

        // Check for already-connected EA accessories
        checkForEAAccessories()
    }

    private func stopEAMonitoring() {
        NotificationCenter.default.removeObserver(self, name: .EAAccessoryDidConnect, object: nil)
        NotificationCenter.default.removeObserver(self, name: .EAAccessoryDidDisconnect, object: nil)
        NotificationCenter.default.removeObserver(self, name: RIHub.NoUsableProtocolNotification, object: nil)
        EAAccessoryManager.shared().unregisterForLocalNotifications()
    }

    private func checkForEAAccessories() {
        let accessories = EAAccessoryManager.shared().connectedAccessories
        #if DEBUG
        print("EA: Checking \(accessories.count) connected accessories")
        for acc in accessories {
            print("EA:   \(acc.name) protocols=\(acc.protocolStrings) connected=\(acc.isConnected) connectionID=\(acc.connectionID)")
        }
        #endif
        for accessory in accessories {
            addEAAccessoryIfLEGO(accessory)
        }
    }

    private func addEAAccessoryIfLEGO(_ accessory: EAAccessory) {
        guard accessory.protocolStrings.contains(Self.legoEAProtocol) else { return }

        let hub = RIHub(accessory: accessory, protocolString: Self.legoEAProtocol)
        let hubID = hub.identifier

        DispatchQueue.main.async {
            guard self.devices[hubID] == nil else { return }
            self.devices[hubID] = hub
            #if DEBUG
            print("EA: Added hub \(accessory.name) (connectionID=\(accessory.connectionID))")
            #endif
        }
    }

    @objc private func eaAccessoryDidConnect(_ notification: Notification) {
        guard let accessory = notification.userInfo?[EAAccessoryKey] as? EAAccessory else { return }
        addEAAccessoryIfLEGO(accessory)
    }

    /// A BLE hub connected but found no usable protocol (FD02 or LWP3).
    /// Disconnect BLE, wait for Bluetooth Classic to re-establish, then check EA.
    /// If EA still has nothing, show the system accessory picker.
    @objc private func bleHubNoUsableProtocol(_ notification: Notification) {
        guard let hub = notification.object as? RIHub, hub.transport == .ble else { return }

        #if DEBUG
        print("EA: BLE hub \(hub.deviceName) has no usable protocol — disconnecting BLE, will check EA")
        #endif

        // Remember this peripheral so BLE scan doesn't re-add it
        bleNoProtocolUUIDs.insert(hub.identifier)

        // Disconnect the useless BLE connection and remove from device list
        hub.disconnect()
        DispatchQueue.main.async {
            self.devices.removeValue(forKey: hub.identifier)
        }

        // After BLE disconnects, the hub may re-establish its Bluetooth Classic
        // connection after a brief delay. Try EA a few times before showing the picker.
        self.retryEACheck(attemptsRemaining: 3, interval: 1.5)
    }

    /// Retry EA accessory check with delay. If all retries exhausted with no EA hub found,
    /// show the system Bluetooth accessory picker to initiate Classic pairing.
    private func retryEACheck(attemptsRemaining: Int, interval: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self = self else { return }

            self.checkForEAAccessories()

            // Check if we now have an EA hub
            let hasEAHub = self.devices.values.contains { $0.transport == .externalAccessory }
            if hasEAHub {
                #if DEBUG
                print("EA: Found EA hub after BLE fallback")
                #endif
                return
            }

            if attemptsRemaining > 1 {
                #if DEBUG
                print("EA: No EA hub yet, retrying... (\(attemptsRemaining - 1) attempts left)")
                #endif
                self.retryEACheck(attemptsRemaining: attemptsRemaining - 1, interval: interval)
            } else {
                // All retries exhausted — show the system accessory picker
                #if DEBUG
                print("EA: No EA hub found after retries — showing accessory picker")
                #endif
                EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil) { error in
                    if let error = error as NSError?, error.code != EABluetoothAccessoryPickerError.alreadyConnected.rawValue {
                        #if DEBUG
                        print("EA: Picker error: \(error.localizedDescription)")
                        #endif
                    }
                    // After picker completes, eaAccessoryDidConnect will fire if user paired a device
                }
            }
        }
    }

    @objc private func eaAccessoryDidDisconnect(_ notification: Notification) {
        guard let accessory = notification.userInfo?[EAAccessoryKey] as? EAAccessory else { return }
        guard accessory.protocolStrings.contains(Self.legoEAProtocol) else { return }

        // Find and remove the hub for this accessory
        DispatchQueue.main.async {
            let toRemove = self.devices.filter { (_, hub) in
                hub.eaAccessory?.connectionID == accessory.connectionID
            }
            for (uuid, hub) in toRemove {
                hub.disconnect()
                self.devices.removeValue(forKey: uuid)
                #if DEBUG
                print("EA: Removed hub \(accessory.name) (connectionID=\(accessory.connectionID))")
                #endif
            }
        }
    }

    #endif  // os(iOS)
}


extension RIHubManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .unknown, .resetting, .unsupported, .unauthorized:
            break

        case .poweredOff:
            if isRunning {
                centralManager.stopScan()
                DispatchQueue.main.async {
                    self.timer?.invalidate()
                    self.timer = nil
                    // Only disconnect BLE hubs; EA hubs are independent of CoreBluetooth state
                    for hub in self.hubs where hub.transport == .ble {
                        hub.disconnect()
                    }
                    self.devices = self.devices.filter { (_, hub) in
                        #if os(iOS)
                        return hub.transport == .externalAccessory
                        #else
                        return false
                        #endif
                    }
                }
            }

        case .poweredOn:
            if isRunning {
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

        #if os(iOS)
        // Skip peripherals that previously connected but had no usable BLE protocol
        // (these hubs need ExternalAccessory instead)
        if bleNoProtocolUUIDs.contains(peripheral.identifier) { return }
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
        print("BLE: didConnect \(peripheral.name ?? "?")")
        #endif
        DispatchQueue.main.async {
            guard let hub = self.devices[peripheral.identifier] else { return }

            hub.lastSeen = Date()
            hub.broadcastStateChange()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        #if DEBUG
        print("BLE: didFailToConnect \(peripheral.name ?? "?") error=\(error?.localizedDescription ?? "none")")
        #endif
        DispatchQueue.main.async {
            guard let hub = self.devices[peripheral.identifier] else { return }

            hub.lastSeen = Date()
            hub.broadcastStateChange()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        #if DEBUG
        print("BLE: didDisconnect \(peripheral.name ?? "?") error=\(error?.localizedDescription ?? "none")")
        #endif
        DispatchQueue.main.async {
            guard let hub = self.devices[peripheral.identifier] else { return }

            hub.lastSeen = Date()
            hub.broadcastStateChange()
        }
    }
}

//
//  SPIKEJSONParser.swift
//  RobotInventorHUB
//
//  Parses JSON telemetry from the SPIKE App 3 firmware (ExternalAccessory transport).
//  Maps JSON messages into the same SPIKEDeviceNotification data structures used by
//  the BLE SPIKE protocol, so the UI works unchanged.
//
//  JSON protocol:
//    m=0: device telemetry — p[0..5]=ports, p[6]=accel, p[7]=gyro, p[8]=orientation
//    m=2: battery — p[0]=voltage, p[1]=percentage, p[2]=charging
//

import Foundation

struct SPIKEJSONParser {

    // MARK: - Device Type IDs (from JSON telemetry)

    /// Motor device types across SPIKE Prime and Robot Inventor.
    /// Type 1 = simple motor (speed only, no position feedback).
    static let motorTypes: Set<Int> = [1, 2, 48, 49, 65, 75, 76]

    /// Distance sensor types.
    static let distanceTypes: Set<Int> = [62]

    /// Color sensor types.
    static let colorTypes: Set<Int> = [61]

    /// Combined Color & Distance Sensor (Robot Inventor / Boost).
    /// values = [colorID, proximity, reflected, ambient]
    static let colorDistanceComboTypes: Set<Int> = [37]

    /// Force sensor types.
    static let forceTypes: Set<Int> = [63]

    /// Light matrix types.
    static let lightMatrixTypes: Set<Int> = [64]

    /// Simple light types (Powered Up lights, hub LED).
    /// Recognized for display but not controllable via scratch protocol.
    static let simpleLightTypes: Set<Int> = [8]

    /// Hub internal devices (status LED, etc.) — skip display.
    static let hubInternalTypes: Set<Int> = []

    // MARK: - Value Helpers

    /// Extract an Int from a value that may be Int, Double, or String.
    /// The firmware sometimes sends -1 as the string "-1".
    private static func intValue(_ val: Any) -> Int? {
        if let i = val as? Int { return i }
        if let d = val as? Double { return Int(d) }
        if let s = val as? String { return Int(s) }
        return nil
    }

    // MARK: - m=0: Device Telemetry

    /// Parse an m=0 telemetry message and update the hub's device state.
    /// `params` is the "p" array from the JSON message.
    static func parseDeviceTelemetry(_ params: [Any], into hub: RIHub) {
        // Ports A–F are params[0..5]
        let portCount = min(params.count, 6)

        var motors: [UInt8: SPIKEDeviceNotification.Motor] = [:]
        var distances: [UInt8: SPIKEDeviceNotification.Distance] = [:]
        var colors: [UInt8: SPIKEDeviceNotification.Color] = [:]
        var forces: [UInt8: SPIKEDeviceNotification.Force] = [:]
        var lightMatrices: [UInt8: SPIKEDeviceNotification.LightMatrix] = [:]
        var devices: [UInt8: UInt16] = [:]

        for portIndex in 0..<portCount {
            let port = UInt8(portIndex)

            // Each port entry is [deviceTypeID, [values...]]
            guard let portArray = params[portIndex] as? [Any],
                  portArray.count >= 2,
                  let deviceType = portArray[0] as? Int else {
                continue
            }

            // Type 0 with empty array = no device
            if deviceType == 0 {
                continue
            }

            // Skip hub-internal virtual ports (status LED on port A, etc.)
            if hubInternalTypes.contains(deviceType) {
                continue
            }

            devices[port] = UInt16(deviceType)

            guard let values = portArray[1] as? [Any] else { continue }

            if motorTypes.contains(deviceType) {
                if let motor = parseMotor(port: port, deviceType: deviceType, values: values) {
                    motors[port] = motor
                }
            } else if distanceTypes.contains(deviceType) {
                if let dist = parseDistance(port: port, values: values) {
                    distances[port] = dist
                }
            } else if colorTypes.contains(deviceType) {
                if let color = parseColor(port: port, values: values) {
                    colors[port] = color
                }
            } else if colorDistanceComboTypes.contains(deviceType) {
                // Combined sensor — produces both distance and color entries
                let (dist, color) = parseColorDistanceCombo(port: port, values: values)
                if let dist = dist { distances[port] = dist }
                if let color = color { colors[port] = color }
            } else if forceTypes.contains(deviceType) {
                if let force = parseForce(port: port, values: values) {
                    forces[port] = force
                }
            } else if lightMatrixTypes.contains(deviceType) {
                if let light = parseLightMatrix(port: port, values: values) {
                    lightMatrices[port] = light
                }
            } else if simpleLightTypes.contains(deviceType) {
                // Known light — tracked in attachedDevices for UI display
                // (not controllable via scratch protocol)
            }
            // Other device types: still tracked in attachedDevices via `devices` dict
        }

        // Update hub state atomically
        hub.dataLock.lock()
        hub.spikeMotors = motors
        hub.spikeDistances = distances
        hub.spikeColors = colors
        hub.spikeForces = forces
        hub.spikeLightMatrices = lightMatrices
        hub.attachedDevices = devices
        hub.dataLock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: RIHub.DeviceDataChangedNotification, object: hub)
        }

        #if DEBUG
        var summary: [String] = []
        if !motors.isEmpty { summary.append("motors=\(motors.count)") }
        if !distances.isEmpty { summary.append("dist=\(distances.count)") }
        if !colors.isEmpty { summary.append("color=\(colors.count)") }
        if !forces.isEmpty { summary.append("force=\(forces.count)") }
        if !lightMatrices.isEmpty { summary.append("light=\(lightMatrices.count)") }
        // Log raw port info for unrecognized devices
        for portIndex in 0..<portCount {
            guard let portArray = params[portIndex] as? [Any],
                  portArray.count >= 2,
                  let deviceType = portArray[0] as? Int,
                  deviceType != 0 else { continue }
            let port = UInt8(portIndex)
            let known = motors[port] != nil || distances[port] != nil ||
                        colors[port] != nil || forces[port] != nil || lightMatrices[port] != nil ||
                        hubInternalTypes.contains(deviceType)
            if !known {
                let vals = portArray.count > 1 ? "\(portArray[1])" : "?"
                summary.append("\(RIHub.portLetter(port)):type\(deviceType)=\(vals)")
            }
        }
        if !summary.isEmpty {
            print("EA JSON: \(summary.joined(separator: " "))")
        }
        #endif
    }

    // MARK: - m=2: Battery

    /// Parse an m=2 battery message.
    /// `params` = [voltage, percentage, charging]
    static func parseBattery(_ params: [Any], into hub: RIHub) {
        guard params.count >= 2 else { return }

        if let percentage = params[1] as? Int {
            hub.batteryv = Double(percentage)
            #if DEBUG
            print("EA JSON: Battery \(percentage)%")
            #endif
        } else if let percentage = params[1] as? Double {
            hub.batteryv = percentage
            #if DEBUG
            print("EA JSON: Battery \(Int(percentage))%")
            #endif
        }
    }

    // MARK: - Individual Device Parsers

    /// Parse motor data.
    /// Angular motors (type 75 etc.): [speed, ?, position, ?]
    /// Simple motors (type 1 etc.): [speed]
    private static func parseMotor(port: UInt8, deviceType: Int, values: [Any]) -> SPIKEDeviceNotification.Motor? {
        guard !values.isEmpty else { return nil }

        let speed = intValue(values[0]) ?? 0
        let position = values.count >= 3 ? (intValue(values[2]) ?? 0) : 0

        return SPIKEDeviceNotification.Motor(
            port: port,
            deviceType: UInt8(clamping: deviceType),
            absolutePosition: 0,
            power: Int16(clamping: speed),
            speed: Int8(clamping: speed),
            position: Int32(clamping: position)
        )
    }

    /// Parse distance sensor: [distance_cm_or_null]
    private static func parseDistance(port: UInt8, values: [Any]) -> SPIKEDeviceNotification.Distance? {
        guard !values.isEmpty else { return nil }

        if let cm = intValue(values[0]), cm >= 0 {
            // Convert cm to mm for consistency with BLE protocol
            return SPIKEDeviceNotification.Distance(port: port, distanceMM: Int16(clamping: cm * 10))
        } else {
            // null or -1 = nothing detected
            return SPIKEDeviceNotification.Distance(port: port, distanceMM: -1)
        }
    }

    /// Parse color sensor: [reflected, colorID, r, g, b]
    private static func parseColor(port: UInt8, values: [Any]) -> SPIKEDeviceNotification.Color? {
        guard values.count >= 5 else { return nil }

        let colorID = intValue(values[1]) ?? -1
        let red = intValue(values[2]) ?? 0
        let green = intValue(values[3]) ?? 0
        let blue = intValue(values[4]) ?? 0

        return SPIKEDeviceNotification.Color(
            port: port,
            colorID: Int8(clamping: colorID),
            red: UInt16(clamping: red),
            green: UInt16(clamping: green),
            blue: UInt16(clamping: blue)
        )
    }

    /// Parse Color & Distance combo sensor (type 37):
    /// values = [colorID, proximity, reflected, ambient]
    /// colorID may be a string "-1" or an int.
    private static func parseColorDistanceCombo(port: UInt8, values: [Any])
        -> (SPIKEDeviceNotification.Distance?, SPIKEDeviceNotification.Color?)
    {
        var dist: SPIKEDeviceNotification.Distance?
        var color: SPIKEDeviceNotification.Color?

        // Distance from proximity (index 1): 0-10 scale, roughly 0-100mm
        if values.count > 1, let prox = intValue(values[1]) {
            let mm = prox >= 0 ? prox * 10 : -1
            dist = SPIKEDeviceNotification.Distance(port: port, distanceMM: Int16(clamping: mm))
        }

        // Color from colorID (index 0)
        let colorID = values.count > 0 ? (intValue(values[0]) ?? -1) : -1
        let reflected = values.count > 2 ? (intValue(values[2]) ?? 0) : 0
        let ambient = values.count > 3 ? (intValue(values[3]) ?? 0) : 0
        color = SPIKEDeviceNotification.Color(
            port: port,
            colorID: Int8(clamping: colorID),
            red: UInt16(clamping: reflected),   // use reflected as approximate brightness
            green: UInt16(clamping: ambient),
            blue: 0
        )

        return (dist, color)
    }

    /// Parse force sensor: [force, pressed]
    private static func parseForce(port: UInt8, values: [Any]) -> SPIKEDeviceNotification.Force? {
        guard values.count >= 2 else { return nil }

        let force = intValue(values[0]) ?? 0
        let pressed = intValue(values[1]) ?? 0

        return SPIKEDeviceNotification.Force(
            port: port,
            force: UInt8(clamping: force),
            pressed: UInt8(clamping: pressed)
        )
    }

    /// Parse 3x3 light matrix: [pixels...]
    private static func parseLightMatrix(port: UInt8, values: [Any]) -> SPIKEDeviceNotification.LightMatrix? {
        let pixels = values.compactMap { intValue($0) }.map { UInt8(clamping: $0) }
        guard !pixels.isEmpty else { return nil }

        // Pad to 9 if needed
        var padded = pixels
        while padded.count < 9 {
            padded.append(0)
        }

        return SPIKEDeviceNotification.LightMatrix(port: port, pixels: Array(padded.prefix(9)))
    }
}

//
//  LWP3Message.swift
//  RobotInventorHUB
//
//  Incoming LWP3 binary message parser.
//  Pure Swift — no UIKit/AppKit/CoreBluetooth dependencies.
//

import Foundation

// MARK: - Data Helpers

extension Data {
    func lwp3_uint16LE(at offset: Int) -> UInt16? {
        guard offset + 2 <= count else { return nil }
        return UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func lwp3_uint32LE(at offset: Int) -> UInt32? {
        guard offset + 4 <= count else { return nil }
        return UInt32(self[startIndex + offset])
             | (UInt32(self[startIndex + offset + 1]) << 8)
             | (UInt32(self[startIndex + offset + 2]) << 16)
             | (UInt32(self[startIndex + offset + 3]) << 24)
    }

    func lwp3_int8(at offset: Int) -> Int8? {
        guard offset < count else { return nil }
        return Int8(bitPattern: self[startIndex + offset])
    }

    func lwp3_int16LE(at offset: Int) -> Int16? {
        guard let raw = lwp3_uint16LE(at: offset) else { return nil }
        return Int16(bitPattern: raw)
    }

    func lwp3_int32LE(at offset: Int) -> Int32? {
        guard let raw = lwp3_uint32LE(at: offset) else { return nil }
        return Int32(bitPattern: raw)
    }
}

// MARK: - Parsed Message

enum LWP3Message {
    case hubProperty(property: LWP3HubProperty, operation: LWP3HubPropertyOperation, payload: Data)
    case hubAction(action: LWP3HubActionType)
    case hubAlert(alertType: UInt8, operation: UInt8, payload: Data)
    case hubAttachedIO(portID: UInt8, event: LWP3IOEvent, deviceType: LWP3IODeviceType?,
                       deviceTypeRaw: UInt16,
                       hwRevision: UInt32?, swRevision: UInt32?,
                       portIDA: UInt8?, portIDB: UInt8?)
    case portValueSingle(portID: UInt8, value: Data)
    case portValueCombined(portID: UInt8, modePointers: UInt16, value: Data)
    case portInformation(portID: UInt8, informationType: UInt8, payload: Data)
    case portModeInformation(portID: UInt8, mode: UInt8, informationType: UInt8, payload: Data)
    case portInputFormatSingle(portID: UInt8, mode: UInt8, deltaInterval: UInt32, notificationEnabled: Bool)
    case portOutputCommandFeedback(portID: UInt8, feedback: UInt8)
    case genericError(commandType: UInt8, errorCode: UInt8)
    case unknown(messageType: UInt8, payload: Data)

    // MARK: - Parsing

    static func parse(from data: Data) -> LWP3Message? {
        guard data.count >= 3 else { return nil }

        // Decode message length and determine header size
        let headerOffset: Int
        if data[data.startIndex] == 0x00 {
            // Possibly a 2-byte length (high bit set would be in a real >127-byte message)
            // Actually in LWP3: if first byte has bit 7 set, length is 2 bytes.
            // But let's handle the standard way:
            guard data.count >= 4 else { return nil }
            headerOffset = 4 // 2 bytes length + 1 byte hub ID + message type starts at byte 3
        } else if data[data.startIndex] & 0x80 != 0 {
            // 2-byte length: bits [6:0] of byte 0 are low 7, byte 1 is high 8
            guard data.count >= 4 else { return nil }
            headerOffset = 4
        } else {
            headerOffset = 3 // 1 byte length + 1 byte hub ID + message type at byte 2
        }

        // Hub ID is always at offset 1 (single-byte length) or 2 (two-byte length)
        // Message type follows hub ID
        let messageTypeOffset: Int
        if headerOffset == 4 {
            messageTypeOffset = 3
        } else {
            messageTypeOffset = 2
        }

        let messageTypeByte = data[data.startIndex + messageTypeOffset]
        let payloadStart = data.startIndex + messageTypeOffset + 1
        let payload = data.count > messageTypeOffset + 1 ? data[payloadStart...] : Data()

        guard let messageType = LWP3MessageType(rawValue: messageTypeByte) else {
            return .unknown(messageType: messageTypeByte, payload: Data(payload))
        }

        switch messageType {
        case .hubProperties:
            return parseHubProperty(Data(payload))

        case .hubActions:
            return parseHubAction(Data(payload))

        case .hubAlerts:
            return parseHubAlert(Data(payload))

        case .hubAttachedIO:
            return parseHubAttachedIO(Data(payload))

        case .portValueSingle:
            return parsePortValueSingle(Data(payload))

        case .portValueCombined:
            return parsePortValueCombined(Data(payload))

        case .portInformation:
            return parsePortInformation(Data(payload))

        case .portModeInformation:
            return parsePortModeInformation(Data(payload))

        case .portInputFormatSingle:
            return parsePortInputFormatSingle(Data(payload))

        case .portOutputCommandFeedback:
            return parsePortOutputCommandFeedback(Data(payload))

        case .genericError:
            return parseGenericError(Data(payload))

        default:
            return .unknown(messageType: messageTypeByte, payload: Data(payload))
        }
    }

    // MARK: - Individual Parsers

    private static func parseHubProperty(_ payload: Data) -> LWP3Message? {
        guard payload.count >= 2,
              let property = LWP3HubProperty(rawValue: payload[payload.startIndex]),
              let operation = LWP3HubPropertyOperation(rawValue: payload[payload.startIndex + 1])
        else { return nil }
        let value = payload.count > 2 ? Data(payload[(payload.startIndex + 2)...]) : Data()
        return .hubProperty(property: property, operation: operation, payload: value)
    }

    private static func parseHubAction(_ payload: Data) -> LWP3Message? {
        guard payload.count >= 1,
              let action = LWP3HubActionType(rawValue: payload[payload.startIndex])
        else { return nil }
        return .hubAction(action: action)
    }

    private static func parseHubAlert(_ payload: Data) -> LWP3Message? {
        guard payload.count >= 2 else { return nil }
        let alertType = payload[payload.startIndex]
        let operation = payload[payload.startIndex + 1]
        let value = payload.count > 2 ? Data(payload[(payload.startIndex + 2)...]) : Data()
        return .hubAlert(alertType: alertType, operation: operation, payload: value)
    }

    private static func parseHubAttachedIO(_ payload: Data) -> LWP3Message? {
        guard payload.count >= 2 else { return nil }
        let portID = payload[payload.startIndex]
        guard let event = LWP3IOEvent(rawValue: payload[payload.startIndex + 1]) else { return nil }

        switch event {
        case .detached:
            return .hubAttachedIO(portID: portID, event: event, deviceType: nil,
                                  deviceTypeRaw: 0,
                                  hwRevision: nil, swRevision: nil,
                                  portIDA: nil, portIDB: nil)

        case .attached:
            guard payload.count >= 10 else { return nil }
            let deviceTypeRaw = payload.lwp3_uint16LE(at: 2) ?? 0
            let deviceType = LWP3IODeviceType(rawValue: deviceTypeRaw)
            let hwRevision = payload.lwp3_uint32LE(at: 4)
            let swRevision = payload.lwp3_uint32LE(at: 8)
            return .hubAttachedIO(portID: portID, event: event, deviceType: deviceType,
                                  deviceTypeRaw: deviceTypeRaw,
                                  hwRevision: hwRevision, swRevision: swRevision,
                                  portIDA: nil, portIDB: nil)

        case .attachedVirtual:
            guard payload.count >= 6 else { return nil }
            let deviceTypeRaw = payload.lwp3_uint16LE(at: 2) ?? 0
            let deviceType = LWP3IODeviceType(rawValue: deviceTypeRaw)
            let portIDA = payload[payload.startIndex + 4]
            let portIDB = payload[payload.startIndex + 5]
            return .hubAttachedIO(portID: portID, event: event, deviceType: deviceType,
                                  deviceTypeRaw: deviceTypeRaw,
                                  hwRevision: nil, swRevision: nil,
                                  portIDA: portIDA, portIDB: portIDB)
        }
    }

    private static func parsePortValueSingle(_ payload: Data) -> LWP3Message? {
        guard payload.count >= 1 else { return nil }
        let portID = payload[payload.startIndex]
        let value = payload.count > 1 ? Data(payload[(payload.startIndex + 1)...]) : Data()
        return .portValueSingle(portID: portID, value: value)
    }

    private static func parsePortValueCombined(_ payload: Data) -> LWP3Message? {
        guard payload.count >= 3,
              let modePointers = payload.lwp3_uint16LE(at: 1)
        else { return nil }
        let portID = payload[payload.startIndex]
        let value = payload.count > 3 ? Data(payload[(payload.startIndex + 3)...]) : Data()
        return .portValueCombined(portID: portID, modePointers: modePointers, value: value)
    }

    private static func parsePortInformation(_ payload: Data) -> LWP3Message? {
        guard payload.count >= 2 else { return nil }
        let portID = payload[payload.startIndex]
        let informationType = payload[payload.startIndex + 1]
        let rest = payload.count > 2 ? Data(payload[(payload.startIndex + 2)...]) : Data()
        return .portInformation(portID: portID, informationType: informationType, payload: rest)
    }

    private static func parsePortModeInformation(_ payload: Data) -> LWP3Message? {
        guard payload.count >= 3 else { return nil }
        let portID = payload[payload.startIndex]
        let mode = payload[payload.startIndex + 1]
        let informationType = payload[payload.startIndex + 2]
        let rest = payload.count > 3 ? Data(payload[(payload.startIndex + 3)...]) : Data()
        return .portModeInformation(portID: portID, mode: mode, informationType: informationType, payload: rest)
    }

    private static func parsePortInputFormatSingle(_ payload: Data) -> LWP3Message? {
        guard payload.count >= 6 else { return nil }
        let portID = payload[payload.startIndex]
        let mode = payload[payload.startIndex + 1]
        guard let deltaInterval = payload.lwp3_uint32LE(at: 2) else { return nil }
        let notificationEnabled = payload[payload.startIndex + 6] != 0
        return .portInputFormatSingle(portID: portID, mode: mode,
                                       deltaInterval: deltaInterval,
                                       notificationEnabled: notificationEnabled)
    }

    private static func parsePortOutputCommandFeedback(_ payload: Data) -> LWP3Message? {
        guard payload.count >= 2 else { return nil }
        let portID = payload[payload.startIndex]
        let feedback = payload[payload.startIndex + 1]
        return .portOutputCommandFeedback(portID: portID, feedback: feedback)
    }

    private static func parseGenericError(_ payload: Data) -> LWP3Message? {
        guard payload.count >= 2 else { return nil }
        return .genericError(commandType: payload[payload.startIndex],
                             errorCode: payload[payload.startIndex + 1])
    }
}

// MARK: - CustomStringConvertible

extension LWP3Message: CustomStringConvertible {
    var description: String {
        switch self {
        case .hubProperty(let property, let operation, let payload):
            return "HubProperty(\(property), \(operation), \(payload.count) bytes)"
        case .hubAction(let action):
            return "HubAction(\(action))"
        case .hubAlert(let alertType, let operation, _):
            return "HubAlert(type: 0x\(String(format: "%02X", alertType)), op: 0x\(String(format: "%02X", operation)))"
        case .hubAttachedIO(let portID, let event, _, let deviceTypeRaw, _, _, let portIDA, let portIDB):
            let portName = LWP3PortID(value: portID).displayName
            let typeName = LWP3IODeviceType(rawValue: deviceTypeRaw)?.displayName ?? "Unknown(\(deviceTypeRaw))"
            switch event {
            case .detached:
                return "IO Detached(port \(portName))"
            case .attached:
                return "IO Attached(port \(portName): \(typeName))"
            case .attachedVirtual:
                return "IO VirtualAttached(port \(portName): \(typeName), ports \(portIDA ?? 0)+\(portIDB ?? 0))"
            }
        case .portValueSingle(let portID, let value):
            return "PortValue(port \(LWP3PortID(value: portID).displayName), \(value.count) bytes)"
        case .portValueCombined(let portID, let modePointers, let value):
            return "PortValueCombined(port \(LWP3PortID(value: portID).displayName), modes: 0x\(String(format: "%04X", modePointers)), \(value.count) bytes)"
        case .portInformation(let portID, let informationType, _):
            return "PortInfo(port \(LWP3PortID(value: portID).displayName), type: 0x\(String(format: "%02X", informationType)))"
        case .portModeInformation(let portID, let mode, let informationType, _):
            return "PortModeInfo(port \(LWP3PortID(value: portID).displayName), mode: \(mode), type: 0x\(String(format: "%02X", informationType)))"
        case .portInputFormatSingle(let portID, let mode, let deltaInterval, let notificationEnabled):
            return "PortInputFormat(port \(LWP3PortID(value: portID).displayName), mode: \(mode), delta: \(deltaInterval), notify: \(notificationEnabled))"
        case .portOutputCommandFeedback(let portID, let feedback):
            return "PortOutputFeedback(port \(LWP3PortID(value: portID).displayName), 0x\(String(format: "%02X", feedback)))"
        case .genericError(let commandType, let errorCode):
            return "Error(cmd: 0x\(String(format: "%02X", commandType)), err: 0x\(String(format: "%02X", errorCode)))"
        case .unknown(let messageType, let payload):
            return "Unknown(type: 0x\(String(format: "%02X", messageType)), \(payload.count) bytes)"
        }
    }
}

//
//  LWP3Command.swift
//  RobotInventorHUB
//
//  Outgoing LWP3 command builder.
//  Pure Swift — no UIKit/AppKit/CoreBluetooth dependencies.
//

import Foundation

struct LWP3Command {

    // MARK: - Hub Properties

    static func requestHubProperty(_ property: LWP3HubProperty) -> Data {
        return buildMessage(type: .hubProperties, payload: [property.rawValue, LWP3HubPropertyOperation.requestUpdate.rawValue])
    }

    static func enableHubPropertyUpdates(_ property: LWP3HubProperty) -> Data {
        return buildMessage(type: .hubProperties, payload: [property.rawValue, LWP3HubPropertyOperation.enableUpdates.rawValue])
    }

    static func disableHubPropertyUpdates(_ property: LWP3HubProperty) -> Data {
        return buildMessage(type: .hubProperties, payload: [property.rawValue, LWP3HubPropertyOperation.disableUpdates.rawValue])
    }

    static func setHubProperty(_ property: LWP3HubProperty, value: Data) -> Data {
        var payload: [UInt8] = [property.rawValue, LWP3HubPropertyOperation.set.rawValue]
        payload.append(contentsOf: value)
        return buildMessage(type: .hubProperties, payload: payload)
    }

    // MARK: - Hub Actions

    static func hubAction(_ action: LWP3HubActionType) -> Data {
        return buildMessage(type: .hubActions, payload: [action.rawValue])
    }

    // MARK: - Port Input Format Setup

    static func setPortInputFormat(portID: UInt8, mode: UInt8, deltaInterval: UInt32, notificationEnabled: Bool) -> Data {
        var payload: [UInt8] = [portID, mode]
        payload.append(contentsOf: uint32LEBytes(deltaInterval))
        payload.append(notificationEnabled ? 1 : 0)
        return buildMessage(type: .portInputFormatSetupSingle, payload: payload)
    }

    // MARK: - Port Information Requests

    static func requestPortInformation(portID: UInt8, informationType: UInt8) -> Data {
        return buildMessage(type: .portInformationRequest, payload: [portID, informationType])
    }

    static func requestPortModeInformation(portID: UInt8, mode: UInt8, informationType: UInt8) -> Data {
        return buildMessage(type: .portModeInformationRequest, payload: [portID, mode, informationType])
    }

    // MARK: - Motor Commands

    static func motorStartPower(portID: UInt8, power: Int8) -> Data {
        return buildPortOutputCommand(portID: portID, subCommand: .startPower,
                                      payload: [UInt8(bitPattern: power)])
    }

    static func motorStartSpeed(portID: UInt8, speed: Int8, maxPower: Int8 = 100, useProfile: UInt8 = 0x00) -> Data {
        return buildPortOutputCommand(portID: portID, subCommand: .startSpeed,
                                      payload: [UInt8(bitPattern: speed),
                                                UInt8(bitPattern: maxPower),
                                                useProfile])
    }

    static func motorStartSpeedForTime(portID: UInt8, time: UInt16, speed: Int8, maxPower: Int8 = 100,
                                        endState: LWP3MotorEndState = .brake, useProfile: UInt8 = 0x00) -> Data {
        var payload: [UInt8] = []
        payload.append(contentsOf: uint16LEBytes(time))
        payload.append(UInt8(bitPattern: speed))
        payload.append(UInt8(bitPattern: maxPower))
        payload.append(endState.rawValue)
        payload.append(useProfile)
        return buildPortOutputCommand(portID: portID, subCommand: .startSpeedForTime, payload: payload)
    }

    static func motorStartSpeedForDegrees(portID: UInt8, degrees: UInt32, speed: Int8, maxPower: Int8 = 100,
                                           endState: LWP3MotorEndState = .brake, useProfile: UInt8 = 0x00) -> Data {
        var payload: [UInt8] = []
        payload.append(contentsOf: uint32LEBytes(degrees))
        payload.append(UInt8(bitPattern: speed))
        payload.append(UInt8(bitPattern: maxPower))
        payload.append(endState.rawValue)
        payload.append(useProfile)
        return buildPortOutputCommand(portID: portID, subCommand: .startSpeedForDegrees, payload: payload)
    }

    static func motorGotoAbsolutePosition(portID: UInt8, position: Int32, speed: Int8, maxPower: Int8 = 100,
                                           endState: LWP3MotorEndState = .brake, useProfile: UInt8 = 0x00) -> Data {
        var payload: [UInt8] = []
        payload.append(contentsOf: int32LEBytes(position))
        payload.append(UInt8(bitPattern: speed))
        payload.append(UInt8(bitPattern: maxPower))
        payload.append(endState.rawValue)
        payload.append(useProfile)
        return buildPortOutputCommand(portID: portID, subCommand: .gotoAbsolutePosition, payload: payload)
    }

    static func motorBrake(portID: UInt8) -> Data {
        return motorStartPower(portID: portID, power: 127)
    }

    static func motorFloat(portID: UInt8) -> Data {
        return motorStartPower(portID: portID, power: 0)
    }

    // MARK: - LED Commands

    static func setHubLEDColor(portID: UInt8, colorIndex: UInt8) -> Data {
        return buildPortOutputCommand(portID: portID, subCommand: .writeDirectModeData,
                                      payload: [0x00, colorIndex]) // mode 0 = color index
    }

    static func setHubLEDRGB(portID: UInt8, red: UInt8, green: UInt8, blue: UInt8) -> Data {
        return buildPortOutputCommand(portID: portID, subCommand: .writeDirectModeData,
                                      payload: [0x01, red, green, blue]) // mode 1 = RGB
    }

    // MARK: - Virtual Port Setup

    static func createVirtualPort(portIDA: UInt8, portIDB: UInt8) -> Data {
        return buildMessage(type: .virtualPortSetup, payload: [0x01, portIDA, portIDB]) // 0x01 = connect
    }

    static func deleteVirtualPort(portID: UInt8) -> Data {
        return buildMessage(type: .virtualPortSetup, payload: [0x00, portID]) // 0x00 = disconnect
    }

    // MARK: - Message Building Helpers

    private static func buildMessage(type: LWP3MessageType, payload: [UInt8]) -> Data {
        let hubID: UInt8 = 0x00
        // Total length = length byte(s) + hub ID + message type + payload
        let totalLength = 1 + 1 + 1 + payload.count // 1 length + 1 hubID + 1 type + payload

        if totalLength < 128 {
            var bytes: [UInt8] = [UInt8(totalLength), hubID, type.rawValue]
            bytes.append(contentsOf: payload)
            return Data(bytes)
        } else {
            // 2-byte length encoding
            let totalLength2 = totalLength + 1 // extra byte for 2-byte length
            let lowByte = UInt8((totalLength2 & 0x7F) | 0x80)
            let highByte = UInt8(totalLength2 >> 7)
            var bytes: [UInt8] = [lowByte, highByte, hubID, type.rawValue]
            bytes.append(contentsOf: payload)
            return Data(bytes)
        }
    }

    private static func buildPortOutputCommand(portID: UInt8, subCommand: LWP3PortOutputSubCommand,
                                                payload: [UInt8]) -> Data {
        let startupAndCompletion: UInt8 = 0x11 // Execute immediately + command feedback
        var fullPayload: [UInt8] = [portID, startupAndCompletion, subCommand.rawValue]
        fullPayload.append(contentsOf: payload)
        return buildMessage(type: .portOutputCommand, payload: fullPayload)
    }

    // MARK: - Byte Encoding Helpers

    private static func uint16LEBytes(_ value: UInt16) -> [UInt8] {
        return [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private static func uint32LEBytes(_ value: UInt32) -> [UInt8] {
        return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private static func int32LEBytes(_ value: Int32) -> [UInt8] {
        return uint32LEBytes(UInt32(bitPattern: value))
    }
}

//
//  LWP3ProtocolTests.swift
//  LWP3ProtocolTests
//
//  Unit tests for the LWP3 protocol layer (parser + command builder).
//

import XCTest

// The protocol files (LWP3Types, LWP3Message, LWP3Command) are compiled
// directly into this test target — no @testable import needed.

class LWP3ProtocolTests: XCTestCase {

    // MARK: - Helper

    /// Build a Data value from a byte array literal.
    private func bytes(_ values: [UInt8]) -> Data {
        return Data(values)
    }

    // MARK: - Message Parser: Hub Properties

    func testParseHubPropertyBatteryUpdate() {
        // length=6, hubID=0, type=0x01(hubProperties), prop=0x06(battery), op=0x06(update), value=0x64(100%)
        let data = bytes([0x06, 0x00, 0x01, 0x06, 0x06, 0x64])
        guard let msg = LWP3Message.parse(from: data) else {
            XCTFail("Failed to parse battery update")
            return
        }
        if case .hubProperty(let property, let operation, let payload) = msg {
            XCTAssertEqual(property, .batteryVoltage)
            XCTAssertEqual(operation, .update)
            XCTAssertEqual(payload.count, 1)
            XCTAssertEqual(payload.first, 0x64)
        } else {
            XCTFail("Expected hubProperty, got \(msg)")
        }
    }

    func testParseHubPropertyFWVersionUpdate() {
        // length=9, hubID=0, type=0x01, prop=0x03(fwVersion), op=0x06(update), 4 bytes version
        let data = bytes([0x09, 0x00, 0x01, 0x03, 0x06, 0x01, 0x02, 0x03, 0x04])
        guard let msg = LWP3Message.parse(from: data) else {
            XCTFail("Failed to parse FW version")
            return
        }
        if case .hubProperty(let property, let operation, let payload) = msg {
            XCTAssertEqual(property, .fwVersion)
            XCTAssertEqual(operation, .update)
            XCTAssertEqual(payload.count, 4)
        } else {
            XCTFail("Expected hubProperty, got \(msg)")
        }
    }

    // MARK: - Message Parser: Hub Actions

    func testParseHubActionWillDisconnect() {
        let data = bytes([0x04, 0x00, 0x02, 0x31])
        guard let msg = LWP3Message.parse(from: data) else {
            XCTFail("Failed to parse hub action")
            return
        }
        if case .hubAction(let action) = msg {
            XCTAssertEqual(action, .willDisconnect)
        } else {
            XCTFail("Expected hubAction, got \(msg)")
        }
    }

    func testParseHubActionWillSwitchOff() {
        let data = bytes([0x04, 0x00, 0x02, 0x30])
        guard let msg = LWP3Message.parse(from: data) else {
            XCTFail("Failed to parse hub action")
            return
        }
        if case .hubAction(let action) = msg {
            XCTAssertEqual(action, .willSwitchOff)
        } else {
            XCTFail("Expected hubAction, got \(msg)")
        }
    }

    // MARK: - Message Parser: Hub Attached IO

    func testParseAttachedIOMotorOnPortA() {
        // Attached: port=0(A), event=1(attached), deviceType=0x0031(49=spikeLargeMotor), HW rev, SW rev
        let data = bytes([0x0F, 0x00, 0x04,
                          0x00,                   // port 0 = A
                          0x01,                   // event = attached
                          0x31, 0x00,             // device type 49 (LE) = spikeLargeMotor
                          0x00, 0x00, 0x00, 0x10, // HW revision
                          0x00, 0x00, 0x00, 0x10  // SW revision
                         ])
        guard let msg = LWP3Message.parse(from: data) else {
            XCTFail("Failed to parse attached IO")
            return
        }
        if case .hubAttachedIO(let portID, let event, let deviceType, let hwRev, let swRev, let portIDA, let portIDB) = msg {
            XCTAssertEqual(portID, 0)
            XCTAssertEqual(event, .attached)
            XCTAssertEqual(deviceType, .spikeLargeMotor)
            XCTAssertNotNil(hwRev)
            XCTAssertNotNil(swRev)
            XCTAssertNil(portIDA)
            XCTAssertNil(portIDB)
        } else {
            XCTFail("Expected hubAttachedIO, got \(msg)")
        }
    }

    func testParseAttachedIOColorSensor() {
        // Technic Color Sensor (type 61 = 0x3D) on port C (2)
        let data = bytes([0x0F, 0x00, 0x04,
                          0x02,                   // port 2 = C
                          0x01,                   // event = attached
                          0x3D, 0x00,             // device type 61 (LE)
                          0x01, 0x00, 0x00, 0x00, // HW revision
                          0x01, 0x00, 0x00, 0x00  // SW revision
                         ])
        guard let msg = LWP3Message.parse(from: data) else {
            XCTFail("Failed to parse attached IO")
            return
        }
        if case .hubAttachedIO(let portID, _, let deviceType, _, _, _, _) = msg {
            XCTAssertEqual(portID, 2)
            XCTAssertEqual(deviceType, .technicColorSensor)
        } else {
            XCTFail("Expected hubAttachedIO, got \(msg)")
        }
    }

    func testParseDetachedIO() {
        let data = bytes([0x05, 0x00, 0x04, 0x01, 0x00]) // port B detached
        guard let msg = LWP3Message.parse(from: data) else {
            XCTFail("Failed to parse detached IO")
            return
        }
        if case .hubAttachedIO(let portID, let event, let deviceType, _, _, _, _) = msg {
            XCTAssertEqual(portID, 1)
            XCTAssertEqual(event, .detached)
            XCTAssertNil(deviceType)
        } else {
            XCTFail("Expected hubAttachedIO, got \(msg)")
        }
    }

    func testParseVirtualPortAttached() {
        // Virtual port attached: port=6, event=2(virtual), type=spikeLargeMotor, portA=0, portB=1
        let data = bytes([0x09, 0x00, 0x04,
                          0x06,                   // virtual port 6
                          0x02,                   // event = attachedVirtual
                          0x31, 0x00,             // device type 49 (LE)
                          0x00,                   // port ID A
                          0x01                    // port ID B
                         ])
        guard let msg = LWP3Message.parse(from: data) else {
            XCTFail("Failed to parse virtual port")
            return
        }
        if case .hubAttachedIO(let portID, let event, let deviceType, _, _, let portIDA, let portIDB) = msg {
            XCTAssertEqual(portID, 6)
            XCTAssertEqual(event, .attachedVirtual)
            XCTAssertEqual(deviceType, .spikeLargeMotor)
            XCTAssertEqual(portIDA, 0)
            XCTAssertEqual(portIDB, 1)
        } else {
            XCTFail("Expected hubAttachedIO, got \(msg)")
        }
    }

    // MARK: - Message Parser: Port Value

    func testParsePortValueSingle() {
        // Port value: port=0, 4 bytes of sensor data
        let data = bytes([0x08, 0x00, 0x45, 0x00, 0x10, 0x20, 0x30, 0x40])
        guard let msg = LWP3Message.parse(from: data) else {
            XCTFail("Failed to parse port value")
            return
        }
        if case .portValueSingle(let portID, let value) = msg {
            XCTAssertEqual(portID, 0)
            XCTAssertEqual(value.count, 4)
        } else {
            XCTFail("Expected portValueSingle, got \(msg)")
        }
    }

    // MARK: - Message Parser: Port Input Format

    func testParsePortInputFormatSingle() {
        // port=0, mode=0, delta=1(LE 4 bytes), notification=1
        let data = bytes([0x0A, 0x00, 0x47,
                          0x00,                   // port
                          0x00,                   // mode
                          0x01, 0x00, 0x00, 0x00, // delta interval (LE)
                          0x01                    // notification enabled
                         ])
        guard let msg = LWP3Message.parse(from: data) else {
            XCTFail("Failed to parse port input format")
            return
        }
        if case .portInputFormatSingle(let portID, let mode, let deltaInterval, let notify) = msg {
            XCTAssertEqual(portID, 0)
            XCTAssertEqual(mode, 0)
            XCTAssertEqual(deltaInterval, 1)
            XCTAssertTrue(notify)
        } else {
            XCTFail("Expected portInputFormatSingle, got \(msg)")
        }
    }

    // MARK: - Message Parser: Port Output Command Feedback

    func testParsePortOutputFeedback() {
        let data = bytes([0x05, 0x00, 0x82, 0x00, 0x0A])
        guard let msg = LWP3Message.parse(from: data) else {
            XCTFail("Failed to parse feedback")
            return
        }
        if case .portOutputCommandFeedback(let portID, let feedback) = msg {
            XCTAssertEqual(portID, 0)
            XCTAssertEqual(feedback, 0x0A)
        } else {
            XCTFail("Expected portOutputCommandFeedback, got \(msg)")
        }
    }

    // MARK: - Message Parser: Generic Error

    func testParseGenericError() {
        let data = bytes([0x05, 0x00, 0x05, 0x81, 0x06])
        guard let msg = LWP3Message.parse(from: data) else {
            XCTFail("Failed to parse generic error")
            return
        }
        if case .genericError(let commandType, let errorCode) = msg {
            XCTAssertEqual(commandType, 0x81)
            XCTAssertEqual(errorCode, 0x06)
        } else {
            XCTFail("Expected genericError, got \(msg)")
        }
    }

    // MARK: - Message Parser: Unknown Type

    func testParseUnknownMessageType() {
        let data = bytes([0x05, 0x00, 0xFF, 0x01, 0x02])
        guard let msg = LWP3Message.parse(from: data) else {
            XCTFail("Should parse as unknown, not nil")
            return
        }
        if case .unknown(let messageType, let payload) = msg {
            XCTAssertEqual(messageType, 0xFF)
            XCTAssertEqual(payload.count, 2)
        } else {
            XCTFail("Expected unknown, got \(msg)")
        }
    }

    // MARK: - Message Parser: Edge Cases

    func testParseTooShort() {
        let data = bytes([0x02, 0x00])
        XCTAssertNil(LWP3Message.parse(from: data))
    }

    func testParseEmptyData() {
        XCTAssertNil(LWP3Message.parse(from: Data()))
    }

    // MARK: - Command Builder: Hub Properties

    func testBuildRequestBatteryVoltage() {
        let cmd = LWP3Command.requestHubProperty(.batteryVoltage)
        // Expected: [05, 00, 01, 06, 05]
        XCTAssertEqual(cmd.count, 5)
        XCTAssertEqual(cmd[0], 5)     // length
        XCTAssertEqual(cmd[1], 0x00)  // hub ID
        XCTAssertEqual(cmd[2], 0x01)  // message type: hubProperties
        XCTAssertEqual(cmd[3], 0x06)  // property: batteryVoltage
        XCTAssertEqual(cmd[4], 0x05)  // operation: requestUpdate
    }

    func testBuildEnableBatteryUpdates() {
        let cmd = LWP3Command.enableHubPropertyUpdates(.batteryVoltage)
        XCTAssertEqual(cmd.count, 5)
        XCTAssertEqual(cmd[2], 0x01)  // hubProperties
        XCTAssertEqual(cmd[3], 0x06)  // batteryVoltage
        XCTAssertEqual(cmd[4], 0x02)  // enableUpdates
    }

    func testBuildDisableBatteryUpdates() {
        let cmd = LWP3Command.disableHubPropertyUpdates(.batteryVoltage)
        XCTAssertEqual(cmd.count, 5)
        XCTAssertEqual(cmd[4], 0x03)  // disableUpdates
    }

    func testBuildSetHubProperty() {
        let cmd = LWP3Command.setHubProperty(.advertisingName, value: Data([0x48, 0x55, 0x42]))
        XCTAssertEqual(cmd[2], 0x01)  // hubProperties
        XCTAssertEqual(cmd[3], 0x01)  // advertisingName
        XCTAssertEqual(cmd[4], 0x01)  // set operation
        XCTAssertEqual(cmd[5], 0x48)  // 'H'
        XCTAssertEqual(cmd[6], 0x55)  // 'U'
        XCTAssertEqual(cmd[7], 0x42)  // 'B'
        XCTAssertEqual(cmd[0], UInt8(cmd.count)) // length byte matches
    }

    // MARK: - Command Builder: Hub Actions

    func testBuildHubActionDisconnect() {
        let cmd = LWP3Command.hubAction(.disconnect)
        XCTAssertEqual(cmd, bytes([0x04, 0x00, 0x02, 0x02]))
    }

    func testBuildHubActionSwitchOff() {
        let cmd = LWP3Command.hubAction(.switchOff)
        XCTAssertEqual(cmd, bytes([0x04, 0x00, 0x02, 0x01]))
    }

    // MARK: - Command Builder: Port Input Format

    func testBuildSetPortInputFormat() {
        let cmd = LWP3Command.setPortInputFormat(portID: 0, mode: 0, deltaInterval: 1, notificationEnabled: true)
        // Expected: [0A, 00, 41, 00, 00, 01, 00, 00, 00, 01]
        XCTAssertEqual(cmd.count, 10)
        XCTAssertEqual(cmd[0], 10)    // length
        XCTAssertEqual(cmd[2], 0x41)  // portInputFormatSetupSingle
        XCTAssertEqual(cmd[3], 0x00)  // portID
        XCTAssertEqual(cmd[4], 0x00)  // mode
        XCTAssertEqual(cmd[5], 0x01)  // delta interval byte 0
        XCTAssertEqual(cmd[6], 0x00)  // delta interval byte 1
        XCTAssertEqual(cmd[7], 0x00)  // delta interval byte 2
        XCTAssertEqual(cmd[8], 0x00)  // delta interval byte 3
        XCTAssertEqual(cmd[9], 0x01)  // notification enabled
    }

    func testBuildSetPortInputFormatNotificationDisabled() {
        let cmd = LWP3Command.setPortInputFormat(portID: 2, mode: 3, deltaInterval: 5, notificationEnabled: false)
        XCTAssertEqual(cmd[3], 0x02)  // portID = C
        XCTAssertEqual(cmd[4], 0x03)  // mode
        XCTAssertEqual(cmd[9], 0x00)  // notification disabled
    }

    // MARK: - Command Builder: Port Information Requests

    func testBuildRequestPortInformation() {
        let cmd = LWP3Command.requestPortInformation(portID: 0, informationType: 0x01)
        XCTAssertEqual(cmd.count, 5)
        XCTAssertEqual(cmd[2], 0x21)  // portInformationRequest
        XCTAssertEqual(cmd[3], 0x00)  // portID
        XCTAssertEqual(cmd[4], 0x01)  // informationType
    }

    func testBuildRequestPortModeInformation() {
        let cmd = LWP3Command.requestPortModeInformation(portID: 0, mode: 2, informationType: 0x03)
        XCTAssertEqual(cmd.count, 6)
        XCTAssertEqual(cmd[2], 0x22)  // portModeInformationRequest
        XCTAssertEqual(cmd[3], 0x00)  // portID
        XCTAssertEqual(cmd[4], 0x02)  // mode
        XCTAssertEqual(cmd[5], 0x03)  // informationType
    }

    // MARK: - Command Builder: Motor Commands

    func testBuildMotorStartPower() {
        let cmd = LWP3Command.motorStartPower(portID: 0, power: 50)
        XCTAssertEqual(cmd[2], 0x81)  // portOutputCommand
        XCTAssertEqual(cmd[3], 0x00)  // portID
        XCTAssertEqual(cmd[4], 0x11)  // startup + completion flags
        XCTAssertEqual(cmd[5], 0x01)  // subcommand: startPower
        XCTAssertEqual(cmd[6], 50)    // power
    }

    func testBuildMotorStartPowerNegative() {
        let cmd = LWP3Command.motorStartPower(portID: 1, power: -50)
        XCTAssertEqual(cmd[3], 0x01)  // port B
        XCTAssertEqual(cmd[6], UInt8(bitPattern: -50)) // signed as unsigned
    }

    func testBuildMotorStartSpeed() {
        let cmd = LWP3Command.motorStartSpeed(portID: 0, speed: 75, maxPower: 100, useProfile: 0)
        XCTAssertEqual(cmd[5], 0x07)  // subcommand: startSpeed
        XCTAssertEqual(cmd[6], 75)    // speed
        XCTAssertEqual(cmd[7], 100)   // maxPower
        XCTAssertEqual(cmd[8], 0x00)  // useProfile
    }

    func testBuildMotorStartSpeedForTime() {
        let cmd = LWP3Command.motorStartSpeedForTime(portID: 0, time: 1000, speed: 50,
                                                      maxPower: 100, endState: .brake, useProfile: 0)
        XCTAssertEqual(cmd[5], 0x09)  // subcommand: startSpeedForTime
        // time = 1000 = 0x03E8 in LE: [0xE8, 0x03]
        XCTAssertEqual(cmd[6], 0xE8)
        XCTAssertEqual(cmd[7], 0x03)
        XCTAssertEqual(cmd[8], 50)    // speed
        XCTAssertEqual(cmd[9], 100)   // maxPower
        XCTAssertEqual(cmd[10], LWP3MotorEndState.brake.rawValue) // 127
        XCTAssertEqual(cmd[11], 0x00) // useProfile
    }

    func testBuildMotorStartSpeedForDegrees() {
        let cmd = LWP3Command.motorStartSpeedForDegrees(portID: 0, degrees: 360, speed: 50,
                                                         maxPower: 100, endState: .hold, useProfile: 0)
        XCTAssertEqual(cmd[5], 0x0B)  // subcommand: startSpeedForDegrees
        // degrees = 360 = 0x00000168 in LE: [0x68, 0x01, 0x00, 0x00]
        XCTAssertEqual(cmd[6], 0x68)
        XCTAssertEqual(cmd[7], 0x01)
        XCTAssertEqual(cmd[8], 0x00)
        XCTAssertEqual(cmd[9], 0x00)
        XCTAssertEqual(cmd[10], 50)   // speed
        XCTAssertEqual(cmd[11], 100)  // maxPower
        XCTAssertEqual(cmd[12], LWP3MotorEndState.hold.rawValue) // 126
    }

    func testBuildMotorGotoAbsolutePosition() {
        let cmd = LWP3Command.motorGotoAbsolutePosition(portID: 0, position: -180, speed: 50,
                                                         maxPower: 100, endState: .brake, useProfile: 0)
        XCTAssertEqual(cmd[5], 0x0D)  // subcommand: gotoAbsolutePosition
        // position = -180 as Int32 LE
        let expected = UInt32(bitPattern: Int32(-180))
        XCTAssertEqual(cmd[6], UInt8(expected & 0xFF))
        XCTAssertEqual(cmd[7], UInt8((expected >> 8) & 0xFF))
        XCTAssertEqual(cmd[8], UInt8((expected >> 16) & 0xFF))
        XCTAssertEqual(cmd[9], UInt8((expected >> 24) & 0xFF))
    }

    func testBuildMotorBrake() {
        let cmd = LWP3Command.motorBrake(portID: 0)
        XCTAssertEqual(cmd[5], 0x01)  // subcommand: startPower
        XCTAssertEqual(cmd[6], 127)   // brake = 127
    }

    func testBuildMotorFloat() {
        let cmd = LWP3Command.motorFloat(portID: 0)
        XCTAssertEqual(cmd[5], 0x01)  // subcommand: startPower
        XCTAssertEqual(cmd[6], 0)     // float = 0
    }

    // MARK: - Command Builder: LED Commands

    func testBuildSetHubLEDColor() {
        let cmd = LWP3Command.setHubLEDColor(portID: 50, colorIndex: 5)
        XCTAssertEqual(cmd[3], 50)    // portID (hub RGB light port)
        XCTAssertEqual(cmd[5], 0x51)  // subcommand: writeDirectModeData
        XCTAssertEqual(cmd[6], 0x00)  // mode 0 = color index
        XCTAssertEqual(cmd[7], 5)     // color index
    }

    func testBuildSetHubLEDRGB() {
        let cmd = LWP3Command.setHubLEDRGB(portID: 50, red: 255, green: 128, blue: 0)
        XCTAssertEqual(cmd[5], 0x51)  // subcommand: writeDirectModeData
        XCTAssertEqual(cmd[6], 0x01)  // mode 1 = RGB
        XCTAssertEqual(cmd[7], 255)   // red
        XCTAssertEqual(cmd[8], 128)   // green
        XCTAssertEqual(cmd[9], 0)     // blue
    }

    // MARK: - Command Builder: Virtual Ports

    func testBuildCreateVirtualPort() {
        let cmd = LWP3Command.createVirtualPort(portIDA: 0, portIDB: 1)
        XCTAssertEqual(cmd[2], 0x61)  // virtualPortSetup
        XCTAssertEqual(cmd[3], 0x01)  // connect sub-command
        XCTAssertEqual(cmd[4], 0x00)  // port A
        XCTAssertEqual(cmd[5], 0x01)  // port B
    }

    func testBuildDeleteVirtualPort() {
        let cmd = LWP3Command.deleteVirtualPort(portID: 6)
        XCTAssertEqual(cmd[2], 0x61)  // virtualPortSetup
        XCTAssertEqual(cmd[3], 0x00)  // disconnect sub-command
        XCTAssertEqual(cmd[4], 6)     // virtual port ID
    }

    // MARK: - Command Builder: Length Byte

    func testAllCommandsHaveCorrectLength() {
        let commands: [Data] = [
            LWP3Command.requestHubProperty(.batteryVoltage),
            LWP3Command.enableHubPropertyUpdates(.batteryVoltage),
            LWP3Command.disableHubPropertyUpdates(.rssi),
            LWP3Command.hubAction(.disconnect),
            LWP3Command.setPortInputFormat(portID: 0, mode: 0, deltaInterval: 1, notificationEnabled: true),
            LWP3Command.requestPortInformation(portID: 0, informationType: 1),
            LWP3Command.requestPortModeInformation(portID: 0, mode: 0, informationType: 0),
            LWP3Command.motorStartPower(portID: 0, power: 50),
            LWP3Command.motorStartSpeed(portID: 0, speed: 50),
            LWP3Command.motorStartSpeedForTime(portID: 0, time: 1000, speed: 50),
            LWP3Command.motorStartSpeedForDegrees(portID: 0, degrees: 360, speed: 50),
            LWP3Command.motorGotoAbsolutePosition(portID: 0, position: 0, speed: 50),
            LWP3Command.motorBrake(portID: 0),
            LWP3Command.motorFloat(portID: 0),
            LWP3Command.setHubLEDColor(portID: 50, colorIndex: 3),
            LWP3Command.setHubLEDRGB(portID: 50, red: 0, green: 0, blue: 0),
            LWP3Command.createVirtualPort(portIDA: 0, portIDB: 1),
            LWP3Command.deleteVirtualPort(portID: 6),
        ]

        for cmd in commands {
            XCTAssertEqual(Int(cmd[0]), cmd.count,
                           "Length byte mismatch for command starting with 0x\(String(format: "%02X", cmd[2]))")
        }
    }

    // MARK: - Round-Trip Tests

    func testRoundTripHubProperty() {
        let cmd = LWP3Command.requestHubProperty(.batteryVoltage)
        let msg = LWP3Message.parse(from: cmd)
        XCTAssertNotNil(msg)
        if case .hubProperty(let prop, let op, _) = msg! {
            XCTAssertEqual(prop, .batteryVoltage)
            XCTAssertEqual(op, .requestUpdate)
        } else {
            XCTFail("Round-trip failed: expected hubProperty, got \(msg!)")
        }
    }

    func testRoundTripHubAction() {
        let cmd = LWP3Command.hubAction(.disconnect)
        let msg = LWP3Message.parse(from: cmd)
        XCTAssertNotNil(msg)
        if case .hubAction(let action) = msg! {
            XCTAssertEqual(action, .disconnect)
        } else {
            XCTFail("Round-trip failed: expected hubAction, got \(msg!)")
        }
    }

    // MARK: - Type Enums

    func testIODeviceTypeDisplayName() {
        XCTAssertEqual(LWP3IODeviceType.spikeLargeMotor.displayName, "SPIKE Large Motor")
        XCTAssertEqual(LWP3IODeviceType.technicColorSensor.displayName, "Technic Color Sensor")
        XCTAssertEqual(LWP3IODeviceType.hubRGBLight.displayName, "Hub RGB Light")
    }

    func testIODeviceTypeCategory() {
        XCTAssertEqual(LWP3IODeviceType.spikeLargeMotor.category, .motor)
        XCTAssertEqual(LWP3IODeviceType.technicColorSensor.category, .sensor)
        XCTAssertEqual(LWP3IODeviceType.hubRGBLight.category, .light)
        XCTAssertEqual(LWP3IODeviceType.hubIMUAccelerometer.category, .hubInternal)
        XCTAssertEqual(LWP3IODeviceType.hubBatteryVoltage.category, .hubInternal)
    }

    func testPortIDDisplayName() {
        XCTAssertEqual(LWP3PortID(value: 0).displayName, "A")
        XCTAssertEqual(LWP3PortID(value: 1).displayName, "B")
        XCTAssertEqual(LWP3PortID(value: 5).displayName, "F")
        XCTAssertEqual(LWP3PortID(value: 10).displayName, "Port(10)")
    }

    func testFeedbackStatusOptionSet() {
        let status: LWP3FeedbackStatus = [.bufferEmpty, .commandCompleted]
        XCTAssertTrue(status.contains(.bufferEmpty))
        XCTAssertTrue(status.contains(.commandCompleted))
        XCTAssertFalse(status.contains(.commandInProgress))
    }

    // MARK: - Data Extension Helpers

    func testDataUInt16LE() {
        let data = bytes([0xE8, 0x03])
        XCTAssertEqual(data.lwp3_uint16LE(at: 0), 1000)
    }

    func testDataUInt32LE() {
        let data = bytes([0x68, 0x01, 0x00, 0x00])
        XCTAssertEqual(data.lwp3_uint32LE(at: 0), 360)
    }

    func testDataInt8() {
        let data = bytes([0xCE]) // -50 as signed
        XCTAssertEqual(data.lwp3_int8(at: 0), -50)
    }

    func testDataInt16LE() {
        let data = bytes([0x4C, 0xFF]) // -180 as LE Int16
        XCTAssertEqual(data.lwp3_int16LE(at: 0), -180)
    }

    func testDataInt32LE() {
        let data = bytes([0x4C, 0xFF, 0xFF, 0xFF]) // -180 as LE Int32
        XCTAssertEqual(data.lwp3_int32LE(at: 0), -180)
    }

    func testDataReadBeyondBounds() {
        let data = bytes([0x01])
        XCTAssertNil(data.lwp3_uint16LE(at: 0))
        XCTAssertNil(data.lwp3_uint32LE(at: 0))
        XCTAssertNil(data.lwp3_int8(at: 1))
    }

    // MARK: - Message Description

    func testMessageDescription() {
        let data = bytes([0x05, 0x00, 0x04, 0x01, 0x00])
        guard let msg = LWP3Message.parse(from: data) else {
            XCTFail("Failed to parse")
            return
        }
        let desc = msg.description
        XCTAssertTrue(desc.contains("Detached"))
        XCTAssertTrue(desc.contains("B"))
    }
}

// Equatable conformance needed for DeviceCategory assertions
extension DeviceCategory: Equatable {}

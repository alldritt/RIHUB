//
//  LWP3Types.swift
//  RobotInventorHUB
//
//  LEGO Wireless Protocol 3.0 enums and constants.
//  Pure Swift — no UIKit/AppKit/CoreBluetooth dependencies.
//

import Foundation

// MARK: - Message Types

enum LWP3MessageType: UInt8, CaseIterable {
    case hubProperties              = 0x01
    case hubActions                 = 0x02
    case hubAlerts                  = 0x03
    case hubAttachedIO              = 0x04
    case genericError               = 0x05
    case portInformationRequest     = 0x21
    case portModeInformationRequest = 0x22
    case portInputFormatSetupSingle   = 0x41
    case portInputFormatSetupCombined = 0x42
    case portInformation            = 0x43
    case portModeInformation        = 0x44
    case portValueSingle            = 0x45
    case portValueCombined          = 0x46
    case portInputFormatSingle      = 0x47
    case portInputFormatCombined    = 0x48
    case virtualPortSetup           = 0x61
    case portOutputCommand          = 0x81
    case portOutputCommandFeedback  = 0x82
}

// MARK: - IO Device Types

enum DeviceCategory {
    case motor
    case sensor
    case light
    case hubInternal
    case unknown
}

enum LWP3IODeviceType: UInt16, CaseIterable {
    // Motors
    case poweredUpMediumMotor          = 1
    case trainMotor                    = 2
    case poweredUpLights               = 8
    case boostInteractiveMotor         = 38
    case spikeMediumMotor              = 48
    case spikeLargeMotor               = 49
    case technicSmallAngularMotor      = 65
    case technicMediumAngularMotorGray = 75
    case technicLargeAngularMotorGray  = 76

    // Sensors
    case boostColorDistance            = 37
    case technicColorSensor            = 61
    case technicDistanceSensor         = 62
    case technicForceSensor            = 63

    // Hub internals — IMU
    case hubIMUGesture                 = 54
    case hubIMUAccelerometer           = 57
    case hubIMUGyro                    = 58
    case hubIMUPosition                = 59
    case hubIMUTemperature             = 60
    case hubIMUOrientation             = 93

    // Hub system
    case hubBatteryVoltage             = 20
    case hubBatteryCurrent             = 21
    case hubPiezoTone                  = 22
    case hubRGBLight                   = 23
    case hubBluetoothRSSI              = 56
    case technicColorLightMatrix       = 64

    var displayName: String {
        switch self {
        case .poweredUpMediumMotor:          return "Powered Up Medium Motor"
        case .trainMotor:                    return "Train Motor"
        case .poweredUpLights:               return "Powered Up Lights"
        case .boostInteractiveMotor:         return "BOOST Interactive Motor"
        case .spikeMediumMotor:              return "SPIKE Medium Motor"
        case .spikeLargeMotor:               return "SPIKE Large Motor"
        case .technicSmallAngularMotor:      return "Technic Small Angular Motor"
        case .technicMediumAngularMotorGray: return "Technic Medium Angular Motor (Gray)"
        case .technicLargeAngularMotorGray:  return "Technic Large Angular Motor (Gray)"
        case .boostColorDistance:            return "BOOST Color & Distance Sensor"
        case .technicColorSensor:            return "Technic Color Sensor"
        case .technicDistanceSensor:         return "Technic Distance Sensor"
        case .technicForceSensor:            return "Technic Force Sensor"
        case .hubIMUGesture:                 return "Hub IMU Gesture"
        case .hubIMUAccelerometer:           return "Hub IMU Accelerometer"
        case .hubIMUGyro:                    return "Hub IMU Gyro"
        case .hubIMUPosition:                return "Hub IMU Position"
        case .hubIMUTemperature:             return "Hub IMU Temperature"
        case .hubIMUOrientation:             return "Hub IMU Orientation"
        case .hubBatteryVoltage:             return "Hub Battery Voltage"
        case .hubBatteryCurrent:             return "Hub Battery Current"
        case .hubPiezoTone:                  return "Hub Piezo Tone"
        case .hubRGBLight:                   return "Hub RGB Light"
        case .hubBluetoothRSSI:              return "Hub Bluetooth RSSI"
        case .technicColorLightMatrix:       return "Technic Color Light Matrix"
        }
    }

    var category: DeviceCategory {
        switch self {
        case .poweredUpMediumMotor, .trainMotor, .boostInteractiveMotor,
             .spikeMediumMotor, .spikeLargeMotor, .technicSmallAngularMotor,
             .technicMediumAngularMotorGray, .technicLargeAngularMotorGray:
            return .motor
        case .boostColorDistance, .technicColorSensor, .technicDistanceSensor,
             .technicForceSensor:
            return .sensor
        case .poweredUpLights, .hubRGBLight, .technicColorLightMatrix:
            return .light
        case .hubIMUGesture, .hubIMUAccelerometer, .hubIMUGyro, .hubIMUPosition,
             .hubIMUTemperature, .hubIMUOrientation, .hubBatteryVoltage,
             .hubBatteryCurrent, .hubPiezoTone, .hubBluetoothRSSI:
            return .hubInternal
        }
    }
}

// MARK: - Hub Property

enum LWP3HubProperty: UInt8 {
    case advertisingName   = 0x01
    case button            = 0x02
    case fwVersion         = 0x03
    case hwVersion         = 0x04
    case rssi              = 0x05
    case batteryVoltage    = 0x06
    case batteryType       = 0x07
    case manufacturerName  = 0x08
    case radioFWVersion    = 0x09
    case lwpVersion        = 0x0A
    case systemTypeID      = 0x0B
    case hwNetworkID       = 0x0C
    case primaryMAC        = 0x0D
    case secondaryMAC      = 0x0E
    case hwNetworkFamily   = 0x0F
}

// MARK: - Hub Property Operation

enum LWP3HubPropertyOperation: UInt8 {
    case set            = 1
    case enableUpdates  = 2
    case disableUpdates = 3
    case reset          = 4
    case requestUpdate  = 5
    case update         = 6
}

// MARK: - Hub Action

enum LWP3HubActionType: UInt8 {
    case switchOff           = 0x01
    case disconnect          = 0x02
    case startVirtualPowerOff = 0x03
    case resetAfterBoot      = 0x04
    case willSwitchOff       = 0x30
    case willDisconnect      = 0x31
    case willGoIntoBoot      = 0x32
}

// MARK: - IO Event

enum LWP3IOEvent: UInt8 {
    case detached        = 0
    case attached        = 1
    case attachedVirtual = 2
}

// MARK: - Port Output Sub-Commands

enum LWP3PortOutputSubCommand: UInt8 {
    case startPower             = 0x01
    case startSpeed             = 0x07
    case startSpeedForTime      = 0x09
    case startSpeedForDegrees   = 0x0B
    case gotoAbsolutePosition   = 0x0D
    case writeDirectModeData    = 0x51
}

// MARK: - Motor End State

enum LWP3MotorEndState: UInt8 {
    case float = 0
    case hold  = 126
    case brake = 127
}

// MARK: - Feedback Status

struct LWP3FeedbackStatus: OptionSet {
    let rawValue: UInt8

    static let bufferEmpty    = LWP3FeedbackStatus(rawValue: 1 << 0)
    static let commandInProgress = LWP3FeedbackStatus(rawValue: 1 << 1)
    static let commandCompleted  = LWP3FeedbackStatus(rawValue: 1 << 2)
    static let commandDiscarded  = LWP3FeedbackStatus(rawValue: 1 << 3)
    static let idle              = LWP3FeedbackStatus(rawValue: 1 << 4)
    static let busyFull          = LWP3FeedbackStatus(rawValue: 1 << 5)
}

// MARK: - Port ID

struct LWP3PortID {
    let value: UInt8

    var displayName: String {
        switch value {
        case 0: return "A"
        case 1: return "B"
        case 2: return "C"
        case 3: return "D"
        case 4: return "E"
        case 5: return "F"
        default: return "Port(\(value))"
        }
    }
}

// MARK: - Hub Alert

enum LWP3HubAlertType: UInt8 {
    case lowVoltage       = 0x01
    case highCurrent      = 0x02
    case lowSignalStrength = 0x03
    case overPowerCondition = 0x04
}

enum LWP3HubAlertOperation: UInt8 {
    case enableUpdates  = 0x01
    case disableUpdates = 0x02
    case requestUpdate  = 0x03
    case update         = 0x04
}

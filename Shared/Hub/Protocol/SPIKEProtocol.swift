//
//  SPIKEProtocol.swift
//  RobotInventorHUB
//
//  SPIKE Prime BLE protocol: COBS encoding/decoding + message types.
//  Reference: https://lego.github.io/spike-prime-docs/
//

import Foundation


// MARK: - COBS Encoding/Decoding

/// SPIKE Prime variant of Consistent Overhead Byte Stuffing.
/// Escapes bytes 0x00, 0x01, 0x02; XORs with 0x03; frames with 0x02 delimiter.
struct SPIKECOBS {

    private static let delimiter: UInt8 = 0x02
    private static let noDelimiter: UInt8 = 0xFF
    private static let cobsCodeOffset: UInt8 = 0x02
    private static let maxBlockSize = 84
    private static let xorByte: UInt8 = 0x03

    /// COBS-encode raw bytes (without XOR or framing).
    static func encode(_ data: Data) -> Data {
        var buffer = Data()
        var codeIndex = 0
        var block = 0

        func beginBlock() {
            codeIndex = buffer.count
            buffer.append(noDelimiter)
            block = 1
        }

        beginBlock()

        for byte in data {
            if byte > delimiter {
                buffer.append(byte)
                block += 1
            }

            if byte <= delimiter || block > maxBlockSize {
                if byte <= delimiter {
                    let delimiterBase = Int(byte) * maxBlockSize
                    let blockOffset = block + Int(cobsCodeOffset)
                    buffer[codeIndex] = UInt8(delimiterBase + blockOffset)
                }
                beginBlock()
            }
        }

        buffer[codeIndex] = UInt8(block + Int(cobsCodeOffset))
        return buffer
    }

    /// COBS-decode bytes (after XOR has been reversed, without framing).
    static func decode(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }

        var buffer = Data()

        func unescape(_ code: UInt8) -> (value: UInt8?, block: Int) {
            if code == 0xFF {
                return (nil, maxBlockSize + 1)
            }
            let adjusted = Int(code) - Int(cobsCodeOffset)
            var (value, block) = adjusted.quotientAndRemainder(dividingBy: maxBlockSize)
            if block == 0 {
                block = maxBlockSize
                value -= 1
            }
            return (UInt8(value), block)
        }

        var (value, block) = unescape(data[0])

        for i in 1..<data.count {
            let byte = data[i]
            block -= 1
            if block > 0 {
                buffer.append(byte)
                continue
            }

            if let v = value {
                buffer.append(v)
            }

            (value, block) = unescape(byte)
        }

        return buffer
    }

    /// Encode a message: COBS encode → XOR → append 0x02 frame delimiter.
    static func pack(_ data: Data) -> Data {
        var encoded = encode(data)
        for i in 0..<encoded.count {
            encoded[i] ^= xorByte
        }
        encoded.append(delimiter)
        return encoded
    }

    /// Decode a framed message: strip frame → XOR → COBS decode.
    static func unpack(_ frame: Data) -> Data {
        guard !frame.isEmpty else { return Data() }

        var start = 0
        if frame[0] == 0x01 { // high-priority prefix
            start += 1
        }
        // Strip trailing 0x02 delimiter
        let end = frame.count - 1

        guard end > start else { return Data() }

        var unframed = Data(frame[start..<end])
        for i in 0..<unframed.count {
            unframed[i] ^= xorByte
        }
        return decode(unframed)
    }
}


// MARK: - SPIKE Prime Message Types

/// Parsed InfoResponse from the hub.
struct SPIKEInfoResponse {
    let rpcMajor: UInt8
    let rpcMinor: UInt8
    let rpcBuild: UInt16
    let firmwareMajor: UInt8
    let firmwareMinor: UInt8
    let firmwareBuild: UInt16
    let maxPacketSize: UInt16
    let maxMessageSize: UInt16
    let maxChunkSize: UInt16
    let productGroupDevice: UInt16

    /// Parse from raw (COBS-decoded) message bytes.
    static func parse(from data: Data) -> SPIKEInfoResponse? {
        // Format: <BBBHBBHHHHH  = 1+1+1+2+1+1+2+2+2+2+2 = 17 bytes
        guard data.count >= 17, data[0] == 0x01 else { return nil }
        return SPIKEInfoResponse(
            rpcMajor: data[1],
            rpcMinor: data[2],
            rpcBuild: data.uint16LE(at: 3),
            firmwareMajor: data[5],
            firmwareMinor: data[6],
            firmwareBuild: data.uint16LE(at: 7),
            maxPacketSize: data.uint16LE(at: 9),
            maxMessageSize: data.uint16LE(at: 11),
            maxChunkSize: data.uint16LE(at: 13),
            productGroupDevice: data.uint16LE(at: 15)
        )
    }
}

/// Parsed DeviceNotification containing sub-messages for battery, motor, etc.
struct SPIKEDeviceNotification {

    struct Battery {
        let level: UInt8    // percentage
    }

    struct Motor {
        let port: UInt8
        let deviceType: UInt8
        let absolutePosition: Int16
        let power: Int16
        let speed: Int8
        let position: Int32
    }

    struct Distance {
        let port: UInt8
        let distanceMM: Int16   // -1 when nothing detected
    }

    struct Color {
        let port: UInt8
        let colorID: Int8       // -1 when nothing detected
        let red: UInt16
        let green: UInt16
        let blue: UInt16
    }

    struct Force {
        let port: UInt8
        let force: UInt8
        let pressed: UInt8
    }

    struct LightMatrix {
        let port: UInt8
        let pixels: [UInt8]  // 9 brightness values (0–100), row-major 3x3
    }

    let battery: Battery?
    let motors: [Motor]
    let distances: [Distance]
    let colors: [Color]
    let forces: [Force]
    let lightMatrices: [LightMatrix]

    /// Parse from raw (COBS-decoded) message bytes.
    static func parse(from data: Data) -> SPIKEDeviceNotification? {
        guard data.count >= 3, data[0] == 0x3C else { return nil }
        let payloadSize = Int(data.uint16LE(at: 1))
        let payload = data.dropFirst(3)
        guard payload.count >= payloadSize else { return nil }

        var battery: Battery? = nil
        var motors: [Motor] = []
        var distances: [Distance] = []
        var colors: [Color] = []
        var forces: [Force] = []
        var lightMatrices: [LightMatrix] = []

        var offset = payload.startIndex
        while offset < payload.endIndex {
            let msgID = payload[offset]
            switch msgID {
            case 0x00: // Battery: <BB = 2 bytes
                guard offset + 2 <= payload.endIndex else { break }
                battery = Battery(level: payload[offset + 1])
                offset += 2

            case 0x0A: // Motor: <BBBhhbi = 1+1+1+2+2+1+4 = 12 bytes
                guard offset + 12 <= payload.endIndex else { break }
                let d = Data(payload[offset..<offset+12])
                motors.append(Motor(
                    port: d[1],
                    deviceType: d[2],
                    absolutePosition: d.int16LE(at: 3),
                    power: d.int16LE(at: 5),
                    speed: Int8(bitPattern: d[7]),
                    position: d.int32LE(at: 8)
                ))
                offset += 12

            case 0x0D: // Distance sensor: <BBh = 1+1+2 = 4 bytes
                guard offset + 4 <= payload.endIndex else { break }
                let d = Data(payload[offset..<offset+4])
                distances.append(Distance(
                    port: d[1],
                    distanceMM: d.int16LE(at: 2)
                ))
                offset += 4

            case 0x0C: // Color sensor: <BBbHHH = 1+1+1+2+2+2 = 9 bytes
                guard offset + 9 <= payload.endIndex else { break }
                let d = Data(payload[offset..<offset+9])
                colors.append(Color(
                    port: d[1],
                    colorID: Int8(bitPattern: d[2]),
                    red: d.uint16LE(at: 3),
                    green: d.uint16LE(at: 5),
                    blue: d.uint16LE(at: 7)
                ))
                offset += 9

            case 0x0B: // Force sensor: <BBBB = 4 bytes
                guard offset + 4 <= payload.endIndex else { break }
                let d = Data(payload[offset..<offset+4])
                forces.append(Force(
                    port: d[1],
                    force: d[2],
                    pressed: d[3]
                ))
                offset += 4

            case 0x01: // IMU: <BBBhhhhhhhhh = 1+1+1+2*9 = 21 bytes
                guard offset + 21 <= payload.endIndex else { break }
                offset += 21

            case 0x02: // 5x5 display: <B25B = 26 bytes
                guard offset + 26 <= payload.endIndex else { break }
                offset += 26

            case 0x0E: // 3x3 light matrix: <BB9B = 11 bytes
                guard offset + 11 <= payload.endIndex else { break }
                let d = Data(payload[offset..<offset+11])
                lightMatrices.append(LightMatrix(
                    port: d[1],
                    pixels: Array(d[2..<11])
                ))
                offset += 11

            default:
                // Unknown sub-message — can't continue parsing
                return SPIKEDeviceNotification(battery: battery, motors: motors, distances: distances, colors: colors, forces: forces, lightMatrices: lightMatrices)
            }
        }

        return SPIKEDeviceNotification(battery: battery, motors: motors, distances: distances, colors: colors, forces: forces, lightMatrices: lightMatrices)
    }
}

/// Build outgoing SPIKE Prime protocol messages.
struct SPIKECommand {

    /// InfoRequest — single byte 0x00.
    static func infoRequest() -> Data {
        return Data([0x00])
    }

    /// DeviceNotificationRequest — enable periodic sensor/battery notifications.
    static func deviceNotificationRequest(intervalMS: UInt16) -> Data {
        var data = Data([0x28])
        data.appendUInt16LE(intervalMS)
        return data
    }

    /// ProgramFlowRequest — start or stop a program in a slot.
    static func programFlowRequest(stop: Bool, slot: UInt8) -> Data {
        return Data([0x1E, stop ? 1 : 0, slot])
    }

    /// ClearSlotRequest — clear a program slot.
    static func clearSlotRequest(slot: UInt8) -> Data {
        return Data([0x46, slot])
    }

    /// SetHubNameRequest.
    static func setHubNameRequest(_ name: String) -> Data {
        var data = Data([0x16])
        if let nameData = name.data(using: .utf8) {
            data.append(nameData)
        }
        data.append(0x00) // null terminator
        return data
    }

    /// GetHubNameRequest.
    static func getHubNameRequest() -> Data {
        return Data([0x18])
    }
}


// MARK: - Data Helpers

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func int16LE(at offset: Int) -> Int16 {
        return Int16(bitPattern: uint16LE(at: offset))
    }

    func int32LE(at offset: Int) -> Int32 {
        let u = UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
        return Int32(bitPattern: u)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }
}

//
//  ContentView.swift
//  Shared
//
//  Created by Mark Alldritt on 2021-02-09.
//

import SwiftUI
#if os(iOS)
import ExternalAccessory
#endif

extension View {
    var titleFont: Font {
        #if os(watchOS)
        return .headline
        #else
        return .title
        #endif
    }
    
    var chartLabelFont: Font {
        #if os(watchOS)
        return .system(size: 9)
        #else
        return .caption
        #endif
    }
}

struct FilledButton: View {
    var buttonWidth: CGFloat {
        #if os(watchOS)
        let w = WKInterfaceDevice.current().screenBounds.size.width
        #elseif os(iOS)
        let w = UIScreen.main.bounds.size.width
        #elseif os(macOS)
        let w = NSScreen.main?.frame.size.width ?? 800
        #endif

        return w * 0.8 // 80%
    }
    let title: String
    let action: () -> Void

    var body: some View {
        #if os(watchOS)
        Button(title, action: action)
        #else
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(width: buttonWidth * 0.8, height: 40)
                .foregroundColor(.white)
                .background(Color.accentColor)
                .cornerRadius(10)
        }
        #endif
    }
}

struct NoBluetoothView: View {
    var body: some View {
        Text("Bluetooth Not Available")
            .font(titleFont)
            .multilineTextAlignment(.center)
            .padding()
            .transition(.opacity)
    }
}

struct BluetoothPoweredOffView: View {
    var body: some View {
        Group() {
            VStack() {
                Text("Bluetooth Is Turned Off.  Please turn Bluetooth on to connect to your Robot Inventor hub.")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding()
                FilledButton(title: "Settings", action: {
                    print("Goto settings...")
                })
            }
        }
        .transition(.opacity)
    }
}

struct BluetoothUnauthorizedView: View {
    var body: some View {
        Group() {
            VStack() {
                Text("Bluetooth Access Is Not Authorized.  Please authrorize Robot Inventor HUB to use Bluetooth to connect to your Robot Inventor hub.")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding()
                FilledButton(title: "Settings", action: {
                    print("Goto settings...")
                })
            }
        }
        .transition(.opacity)
    }
}

struct ConnectedView: View {

    private let hub: RIHub
    @State private var snapshot: RIHub.DeviceDataSnapshot?
    @State private var batteryLevel: Int?

    init(_ hub: RIHub) {
        self.hub = hub
    }

    var body: some View {
        let snap = snapshot ?? hub.deviceDataSnapshot()
        let ports = snap.activePorts

        VStack(spacing: 0) {
            // Header: hub name + battery
            HStack {
                Text(hub.deviceName)
                    .font(.headline)
                Spacer()
                if let level = batteryLevel ?? hub.batteryLevel {
                    BatteryIndicator(level: level)
                }
            }
            .padding()

            Divider()

            // Hub state section (IMU, display, gesture)
            if snap.hubOrientation != nil || snap.hubDisplay != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let orient = snap.hubOrientation {
                        OrientationRowView(orientation: orient)
                    }
                    if let accel = snap.hubAccelerometer, let gyro = snap.hubGyroscope {
                        IMURowView(accelerometer: accel, gyroscope: gyro)
                    }
                    if let display = snap.hubDisplay, !display.pixels.isEmpty {
                        HubDisplayView(display: display)
                    }
                    if let gesture = snap.hubGesture, gesture.code > 0 {
                        GestureRowView(gesture: gesture)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                Divider()
            }

            // Per-port device rows
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ports, id: \.self) { port in
                        PortRowView(snapshot: snap, port: port, hub: hub)
                    }
                    if ports.isEmpty {
                        Text("No devices attached")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            Divider()

            // Disconnect button
            FilledButton(title: "Disconnect") {
                hub.disconnect()
            }
            .padding()
        }
        .onReceive(NotificationCenter.default
            .publisher(for: RIHub.DeviceDataChangedNotification, object: hub)) { _ in
            snapshot = hub.deviceDataSnapshot()
            batteryLevel = hub.batteryLevel
        }
        .onReceive(NotificationCenter.default
            .publisher(for: RIHub.AttachedDevicesChangedNotification, object: hub)) { _ in
            snapshot = hub.deviceDataSnapshot()
            batteryLevel = hub.batteryLevel
        }
        .onReceive(NotificationCenter.default
            .publisher(for: RIHub.BatteryChangeNotification, object: hub)) { _ in
            batteryLevel = hub.batteryLevel
        }
    }
}

// MARK: - Battery Indicator

struct BatteryIndicator: View {
    let level: Int

    private var color: Color {
        if level > 50 { return .green }
        if level > 20 { return .yellow }
        return .red
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("\(level)%")
                .font(.system(.subheadline, design: .monospaced))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary, lineWidth: 1)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: max(0, geo.size.width * CGFloat(level) / 100.0))
                }
            }
            .frame(width: 30, height: 12)
        }
    }
}

// MARK: - Per-Port Row

struct PortRowView: View {
    let snapshot: RIHub.DeviceDataSnapshot
    let port: UInt8
    let hub: RIHub?

    private var hasSPIKEData: Bool {
        snapshot.motors[port] != nil || snapshot.distances[port] != nil ||
        snapshot.colors[port] != nil || snapshot.forces[port] != nil ||
        snapshot.lightMatrices[port] != nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Port \(RIHub.portLetter(port))")
                .font(.subheadline.bold())
                .frame(width: 52, alignment: .leading)

            if let motor = snapshot.motors[port] {
                MotorRowView(motor: motor, hub: hub)
            }
            if let dist = snapshot.distances[port] {
                DistanceRowView(distance: dist)
            }
            if let color = snapshot.colors[port] {
                ColorRowView(color: color)
            }
            if let force = snapshot.forces[port] {
                ForceRowView(force: force)
            }
            if let light = snapshot.lightMatrices[port] {
                LightMatrixRowView(light: light)
            }

            // LWP3 device — show type name when no SPIKE telemetry
            if !hasSPIKEData, let rawType = snapshot.lwp3Devices[port] {
                LWP3DeviceRowView(rawType: rawType, portValue: snapshot.lwp3PortValues[port],
                                  port: port, hub: hub)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Device Type Views

struct MotorRowView: View {
    let motor: SPIKEDeviceNotification.Motor
    let hub: RIHub?

    @State private var sliderSpeed: Double = 0

    /// Simple motors (type 1, 2) have no position encoder.
    private var hasPosition: Bool {
        motor.deviceType != 1 && motor.deviceType != 2
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Motor")
                .foregroundColor(.secondary)
                .font(.subheadline)
            Text("spd:\(motor.speed)")
                .font(.system(.subheadline, design: .monospaced))
            if hasPosition {
                Text("pos:\(motor.position)")
                    .font(.system(.subheadline, design: .monospaced))
            }

            if let hub = hub, hub.canControlMotors {
                Slider(value: $sliderSpeed, in: -100...100, step: 1) {
                    Text("Speed")
                }
                .frame(minWidth: 100, maxWidth: 160)
                .onChange(of: sliderSpeed) { newValue in
                    let speed = Int8(clamping: Int(newValue))
                    hub.sendLWP3(LWP3Command.motorStartSpeed(portID: motor.port, speed: speed))
                }

                Button {
                    sliderSpeed = 0
                    hub.sendLWP3(LWP3Command.motorStartSpeed(portID: motor.port, speed: 0))
                } label: {
                    Text("Stop")
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct DistanceRowView: View {
    let distance: SPIKEDeviceNotification.Distance

    var body: some View {
        HStack(spacing: 6) {
            Text("Distance")
                .foregroundColor(.secondary)
                .font(.subheadline)
            if distance.distanceMM < 0 {
                Text("—")
                    .font(.subheadline)
            } else {
                Text("\(distance.distanceMM)mm")
                    .font(.system(.subheadline, design: .monospaced))
            }
        }
    }
}

struct ColorRowView: View {
    let color: SPIKEDeviceNotification.Color

    /// LEGO color ID → display name.
    private static let colorNames: [Int8: String] = [
        0: "Black", 1: "Pink", 2: "Purple", 3: "Blue",
        4: "Lt Blue", 5: "Cyan", 6: "Green", 7: "Yellow",
        8: "Orange", 9: "Red", 10: "White"
    ]

    /// LEGO color ID → swatch color (used when RGB values aren't available).
    private static let colorSwatches: [Int8: SwiftUI.Color] = [
        0: .black, 1: .pink, 2: .purple, 3: .blue,
        4: SwiftUI.Color(red: 0.4, green: 0.7, blue: 1.0),
        5: SwiftUI.Color(red: 0.0, green: 0.9, blue: 0.9), 6: .green, 7: .yellow,
        8: .orange, 9: .red, 10: .white
    ]

    private var swatchColor: SwiftUI.Color {
        // If we have real RGB data (SPIKE color sensor), use it
        if color.red > 0 || color.green > 0 || color.blue > 0 {
            let maxVal = max(Double(color.red), Double(color.green), Double(color.blue), 1)
            return SwiftUI.Color(
                red: Double(color.red) / maxVal,
                green: Double(color.green) / maxVal,
                blue: Double(color.blue) / maxVal
            )
        }
        // Otherwise use the color ID lookup
        return Self.colorSwatches[color.colorID] ?? .gray
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Color")
                .foregroundColor(.secondary)
                .font(.subheadline)
            Circle()
                .fill(swatchColor)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
            if color.colorID >= 0, let name = Self.colorNames[color.colorID] {
                Text(name)
                    .font(.system(.subheadline, design: .monospaced))
            } else {
                Text("—")
                    .font(.subheadline)
            }
        }
    }
}

struct ForceRowView: View {
    let force: SPIKEDeviceNotification.Force

    var body: some View {
        HStack(spacing: 6) {
            Text("Force")
                .foregroundColor(.secondary)
                .font(.subheadline)
            Text("\(force.force)")
                .font(.system(.subheadline, design: .monospaced))
            if force.pressed != 0 {
                Image(systemName: "hand.point.down.fill")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }
        }
    }
}

struct LightMatrixRowView: View {
    let light: SPIKEDeviceNotification.LightMatrix

    var body: some View {
        HStack(spacing: 6) {
            Text("Light")
                .foregroundColor(.secondary)
                .font(.subheadline)
            // 3x3 grid of brightness dots
            VStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { col in
                            let idx = row * 3 + col
                            let brightness = idx < light.pixels.count ? Double(light.pixels[idx]) / 100.0 : 0
                            Circle()
                                .fill(Color.white.opacity(brightness))
                                .frame(width: 6, height: 6)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Hub State Views

struct OrientationRowView: View {
    let orientation: SPIKEDeviceNotification.Orientation

    var body: some View {
        HStack(spacing: 12) {
            Label("Orientation", systemImage: "gyroscope")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .labelStyle(.iconOnly)
            Text("Yaw: \(orientation.yaw)\u{00B0}")
                .font(.system(.subheadline, design: .monospaced))
            Text("Pitch: \(orientation.pitch)\u{00B0}")
                .font(.system(.subheadline, design: .monospaced))
            Text("Roll: \(orientation.roll)\u{00B0}")
                .font(.system(.subheadline, design: .monospaced))
        }
    }
}

struct IMURowView: View {
    let accelerometer: SPIKEDeviceNotification.Accelerometer
    let gyroscope: SPIKEDeviceNotification.Gyroscope

    var body: some View {
        HStack(spacing: 12) {
            Text("Accel: \(accelerometer.x), \(accelerometer.y), \(accelerometer.z)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
            Text("Gyro: \(gyroscope.x), \(gyroscope.y), \(gyroscope.z)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

struct HubDisplayView: View {
    let display: SPIKEDeviceNotification.HubDisplay

    /// Parse the "XXXXX:XXXXX:XXXXX:XXXXX:XXXXX" string into a 5x5 brightness grid.
    private var rows: [[Int]] {
        display.pixels.split(separator: ":").map { row in
            row.compactMap { char in
                char.wholeNumberValue
            }
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Display")
                .foregroundColor(.secondary)
                .font(.subheadline)
            VStack(spacing: 1) {
                ForEach(0..<rows.count, id: \.self) { r in
                    HStack(spacing: 1) {
                        ForEach(0..<rows[r].count, id: \.self) { c in
                            let brightness = Double(rows[r][c]) / 9.0
                            Circle()
                                .fill(Color.white.opacity(brightness))
                                .frame(width: 5, height: 5)
                        }
                    }
                }
            }
        }
    }
}

struct GestureRowView: View {
    let gesture: SPIKEDeviceNotification.Gesture

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap.fill")
                .font(.subheadline)
                .foregroundColor(.yellow)
            Text(gesture.name)
                .font(.subheadline)
        }
    }
}

struct LWP3DeviceRowView: View {
    let rawType: UInt16
    let portValue: Data?
    let port: UInt8
    let hub: RIHub?

    @State private var sliderSpeed: Double = 0

    private var deviceType: LWP3IODeviceType? {
        LWP3IODeviceType(rawValue: rawType)
    }

    private var isControllable: Bool {
        let cat = deviceType?.category
        return cat == .motor || cat == .light
    }

    private var isMotor: Bool {
        deviceType?.category == .motor
    }

    private var icon: String {
        switch deviceType?.category {
        case .motor:       return "gearshape.fill"
        case .sensor:      return "sensor.fill"
        case .light:       return "lightbulb.fill"
        case .hubInternal: return "cpu"
        default:           return "puzzlepiece.fill"
        }
    }

    /// Interpret mode 0 value as a signed power/speed percentage.
    private var powerValue: Int8? {
        guard let data = portValue, !data.isEmpty else { return nil }
        return Int8(bitPattern: data[data.startIndex])
    }

    private var valueLabel: String {
        switch deviceType?.category {
        case .motor:  return "pwr"
        case .light:  return "pwr"
        default:      return "val"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text(deviceType?.displayName ?? "Device(\(rawType))")
                .foregroundColor(.secondary)
                .font(.subheadline)
            if let power = powerValue {
                Text("\(valueLabel):\(power)")
                    .font(.system(.subheadline, design: .monospaced))
            }

            if isControllable, let hub = hub, hub.canControlMotors {
                Slider(value: $sliderSpeed,
                       in: isMotor ? -100...100 : 0...100,
                       step: 1) {
                    Text("Power")
                }
                .frame(minWidth: 100, maxWidth: 160)
                .onChange(of: sliderSpeed) { newValue in
                    let power = Int8(clamping: Int(newValue))
                    hub.sendLWP3(LWP3Command.motorStartPower(portID: port, power: power))
                }

                Button {
                    sliderSpeed = 0
                    hub.sendLWP3(LWP3Command.motorStartPower(portID: port, power: 0))
                } label: {
                    Text(isMotor ? "Stop" : "Off")
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct HubView: View {
    let devicesPublisher = NotificationCenter.default
                .publisher(for: RIHubManager.DevicesChangedNotification)

    @State private var hub = RIHubManager.shared.hubs.first
    @State private var hubState = RIHub.State.disconnected
        
    var body: some View {
        Group {
            if let hub = hub {
                Group {
                    switch hubState {
                    case .connecting:
                        VStack {
                            ProgressView("Connecting…")
                                .padding()
                            FilledButton(title: "Disconnect") {
                                print("Disconnect...")
                                hub.disconnect()
                            }
                        }

                    case .connected:
                        ConnectedView(hub)
                        
                    default:
                        VStack {
                            if let image = hub.largeImage {
                                #if os(watchOS)
                                VStack(alignment: .leading) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 80, height: 80)
                                    Text(hub.deviceName)
                                }
                                #elseif os(iOS)
                                HStack {
                                    Image(uiImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 80, height: 80)
                                        .padding(.trailing, 10)
                                    VStack(alignment: .leading) {
                                        Text(hub.deviceName)
                                    }
                                }
                                #elseif os(macOS)
                                HStack {
                                    Image(nsImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 80, height: 80)
                                        .padding(.trailing, 10)
                                    VStack(alignment: .leading) {
                                        Text(hub.deviceName)
                                    }
                                }
                                #endif
                            }
                            else {
                                Text(hub.deviceName)
                            }
                            FilledButton(title: "Connect", action: {
                                print("Connect...")
                                hub.connect()
                            })
                        }
                    }
                }
                .onReceive(NotificationCenter.default
                            .publisher(for: RIHub.StateChangeNotification, object: hub)) { (output) in
                    hubState = hub.state
                }
            }
            else {
                VStack(spacing: 16) {
                    Text("Please turn on your Robot Inventor hub.")
                        .font(titleFont)
                        .multilineTextAlignment(.center)
                        .padding()

                    #if os(iOS)
                    FilledButton(title: "Pair LEGO Hub") {
                        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil) { error in
                            if let error = error {
                                #if DEBUG
                                print("EA picker error: \(error.localizedDescription)")
                                #endif
                            }
                        }
                    }
                    #endif
                }
            }
        }
        .onReceive(devicesPublisher) { (output) in
            print("devicesChanged: \(RIHubManager.shared.hubs)")
            
            hub = RIHubManager.shared.hubs.first
            hubState = hub?.state ?? .disconnected
        }
        .transition(.opacity)
    }

}

struct ContentView: View {
    @State private var bluetoothState = RIHubManager.shared.state

    let bluetoothPublisher = NotificationCenter.default
                .publisher(for: RIHubManager.BluetoothStateChangedNotification)
    
    var body: some View {
        Group() {
            switch bluetoothState {
            case .poweredOff:
                BluetoothPoweredOffView()
                
            case .unauthorized:
                BluetoothUnauthorizedView()
                
            case .poweredOn:
                HubView()

            default:
                NoBluetoothView()
            }
        }
        .onReceive(bluetoothPublisher) { (output) in
            bluetoothState = RIHubManager.shared.state
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

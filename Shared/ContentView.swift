//
//  ContentView.swift
//  Shared
//
//  Created by Mark Alldritt on 2021-02-09.
//

import SwiftUI

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

    var body: some View {
        HStack(spacing: 6) {
            Text("Motor")
                .foregroundColor(.secondary)
                .font(.subheadline)
            Text("spd:\(motor.speed)")
                .font(.system(.subheadline, design: .monospaced))
            Text("pos:\(motor.position)")
                .font(.system(.subheadline, design: .monospaced))

            if let hub = hub, hub.canControlMotors {
                Slider(value: $sliderSpeed, in: -100...100, step: 1) {
                    Text("Speed")
                }
                .frame(minWidth: 100, maxWidth: 160)
                .onChange(of: sliderSpeed) { newValue in
                    let speed = Int8(clamping: Int(newValue))
                    if speed == 0 {
                        hub.sendLWP3(LWP3Command.motorBrake(portID: motor.port))
                    } else {
                        hub.sendLWP3(LWP3Command.motorStartSpeed(portID: motor.port, speed: speed))
                    }
                }

                Button {
                    sliderSpeed = 0
                    hub.sendLWP3(LWP3Command.motorBrake(portID: motor.port))
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

    private var swatchColor: SwiftUI.Color {
        SwiftUI.Color(
            red: Double(color.red) / 1024.0,
            green: Double(color.green) / 1024.0,
            blue: Double(color.blue) / 1024.0
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Color")
                .foregroundColor(.secondary)
                .font(.subheadline)
            Circle()
                .fill(swatchColor)
                .frame(width: 12, height: 12)
            if color.colorID >= 0 {
                Text("id:\(color.colorID)")
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
                Text("Please turn on your Robot Inventor hub.")
                    .font(titleFont)
                    .multilineTextAlignment(.center)
                    .padding()
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

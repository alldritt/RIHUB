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

    init(_ hub: RIHub) {
        self.hub = hub
    }

    var body: some View {
        VStack {
            Text("Connected")
            Button("Disconnect",
                   action: {
                    hub.disconnect()
                   })
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

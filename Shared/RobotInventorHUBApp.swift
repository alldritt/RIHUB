//
//  RobotInventorHUBApp.swift
//  Shared
//
//  Created by Mark Alldritt on 2021-02-09.
//

import SwiftUI

@main
struct RobotInventorHUBApp: App {
    init() {
        RIHubManager.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

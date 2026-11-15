//
//  SideloaderApp.swift
//  Sideloader
//
//  Created by hani on 11/2/26.
//

import SwiftUI

@main
struct SideloaderApp: App {
    @State private var model = InstallerModel()

    init() {
        AppPackage.removeStaleWorkDirectories()
    }

    var body: some Scene {
        Window("Sideloader", id: "main") {
            ContentView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

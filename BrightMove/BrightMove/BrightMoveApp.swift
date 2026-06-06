//
//  BrightMoveApp.swift
//  BrightMove
//
//  Created by Andrea G on 06/06/2026.
//

import SwiftUI
import SwiftData
import AppKit
import PropertyStore

@main
struct BrightMoveApp: App {
    let container: ModelContainer
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        do {
            container = try ModelContainer(for: PinnedProperty.self, PropertyEvent.self)
        } catch {
            fatalError("Failed to create the data store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
        .windowToolbarStyle(.unified)
    }
}

/// Brings the window to the front when launched via `swift run` (a non-bundled
/// executable otherwise starts as a background accessory).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

//
//  ScrollSnapApp.swift
//  ScrollSnap
//
//  Created by ww on 2026/2/26.
//

import SwiftUI

@main
struct ScrollSnapApp: App {
    @StateObject private var supportStore = SupportStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(supportStore)
        }
    }
}

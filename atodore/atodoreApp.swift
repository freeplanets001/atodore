//
//  atodoreApp.swift
//  atodore
//
//  Created by Tomonori_Ueda on 2026/08/16.
//

import SwiftUI
import SwiftData

enum AppCloudKit {
    static let containerIdentifier = "iCloud.com.freeplanets001.atodore"
}

@main
struct atodoreApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
            PurchaseRecord.self,
            UsageRecord.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private(AppCloudKit.containerIdentifier)
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}

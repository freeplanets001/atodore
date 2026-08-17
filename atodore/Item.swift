//
//  Item.swift
//  atodore
//
//  Created by Tomonori_Ueda on 2026/08/16.
//

import Foundation
import SwiftData

@Model
final class Item {
    var id: UUID = UUID()
    var name: String = ""
    var categoryRawValue: String = "その他"
    var stateRawValue: String = "今使っている"
    var daysRemaining: Int?
    var unopenedCount: Int = 0
    var accuracy: String = "中"
    var importanceRawValue: String = "少し困る"
    var openedDate: Date?
    var expirationDate: Date?
    var averageUsageDays: Int = 30
    var usageHistoryCount: Int = 0
    var minimumStockCount: Int = 0
    var purchaseUnit: String = "個"
    var usageScopeRawValue: String = "家族全体"
    var preferredStore: String = ""
    var barcode: String = ""
    var purchaseURLString: String = ""
    var memo: String = ""
    var storageLocation: String = ""
    var tags: String = ""
    var photoData: Data?
    var productNotificationsEnabled: Bool = true
    var createdAt: Date = Date()
    var timestamp: Date = Date()

    init(
        id: UUID = UUID(),
        name: String,
        categoryRawValue: String,
        stateRawValue: String,
        daysRemaining: Int?,
        unopenedCount: Int,
        accuracy: String,
        importanceRawValue: String,
        openedDate: Date?,
        expirationDate: Date? = nil,
        averageUsageDays: Int,
        usageHistoryCount: Int,
        minimumStockCount: Int = 0,
        purchaseUnit: String = "個",
        usageScopeRawValue: String = "家族全体",
        preferredStore: String = "",
        barcode: String = "",
        purchaseURLString: String = "",
        memo: String = "",
        storageLocation: String = "",
        tags: String = "",
        photoData: Data? = nil,
        productNotificationsEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.categoryRawValue = categoryRawValue
        self.stateRawValue = stateRawValue
        self.daysRemaining = daysRemaining
        self.unopenedCount = unopenedCount
        self.accuracy = accuracy
        self.importanceRawValue = importanceRawValue
        self.openedDate = openedDate
        self.expirationDate = expirationDate
        self.averageUsageDays = averageUsageDays
        self.usageHistoryCount = usageHistoryCount
        self.minimumStockCount = minimumStockCount
        self.purchaseUnit = purchaseUnit
        self.usageScopeRawValue = usageScopeRawValue
        self.preferredStore = preferredStore
        self.barcode = barcode
        self.purchaseURLString = purchaseURLString
        self.memo = memo
        self.storageLocation = storageLocation
        self.tags = tags
        self.photoData = photoData
        self.productNotificationsEnabled = productNotificationsEnabled
        self.createdAt = createdAt
    }
}

@Model
final class PurchaseRecord {
    var id: UUID = UUID()
    var itemID: UUID = UUID()
    var itemName: String = ""
    var quantity: Int = 1
    var price: Int?
    var store: String = ""
    var purchasedAt: Date = Date()

    init(
        id: UUID = UUID(),
        itemID: UUID,
        itemName: String,
        quantity: Int,
        price: Int?,
        store: String,
        purchasedAt: Date = Date()
    ) {
        self.id = id
        self.itemID = itemID
        self.itemName = itemName
        self.quantity = quantity
        self.price = price
        self.store = store
        self.purchasedAt = purchasedAt
    }
}

@Model
final class UsageRecord {
    var id: UUID = UUID()
    var itemID: UUID = UUID()
    var itemName: String = ""
    var eventRawValue: String = ""
    var daysRemainingBefore: Int?
    var daysRemainingAfter: Int?
    var openedAt: Date?
    var actualUsageDays: Int?
    var averageUsageDaysBefore: Int?
    var recordedAt: Date = Date()

    init(
        id: UUID = UUID(),
        itemID: UUID,
        itemName: String,
        eventRawValue: String,
        daysRemainingBefore: Int?,
        daysRemainingAfter: Int?,
        openedAt: Date?,
        actualUsageDays: Int? = nil,
        averageUsageDaysBefore: Int? = nil,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.itemID = itemID
        self.itemName = itemName
        self.eventRawValue = eventRawValue
        self.daysRemainingBefore = daysRemainingBefore
        self.daysRemainingAfter = daysRemainingAfter
        self.openedAt = openedAt
        self.actualUsageDays = actualUsageDays
        self.averageUsageDaysBefore = averageUsageDaysBefore
        self.recordedAt = recordedAt
    }
}

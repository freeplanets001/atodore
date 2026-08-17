//
//  atodoreTests.swift
//  atodoreTests
//
//  Created by Tomonori_Ueda on 2026/08/16.
//

import Testing
import Foundation
@testable import atodore

struct atodoreTests {

    @Test func initialDaysRemainingSubtractsElapsedDays() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let openedAt = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))
        let currentDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 8)))

        let daysRemaining = UsagePredictionService.initialDaysRemaining(
            totalDays: 30,
            openedAt: openedAt,
            currentDate: currentDate,
            calendar: calendar
        )

        #expect(daysRemaining == 23)
    }

    @Test func initialDaysRemainingKeepsAtLeastOneDay() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let openedAt = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))
        let currentDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 15)))

        let daysRemaining = UsagePredictionService.initialDaysRemaining(
            totalDays: 30,
            openedAt: openedAt,
            currentDate: currentDate,
            calendar: calendar
        )

        #expect(daysRemaining == 1)
    }

    @Test func actualUsageDaysIncludesStartAndFinishDay() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let openedAt = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))
        let finishedAt = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10)))

        let days = UsagePredictionService.actualUsageDays(from: openedAt, to: finishedAt, calendar: calendar)

        #expect(days == 10)
    }

    @Test func updatedAverageUsesCurrentActualAndRecentHistory() async throws {
        let average = UsagePredictionService.updatedAverage(
            currentAverage: 30,
            actualUsageDays: 20,
            historicalUsageDays: [24, 26]
        )

        #expect(average == 26)
    }

    @Test func updatedAverageKeepsCurrentAverageWhenActualUsageIsUnknown() async throws {
        let average = UsagePredictionService.updatedAverage(
            currentAverage: 30,
            actualUsageDays: nil,
            historicalUsageDays: [10, 20, 40]
        )

        #expect(average == 30)
    }

    @Test func restoredAverageUsesPreviousAverageWhenAvailable() async throws {
        let average = UsagePredictionService.restoredAverage(
            currentAverage: 42,
            previousAverage: 30,
            remainingActualUsageDays: [10, 20, 90]
        )

        #expect(average == 30)
    }

    @Test func restoredAverageFallsBackToRemainingHistory() async throws {
        let average = UsagePredictionService.restoredAverage(
            currentAverage: 42,
            previousAverage: nil,
            remainingActualUsageDays: [20, 28, 30]
        )

        #expect(average == 26)
    }

    @Test func durationEstimateResolvesCustomDays() async throws {
        #expect(DurationEstimate.custom.resolvedDays(customDays: 45) == 45)
        #expect(DurationEstimate.custom.resolvedDays(customDays: 0) == 1)
        #expect(DurationEstimate.oneMonth.resolvedDays(customDays: 45) == 30)
    }

    @Test func householdUsageAdjustmentShortensPeopleSensitiveCategories() async throws {
        let profile = HouseholdProfile(adults: 2, children: 2, pets: 1)

        #expect(HouseholdUsageAdjustmentService.adjustedDays(baseDays: 30, category: .daily, profile: profile) == 16)
        #expect(HouseholdUsageAdjustmentService.adjustedDays(baseDays: 30, category: .pet, profile: profile) == 19)
        #expect(HouseholdUsageAdjustmentService.adjustedDays(baseDays: 30, category: .other, profile: profile) == 30)
    }

    @Test func productSuggestionUsesHouseholdProfileForFallbackPrediction() async throws {
        let profile = HouseholdProfile(adults: 2, children: 2, pets: 0)
        let suggestion = ProductSuggestionProvider.fallbackSuggestion(for: "トイレットペーパー", householdProfile: profile)

        #expect(suggestion.category == .daily)
        #expect(suggestion.estimate == .custom)
        #expect(suggestion.customDurationDays == 8)
        #expect(suggestion.isHouseholdAdjusted)
        #expect(suggestion.reason.contains("世帯構成"))
    }

    @Test func normalizedProductNameIgnoresWidthCaseAndWhitespace() async throws {
        #expect("　Coffee １ ".normalizedProductName == "coffee1")
        #expect("トイレット ペーパー".normalizedProductName == "トイレットペーパー")
    }

    @Test func japaneseFormattersUseJapaneseDisplay() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16)))

        #expect(JapaneseDateFormatter.shortDate(date) == "8月16日")
        #expect(JapaneseDateFormatter.fullDate(date) == "2026年8月16日")
        #expect(JapaneseCurrencyFormatter.yen(1200) == "1,200円")
    }

    @MainActor @Test func purchaseUnitDefaultsAndExports() async throws {
        let blankUnitProduct = StockProduct(
            name: "洗濯洗剤",
            category: .laundry,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 1,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 0,
            purchaseUnit: " "
        )

        #expect(blankUnitProduct.normalizedPurchaseUnit == "個")

        let product = StockProduct(
            name: "洗濯洗剤",
            category: .laundry,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 1,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 0,
            purchaseUnit: "袋"
        )
        let exportText = AppDataExportService.exportText(for: [product])
        let importedProduct = try #require(try AppDataExportService.importProducts(from: exportText).first)

        #expect(importedProduct.normalizedPurchaseUnit == "袋")
    }

    @Test func tagSuggestionMergesWithoutDuplicates() async throws {
        let merged = TagSuggestionService.mergedTagsText(
            existing: "食品、備蓄",
            suggested: TagSuggestionService.tagsText(for: "保存水", category: .food)
        )

        #expect(merged.contains("食品"))
        #expect(merged.contains("備蓄"))
        #expect(merged.components(separatedBy: "、").filter { $0 == "食品" }.count == 1)
    }

    @Test func householdProfileScopesPredictionTargets() async throws {
        let profile = HouseholdProfile(adults: 2, children: 2, pets: 1)

        #expect(profile.scoped(to: .adults) == HouseholdProfile(adults: 2, children: 0, pets: 0))
        #expect(profile.scoped(to: .children) == HouseholdProfile(adults: 1, children: 2, pets: 0))
        #expect(profile.scoped(to: .pets) == HouseholdProfile(adults: 1, children: 0, pets: 1))
    }

    @MainActor @Test func storeShoppingListGroupsByPreferredStore() async throws {
        let drugstore = StockProduct(
            name: "洗濯洗剤",
            category: .laundry,
            state: .inUse,
            daysRemaining: 2,
            unopenedCount: 0,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 0,
            preferredStore: "ドラッグストア"
        )
        let supermarket = StockProduct(
            name: "牛乳",
            category: .food,
            state: .inUse,
            daysRemaining: 1,
            unopenedCount: 0,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            averageUsageDays: 7,
            usageHistoryCount: 0,
            preferredStore: "スーパー"
        )

        let groups = StoreShoppingListService.groups(products: [drugstore, supermarket]) { $0.normalizedPreferredStore }

        #expect(groups.map(\.storeName) == ["スーパー", "ドラッグストア"])
        #expect(StoreShoppingListService.memoText(groups: groups, householdProfile: HouseholdProfile(adults: 1, children: 0, pets: 0)).contains("[ ] 牛乳"))
    }

    @Test func notificationPreviewUsesPreferredShoppingWeekday() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)

        #expect(NotificationService.refillReminderPreviewDays(daysRemaining: 8, leadDays: 1, preferredShoppingWeekday: weekday, calendar: calendar) <= 7)
        #expect(NotificationService.refillReminderPreviewDays(daysRemaining: 8, leadDays: 1, preferredShoppingWeekday: 0, calendar: calendar) == 7)
    }

    @Test func priceInsightCalculatesRangeAndPreviousComparison() async throws {
        let itemID = UUID()
        let latest = PurchaseHistoryEntry(record: PurchaseRecord(itemID: itemID, itemName: "洗濯洗剤", quantity: 1, price: 520, store: "", purchasedAt: Date()))
        let previous = PurchaseHistoryEntry(record: PurchaseRecord(itemID: itemID, itemName: "洗濯洗剤", quantity: 1, price: 480, store: "", purchasedAt: Date().addingTimeInterval(-86_400)))
        let oldest = PurchaseHistoryEntry(record: PurchaseRecord(itemID: itemID, itemName: "洗濯洗剤", quantity: 1, price: 600, store: "", purchasedAt: Date().addingTimeInterval(-172_800)))

        let insight = try #require(PriceInsightService.insight(from: [previous, oldest, latest]))

        #expect(insight.latestPrice == 520)
        #expect(insight.minPrice == 480)
        #expect(insight.maxPrice == 600)
        #expect(insight.previousComparisonText.contains("高い"))
    }

    @MainActor @Test func widgetSnapshotSummarizesAttentionCounts() async throws {
        let product = StockProduct(
            name: "洗濯洗剤",
            category: .laundry,
            state: .inUse,
            daysRemaining: 2,
            unopenedCount: 0,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 0
        )

        let snapshot = WidgetSnapshotService.snapshotText(for: [product])

        #expect(snapshot.contains("買うもの 1件"))
        #expect(snapshot.contains("洗濯洗剤"))
    }

    @Test func shoppingCompletionStoreRoundTripsIDs() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let text = ShoppingCompletionStore.text(from: [firstID, secondID])

        #expect(ShoppingCompletionStore.ids(from: text) == [firstID, secondID])
    }

    @MainActor @Test func productImportPlannerCanMergeDuplicatesWithoutUsingSlots() async throws {
        let product = StockProduct(
            name: "洗濯洗剤",
            category: .laundry,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 1,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 0
        )
        let newProduct = StockProduct(
            name: "シャンプー",
            category: .bath,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 1,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 0
        )

        let plan = ProductImportPlanner.plan(
            importedProducts: [product, newProduct],
            existingNames: [product.name.normalizedProductName],
            availableSlots: 1,
            mergeDuplicates: true
        )

        #expect(plan.productsToImport.map(\.name) == ["洗濯洗剤", "シャンプー"])
        #expect(plan.mergedDuplicateCount == 1)
        #expect(plan.limitSkippedCount == 0)
    }

    @Test func receiptCandidateExtractorFiltersReceiptNoise() async throws {
        let candidates = ReceiptCandidateExtractor.candidates(from: [
            "レシート",
            "洗濯洗剤 398",
            "小計 398",
            "消費税 39",
            "洗濯洗剤 398",
            "トイレットペーパー",
            "TEL 03-0000-0000"
        ])

        #expect(candidates.map(\.name) == ["洗濯洗剤", "トイレットペーパー"])
    }

    @Test func receiptCandidateIncludesSuggestedCategory() async throws {
        let candidates = ReceiptCandidateExtractor.candidates(from: [
            "コーヒー 598"
        ])

        #expect(candidates.first?.name == "コーヒー")
        #expect(candidates.first?.category == .food)
    }

    @Test func receiptCandidateRefinementNormalizesAndDeduplicatesCandidates() async throws {
        let candidates = ReceiptCandidateRefinementService.fallbackRefinedCandidates(from: [
            ReceiptCandidate(name: "トイレトP"),
            ReceiptCandidate(name: "トイレットペーパー"),
            ReceiptCandidate(name: "洗濯洗剤")
        ])

        #expect(candidates.map(\.name) == ["トイレットペーパー", "洗濯洗剤"])
        #expect(candidates.map(\.category) == [.daily, .laundry])
    }

    @Test func naturalLanguageProductParserExtractsFallbackDraft() async throws {
        let draft = NaturalLanguageProductParser.fallbackDraft(from: "洗濯洗剤を2個買った。詰め替え用で45日持つ")

        #expect(draft.name == "洗濯洗剤")
        #expect(draft.category == .laundry)
        #expect(draft.state == .unopened)
        #expect(draft.unopenedCount == 2)
        #expect(draft.duration == .custom)
        #expect(draft.customDurationDays == 45)
        #expect(draft.memo.contains("詰め替え"))
    }

    @Test func naturalLanguageProductParserAdjustsAmbiguousDurationByHousehold() async throws {
        let draft = NaturalLanguageProductParser.fallbackDraft(
            from: "トイレットペーパーを2個買った",
            householdProfile: HouseholdProfile(adults: 2, children: 2, pets: 0)
        )

        #expect(draft.category == .daily)
        #expect(draft.duration == .custom)
        #expect(draft.customDurationDays == 16)
        #expect(draft.isHouseholdAdjusted)
    }

    @Test func naturalLanguageProductParserKeepsExplicitDuration() async throws {
        let draft = NaturalLanguageProductParser.fallbackDraft(
            from: "トイレットペーパーを2個買った。45日持つ",
            householdProfile: HouseholdProfile(adults: 2, children: 2, pets: 0)
        )

        #expect(draft.customDurationDays == 45)
        #expect(!draft.isHouseholdAdjusted)
    }

    @Test func expirationServiceCalculatesDisplayText() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16)))
        let future = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20)))
        let sameDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16)))
        let past = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15)))

        #expect(ExpirationService.daysRemaining(until: future, from: today, calendar: calendar) == 4)
        #expect(ExpirationService.displayText(for: future, from: today, calendar: calendar) == "期限まで4日")
        #expect(ExpirationService.displayText(for: sameDay, from: today, calendar: calendar) == "今日まで")
        #expect(ExpirationService.displayText(for: past, from: today, calendar: calendar) == "期限切れ")
    }

    @Test func expirationServiceDetectsSoonItems() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16)))
        let soon = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        let later = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))

        #expect(ExpirationService.isSoon(soon, from: today, thresholdDays: 30, calendar: calendar))
        #expect(!ExpirationService.isSoon(later, from: today, thresholdDays: 30, calendar: calendar))
    }

    @Test func notificationSchedulePreviewSortsUpcomingReminders() async throws {
        let expirationDate = try #require(Calendar.current.date(byAdding: .day, value: 10, to: Date()))
        let detergent = StockProduct(
            name: "洗濯洗剤",
            category: .laundry,
            state: .inUse,
            daysRemaining: 4,
            unopenedCount: 0,
            accuracy: "高",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 2
        )
        let milk = StockProduct(
            name: "牛乳",
            category: .food,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 1,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            expirationDate: expirationDate,
            averageUsageDays: 7,
            usageHistoryCount: 0
        )

        let previews = NotificationSchedulePreviewService.previews(
            for: [milk, detergent],
            notificationsEnabled: true,
            leadDays: 3,
            expirationLeadDays: 7
        )

        #expect(previews.map(\.productName) == ["洗濯洗剤", "牛乳"])
        #expect(previews.map(\.kind) == [.refill, .expiration])
        #expect(previews.map(\.daysUntilReminder) == [1, 3])
        #expect(NotificationSchedulePreviewService.nextReminderText(for: [milk, detergent], notificationsEnabled: true, leadDays: 3, expirationLeadDays: 7).contains("洗濯洗剤"))
    }

    @Test func notificationSchedulePreviewReturnsEmptyWhenNotificationsAreDisabled() async throws {
        let product = StockProduct(
            name: "洗濯洗剤",
            category: .laundry,
            state: .inUse,
            daysRemaining: 4,
            unopenedCount: 0,
            accuracy: "高",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 2
        )

        let previews = NotificationSchedulePreviewService.previews(
            for: [product],
            notificationsEnabled: false,
            leadDays: 3,
            expirationLeadDays: 7
        )

        #expect(previews.isEmpty)
        #expect(NotificationSchedulePreviewService.nextReminderText(for: [product], notificationsEnabled: false, leadDays: 3, expirationLeadDays: 7) == "対象なし")
    }

    @Test func appDataExportServiceCreatesReadableJSON() async throws {
        let generatedAt = try #require(ISO8601DateFormatter().date(from: "2026-08-16T00:00:00Z"))
        let product = StockProduct(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
            name: "洗濯洗剤",
            category: .laundry,
            state: .inUse,
            daysRemaining: 5,
            unopenedCount: 1,
            accuracy: "高",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 2,
            purchaseURLString: "https://example.com",
            memo: "詰め替え用",
            storageLocation: "洗面台",
            tags: "詰め替え,定番",
            notificationsEnabled: true
        )

        let text = AppDataExportService.exportText(for: [product], generatedAt: generatedAt)
        let data = try #require(text.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let products = try #require(json["products"] as? [[String: Any]])

        #expect(json["schemaVersion"] as? Int == 1)
        #expect(products.first?["name"] as? String == "洗濯洗剤")
        #expect(products.first?["purchaseURLString"] as? String == "https://example.com")
        #expect(products.first?["memo"] as? String == "詰め替え用")
        #expect(products.first?["storageLocation"] as? String == "洗面台")
        #expect(products.first?["tags"] as? String == "詰め替え,定番")
    }

    @Test func appDataExportServiceImportsExportedProducts() async throws {
        let product = StockProduct(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID(),
            name: "コーヒー",
            category: .food,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 2,
            accuracy: "中",
            importance: .low,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 28,
            usageHistoryCount: 1,
            purchaseURLString: "",
            notificationsEnabled: false
        )
        let text = AppDataExportService.exportText(for: [product])

        let importedProducts = try AppDataExportService.importProducts(from: text)

        #expect(importedProducts.count == 1)
        #expect(importedProducts.first?.id == product.id)
        #expect(importedProducts.first?.name == "コーヒー")
        #expect(importedProducts.first?.category == .food)
        #expect(importedProducts.first?.notificationsEnabled == false)
    }

    @Test func productImportSummaryExplainsSkippedProducts() async throws {
        let summary = ProductImportSummary(importedCount: 2, skippedCount: 3)

        #expect(summary.message == "2件の商品を読み込みました。3件は登録上限または重複のためスキップしました。")
    }

    @Test func purchaseURLFormatterNormalizesOnlyWebURLs() async throws {
        #expect(PurchaseURLFormatter.normalizedURLString(from: "example.com/item") == "https://example.com/item")
        #expect(PurchaseURLFormatter.normalizedURLString(from: " https://example.com/item ") == "https://example.com/item")
        #expect(PurchaseURLFormatter.normalizedURLString(from: "javascript:alert(1)") == "")
        #expect(PurchaseURLFormatter.normalizedURLString(from: "https://") == "")
    }

    @Test func productImportPlannerSkipsExistingAndDuplicateProducts() async throws {
        let detergent = StockProduct(
            name: "洗濯洗剤",
            category: .laundry,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 1,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 0
        )
        let coffee = StockProduct(
            name: "コーヒー",
            category: .food,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 1,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 0
        )

        let plan = ProductImportPlanner.plan(
            importedProducts: [detergent, coffee, coffee],
            existingNames: ["洗濯洗剤".normalizedProductName],
            availableSlots: 10
        )

        #expect(plan.productsToImport.map(\.name) == ["コーヒー"])
        #expect(plan.skippedCount == 2)
        #expect(plan.limitSkippedCount == 0)
    }

    @Test func productImportPlannerTracksLimitSkippedProducts() async throws {
        let detergent = StockProduct(
            name: "洗濯洗剤",
            category: .laundry,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 1,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 0
        )
        let coffee = StockProduct(
            name: "コーヒー",
            category: .food,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 1,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 0
        )

        let plan = ProductImportPlanner.plan(
            importedProducts: [detergent, coffee],
            existingNames: [],
            availableSlots: 1
        )

        #expect(plan.productsToImport.map(\.name) == ["洗濯洗剤"])
        #expect(plan.skippedCount == 1)
        #expect(plan.limitSkippedCount == 1)
    }

    @Test func shoppingMemoServiceCreatesShareableMemo() async throws {
        let detergent = StockProduct(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333") ?? UUID(),
            name: "洗濯洗剤",
            category: .laundry,
            state: .inUse,
            daysRemaining: 2,
            unopenedCount: 0,
            accuracy: "高",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 2
        )
        let tissue = StockProduct(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444") ?? UUID(),
            name: "ティッシュ",
            category: .daily,
            state: .inUse,
            daysRemaining: 5,
            unopenedCount: 0,
            accuracy: "中",
            importance: .high,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 20,
            usageHistoryCount: 1
        )

        let memo = ShoppingMemoService.memoText(for: [tissue, detergent])

        #expect(memo == """
        あとどれ？ 買い物メモ

        - 洗濯洗剤（洗濯 / あと約2日）
        - ティッシュ（日用品 / あと約5日）
        """)
    }

    @Test func shoppingMemoServiceCanIncludeHouseholdProfile() async throws {
        let product = StockProduct(
            name: "ティッシュ",
            category: .daily,
            state: .inUse,
            daysRemaining: 5,
            unopenedCount: 0,
            accuracy: "中",
            importance: .high,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 20,
            usageHistoryCount: 1
        )

        let memo = ShoppingMemoService.memoText(
            for: [product],
            householdProfile: HouseholdProfile(adults: 2, children: 1, pets: 0)
        )

        #expect(memo.contains("世帯: 大人2人・子ども1人"))
        #expect(memo.contains("ティッシュ"))
        #expect(memo.contains("おすすめ"))
    }

    @Test func purchaseRecommendationConsidersUrgencyStockAndHousehold() async throws {
        let detergent = StockProduct(
            name: "洗濯洗剤",
            category: .laundry,
            state: .inUse,
            daysRemaining: 2,
            unopenedCount: 0,
            accuracy: "高",
            importance: .high,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 2
        )

        let recommendation = PurchaseRecommendationService.recommendation(
            for: detergent,
            householdProfile: HouseholdProfile(adults: 2, children: 2, pets: 0)
        )

        #expect(recommendation.quantity == 3)
        #expect(recommendation.reason.contains("残り"))
    }

    @Test func purchaseRecommendationKeepsExistingStockInMind() async throws {
        let tissue = StockProduct(
            name: "ティッシュ",
            category: .daily,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 3,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 20,
            usageHistoryCount: 1
        )

        let recommendation = PurchaseRecommendationService.recommendation(
            for: tissue,
            householdProfile: HouseholdProfile(adults: 1, children: 0, pets: 0)
        )

        #expect(recommendation.quantity == 0)
        #expect(!recommendation.shouldBuy)
        #expect(recommendation.reason.contains("十分"))
    }

    @Test func purchaseRecommendationRespectsMinimumStockCount() async throws {
        let product = StockProduct(
            name: "ティッシュ",
            category: .daily,
            state: .inUse,
            daysRemaining: 20,
            unopenedCount: 0,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 20,
            usageHistoryCount: 1,
            minimumStockCount: 2
        )

        let recommendation = PurchaseRecommendationService.recommendation(
            for: product,
            householdProfile: HouseholdProfile(adults: 1, children: 0, pets: 0)
        )

        #expect(recommendation.quantity == 2)
        #expect(recommendation.shouldBuy)
        #expect(recommendation.reason.contains("最低ストック"))
    }

    @Test func categoryCorrectionSuggestsDifferentInferredCategory() async throws {
        let product = StockProduct(
            name: "トイレットペーパー",
            category: .other,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 1,
            accuracy: "中",
            importance: .high,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 20,
            usageHistoryCount: 0
        )

        #expect(CategoryCorrectionService.suggestedCategory(for: product) == .daily)
    }

    @Test func dataRepairServiceClampsInvalidValues() async throws {
        let product = StockProduct(
            name: "  洗濯洗剤  ",
            category: .laundry,
            state: .inUse,
            daysRemaining: -4,
            unopenedCount: -2,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 999,
            usageHistoryCount: 0,
            minimumStockCount: -1,
            memo: "  詰め替え  "
        )

        let repaired = DataRepairService.repairedProduct(product)

        #expect(repaired.name == "洗濯洗剤")
        #expect(repaired.daysRemaining == 1)
        #expect(repaired.unopenedCount == 0)
        #expect(repaired.minimumStockCount == 0)
        #expect(repaired.averageUsageDays == 365)
        #expect(repaired.memo == "詰め替え")
    }

    @Test func csvExportIncludesOrganizingFields() async throws {
        let product = StockProduct(
            name: "洗濯洗剤",
            category: .laundry,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 2,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 0,
            memo: "詰め替え",
            storageLocation: "洗面台",
            tags: "定番,洗濯"
        )

        let csv = AppDataCSVExportService.exportText(for: [product])

        #expect(csv.contains("置き場所"))
        #expect(csv.contains("洗面台"))
        #expect(csv.contains("\"定番,洗濯\""))
    }

    @Test func purchaseInventoryServiceAdjustsStockWhenPurchaseHistoryChanges() async throws {
        #expect(PurchaseInventoryService.unopenedCountAfterDeletingPurchase(currentCount: 5, deletedQuantity: 2) == 3)
        #expect(PurchaseInventoryService.unopenedCountAfterDeletingPurchase(currentCount: 1, deletedQuantity: 3) == 0)
        #expect(PurchaseInventoryService.unopenedCountAfterUpdatingPurchase(currentCount: 5, oldQuantity: 2, newQuantity: 4) == 7)
        #expect(PurchaseInventoryService.unopenedCountAfterUpdatingPurchase(currentCount: 1, oldQuantity: 3, newQuantity: 1) == 0)
    }

    @Test func purchaseDefaultsServiceUsesLatestPriceAndFrequentStore() async throws {
        let itemID = UUID()
        let newer = PurchaseHistoryEntry(record: PurchaseRecord(
            itemID: itemID,
            itemName: "洗濯洗剤",
            quantity: 1,
            price: 498,
            store: "ドラッグストア",
            purchasedAt: Date()
        ))
        let older = PurchaseHistoryEntry(record: PurchaseRecord(
            itemID: itemID,
            itemName: "洗濯洗剤",
            quantity: 1,
            price: 398,
            store: "スーパー",
            purchasedAt: Date().addingTimeInterval(-86_400)
        ))
        let oldest = PurchaseHistoryEntry(record: PurchaseRecord(
            itemID: itemID,
            itemName: "洗濯洗剤",
            quantity: 1,
            price: 428,
            store: "スーパー",
            purchasedAt: Date().addingTimeInterval(-172_800)
        ))

        let defaults = PurchaseDefaultsService.defaults(from: [newer, older, oldest])

        #expect(defaults.price == 498)
        #expect(defaults.averagePrice == 441)
        #expect(defaults.store == "スーパー")
    }

    @Test func priceComparisonServiceExplainsPriceDifference() async throws {
        let higher = try #require(PriceComparisonService.comparison(currentPrice: 550, averagePrice: 500))
        let lower = try #require(PriceComparisonService.comparison(currentPrice: 440, averagePrice: 500))
        let usual = try #require(PriceComparisonService.comparison(currentPrice: 520, averagePrice: 500))

        #expect(higher.direction == .higher)
        #expect(higher.message.contains("高め"))
        #expect(lower.direction == .lower)
        #expect(lower.message.contains("安め"))
        #expect(usual.direction == .usual)
    }

    @Test func purchaseSpendingSummaryCalculatesMonthlyTotals() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let currentDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 17)))
        let itemID = UUID()
        let thisMonthA = PurchaseHistoryEntry(record: PurchaseRecord(
            itemID: itemID,
            itemName: "洗濯洗剤",
            quantity: 1,
            price: 500,
            store: "スーパー",
            purchasedAt: try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))
        ))
        let thisMonthB = PurchaseHistoryEntry(record: PurchaseRecord(
            itemID: itemID,
            itemName: "ティッシュ",
            quantity: 1,
            price: 300,
            store: "スーパー",
            purchasedAt: try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10)))
        ))
        let noPrice = PurchaseHistoryEntry(record: PurchaseRecord(
            itemID: itemID,
            itemName: "コーヒー",
            quantity: 1,
            price: nil,
            store: "ドラッグストア",
            purchasedAt: try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 12)))
        ))
        let previousMonth = PurchaseHistoryEntry(record: PurchaseRecord(
            itemID: itemID,
            itemName: "米",
            quantity: 1,
            price: 600,
            store: "スーパー",
            purchasedAt: try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 20)))
        ))

        let summary = PurchaseSpendingSummaryService.summary(
            from: [thisMonthA, thisMonthB, noPrice, previousMonth],
            currentDate: currentDate,
            calendar: calendar
        )

        #expect(summary.currentMonthTotal == 800)
        #expect(summary.previousMonthTotal == 600)
        #expect(summary.currentMonthCount == 2)
        #expect(summary.topStore == "スーパー")
        #expect(summary.categoryTotals.map(\.category) == [.laundry, .daily])
        #expect(summary.categoryTotals.map(\.total) == [500, 300])
        #expect(summary.trendText.contains("多め"))
    }

    @Test func purchaseHistoryCSVExportIncludesPurchaseRows() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let purchase = PurchaseHistoryEntry(record: PurchaseRecord(
            itemID: UUID(),
            itemName: "洗濯洗剤",
            quantity: 2,
            price: 498,
            store: "スーパー,駅前",
            purchasedAt: try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 17)))
        ))

        let csv = AppDataCSVExportService.purchaseHistoryText(for: [purchase])

        #expect(csv.contains("購入日,商品名,数量,価格,店舗"))
        #expect(csv.contains("2026年8月17日"))
        #expect(csv.contains("\"スーパー,駅前\""))
    }

    @Test func usageDeletionMessageExplainsPredictionImpact() async throws {
        #expect(UsageDeletionMessage.text(forEventRawValue: "なくなった").contains("平均使用期間"))
        #expect(UsageDeletionMessage.text(forEventRawValue: "まだある").contains("残り日数"))
        #expect(UsageDeletionMessage.text(forEventRawValue: "開けました").contains("現在の商品状態"))
    }

    @Test func purchaseDeletionMessageExplainsStockImpact() async throws {
        #expect(PurchaseDeletionMessage.text(quantity: 3).contains("3個分"))
        #expect(PurchaseDeletionMessage.text(quantity: 3).contains("未開封ストック"))
    }

    @Test func usageInsightServiceExplainsPredictionDirection() async throws {
        #expect(UsageInsightService.fallbackComment(actualUsageDays: 20, previousAverage: 30, learnedAverage: 26).contains("早め"))
        #expect(UsageInsightService.fallbackComment(actualUsageDays: 40, previousAverage: 30, learnedAverage: 34).contains("長持ち"))
        #expect(UsageInsightService.fallbackComment(actualUsageDays: nil, previousAverage: 30, learnedAverage: 30) == "予測を更新しました")
    }

    @Test func stockSearchServiceMatchesCategoryStateAndOrganizingFields() async throws {
        let detergent = StockProduct(
            name: "洗濯洗剤",
            category: .laundry,
            state: .inUse,
            daysRemaining: 2,
            unopenedCount: 0,
            accuracy: "高",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 2,
            memo: "詰め替え",
            storageLocation: "洗面台",
            tags: "定番"
        )
        let coffee = StockProduct(
            name: "コーヒー",
            category: .food,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 2,
            accuracy: "中",
            importance: .low,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 28,
            usageHistoryCount: 1
        )

        #expect(StockSearchService.filteredProducts([detergent, coffee], query: "食品").map(\.name) == ["コーヒー"])
        #expect(StockSearchService.filteredProducts([detergent, coffee], query: "未開封").map(\.name) == ["コーヒー"])
        #expect(StockSearchService.filteredProducts([detergent, coffee], query: "洗面台").map(\.name) == ["洗濯洗剤"])
        #expect(StockSearchService.filteredProducts([detergent, coffee], query: "定番").map(\.name) == ["洗濯洗剤"])
        #expect(StockSearchService.filteredProducts([detergent, coffee], query: "  ").count == 2)
    }

    @Test func stockSortServiceSortsByRecommendedAndName() async throws {
        let coffee = StockProduct(
            name: "コーヒー",
            category: .food,
            state: .inUse,
            daysRemaining: 12,
            unopenedCount: 0,
            accuracy: "中",
            importance: .low,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 28,
            usageHistoryCount: 1
        )
        let detergent = StockProduct(
            name: "洗濯洗剤",
            category: .laundry,
            state: .inUse,
            daysRemaining: 2,
            unopenedCount: 0,
            accuracy: "高",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 2
        )
        let tissue = StockProduct(
            name: "ティッシュ",
            category: .daily,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 2,
            accuracy: "中",
            importance: .high,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 20,
            usageHistoryCount: 1
        )

        let products = [tissue, coffee, detergent]

        #expect(StockSortService.sortedProducts(products, option: .recommended).map(\.name) == ["洗濯洗剤", "コーヒー", "ティッシュ"])
        #expect(StockSortService.sortedProducts(products, option: .name).map(\.name) == ["コーヒー", "ティッシュ", "洗濯洗剤"])
    }

    @Test func shoppingFilterServiceFiltersPurchaseTiming() async throws {
        let detergent = StockProduct(
            name: "洗濯洗剤",
            category: .laundry,
            state: .inUse,
            daysRemaining: 2,
            unopenedCount: 0,
            accuracy: "高",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 2
        )
        let coffee = StockProduct(
            name: "コーヒー",
            category: .food,
            state: .inUse,
            daysRemaining: 12,
            unopenedCount: 0,
            accuracy: "中",
            importance: .low,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 28,
            usageHistoryCount: 1
        )
        let tissue = StockProduct(
            name: "ティッシュ",
            category: .daily,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 2,
            accuracy: "中",
            importance: .high,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 20,
            usageHistoryCount: 1
        )

        let products = [tissue, coffee, detergent]

        #expect(ShoppingFilterService.products(products, option: .thisWeek).map(\.name) == ["洗濯洗剤"])
        #expect(ShoppingFilterService.products(products, option: .soon).map(\.name) == ["コーヒー"])
        #expect(ShoppingFilterService.products(products, option: .all).map(\.name) == ["洗濯洗剤", "コーヒー"])
    }

    @Test func homeSummaryServiceCountsAttentionItems() async throws {
        let expiringDate = try #require(Calendar.current.date(byAdding: .day, value: 5, to: Date()))
        let detergent = StockProduct(
            name: "洗濯洗剤",
            category: .laundry,
            state: .inUse,
            daysRemaining: 2,
            unopenedCount: 0,
            accuracy: "高",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 2
        )
        let coffee = StockProduct(
            name: "コーヒー",
            category: .food,
            state: .inUse,
            daysRemaining: 12,
            unopenedCount: 0,
            accuracy: "中",
            importance: .low,
            openedDate: nil,
            expirationDate: expiringDate,
            averageUsageDays: 28,
            usageHistoryCount: 1
        )
        let tissue = StockProduct(
            name: "ティッシュ",
            category: .daily,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 2,
            accuracy: "中",
            importance: .high,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 20,
            usageHistoryCount: 1
        )

        let summary = HomeSummaryService.summary(for: [detergent, coffee, tissue])

        #expect(summary.buyNowCount == 1)
        #expect(summary.soonCount == 1)
        #expect(summary.expiredCount == 0)
        #expect(summary.expiringCount == 1)
        #expect(summary.unopenedCount == 1)
        #expect(summary.hasAttentionItems)
    }

    @Test func stockFilterServiceFiltersExpiringAndUnopenedProducts() async throws {
        let expiringDate = try #require(Calendar.current.date(byAdding: .day, value: 5, to: Date()))
        let expiredDate = try #require(Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        let detergent = StockProduct(
            name: "洗濯洗剤",
            category: .laundry,
            state: .inUse,
            daysRemaining: 2,
            unopenedCount: 0,
            accuracy: "高",
            importance: .medium,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 30,
            usageHistoryCount: 2
        )
        let coffee = StockProduct(
            name: "コーヒー",
            category: .food,
            state: .inUse,
            daysRemaining: 12,
            unopenedCount: 0,
            accuracy: "中",
            importance: .low,
            openedDate: nil,
            expirationDate: expiringDate,
            averageUsageDays: 28,
            usageHistoryCount: 1
        )
        let tissue = StockProduct(
            name: "ティッシュ",
            category: .daily,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 2,
            accuracy: "中",
            importance: .high,
            openedDate: nil,
            expirationDate: nil,
            averageUsageDays: 20,
            usageHistoryCount: 1
        )
        let milk = StockProduct(
            name: "牛乳",
            category: .food,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 1,
            accuracy: "中",
            importance: .medium,
            openedDate: nil,
            expirationDate: expiredDate,
            averageUsageDays: 7,
            usageHistoryCount: 0
        )

        let products = [detergent, coffee, tissue, milk]

        #expect(StockFilterService.products(products, option: .expiring).map(\.name) == ["コーヒー"])
        #expect(StockFilterService.products(products, option: .expired).map(\.name) == ["牛乳"])
        #expect(StockFilterService.products(products, option: .unopened).map(\.name) == ["ティッシュ", "牛乳"])
        #expect(StockFilterService.products(products, option: .inUse).map(\.name) == ["洗濯洗剤", "コーヒー"])
    }

}

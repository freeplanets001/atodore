//
//  ContentView.swift
//  atodore
//
//  Created by Tomonori_Ueda on 2026/08/16.
//

import SwiftUI
import SwiftData
import StoreKit
import CloudKit
import UniformTypeIdentifiers
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query(sort: \Item.createdAt) private var items: [Item]
    @Query(sort: \PurchaseRecord.purchasedAt, order: .reverse) private var purchaseRecords: [PurchaseRecord]
    @Query(sort: \UsageRecord.recordedAt, order: .reverse) private var usageRecords: [UsageRecord]
    @State private var selectedTab = AppTab.home
    @State private var shoppingFilterOption = ShoppingFilterOption.thisWeek
    @State private var stockFilterOption = StockFilterOption.all
    @State private var isShowingAddProduct = false
    @State private var isShowingOnboarding = false
    @State private var selectedProduct: StockProduct?
    @State private var purchasingProduct: StockProduct?
    @State private var isShowingPaywall = false
    @State private var isShowingTemplateLibrary = false
    @State private var toastMessage: String?
    @State private var proProduct: Product?
    @State private var isLoadingStoreProducts = false
    @State private var isPurchasingPro = false
    @State private var storeStatusMessage = "App Storeから商品情報を読み込みます。"
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("isProUser") private var isProUser = false
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("notificationLeadDays") private var notificationLeadDays = 3
    @AppStorage("expirationNotificationLeadDays") private var expirationNotificationLeadDays = 7
    @AppStorage("preferredShoppingWeekday") private var preferredShoppingWeekday = 0
    @AppStorage("defaultPurchaseProvider") private var defaultPurchaseProviderRawValue = PurchaseProvider.amazon.rawValue
    @AppStorage("usesAIForPurchaseSearch") private var usesAIForPurchaseSearch = true
    @AppStorage("householdAdults") private var householdAdults = 1
    @AppStorage("householdChildren") private var householdChildren = 0
    @AppStorage("householdPets") private var householdPets = 0
    @AppStorage("monthlyPurchaseBudget") private var monthlyPurchaseBudget = 0
    @AppStorage("qualityCheckOnLaunch") private var qualityCheckOnLaunch = true

    @MainActor private var products: [StockProduct] {
        items
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(StockProduct.init)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(
                products: products,
                onAdd: showAddProductFlow,
                onSelect: { selectedProduct = $0 },
                onNavigate: navigateFromHomeSummary
            )
            .tabItem { Label("ホーム", systemImage: "house.fill") }
            .tag(AppTab.home)

            ShoppingView(
                products: products,
                filterOption: $shoppingFilterOption,
                householdProfile: householdProfile,
                purchaseDefaults: purchaseDefaults,
                onSelect: { selectedProduct = $0 },
                onSavedPurchase: recordPurchase
            )
            .tabItem { Label("買い物", systemImage: "cart.fill") }
            .tag(AppTab.shopping)

            StockView(
                products: products,
                filterOption: $stockFilterOption,
                usageHistories: usageHistoryEntries,
                onAdd: showAddProductFlow,
                onSelect: { selectedProduct = $0 },
                onBought: { purchasingProduct = $0 },
                onOpened: { openProduct(product: $0, openedAt: Date()) },
                onFinished: { finishUsing(product: $0, finishedAt: Date()) },
                onDeleteUsage: deleteUsageRecord
            )
            .tabItem { Label("ストック", systemImage: "shippingbox.fill") }
            .tag(AppTab.stock)

            SettingsView(
                isProUser: isProUser,
                registeredCount: products.count,
                freeLimit: AppPlan.freeProductLimit,
                products: products,
                purchases: purchaseHistoryEntries,
                notificationsEnabled: $notificationsEnabled,
                notificationLeadDays: $notificationLeadDays,
                expirationNotificationLeadDays: $expirationNotificationLeadDays,
                preferredShoppingWeekday: $preferredShoppingWeekday,
                defaultPurchaseProviderRawValue: $defaultPurchaseProviderRawValue,
                usesAIForPurchaseSearch: $usesAIForPurchaseSearch,
                householdAdults: $householdAdults,
                householdChildren: $householdChildren,
                householdPets: $householdPets,
                monthlyPurchaseBudget: $monthlyPurchaseBudget,
                qualityCheckOnLaunch: $qualityCheckOnLaunch,
                onRequestNotifications: requestNotificationAuthorization,
                onRescheduleNotifications: rescheduleAllNotifications,
                onSendTestNotification: sendTestNotification,
                onShowPaywall: { isShowingPaywall = true },
                onRestorePurchase: {
                    Task {
                        await restoreProPurchase()
                    }
                },
                onShowTemplates: { isShowingTemplateLibrary = true },
                onShowOnboarding: { isShowingOnboarding = true },
                onRepairData: repairData,
                onApplyCategorySuggestions: applyCategorySuggestions,
                onImportProducts: importProducts
            )
                .tabItem { Label("設定", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .tint(AppTheme.primary)
        .sheet(isPresented: $isShowingAddProduct) {
            AddProductView(
                householdProfile: householdProfile,
                barcodeLookupProxyURLString: AppAPIConfiguration.barcodeLookupProxyURLString,
                onRequestNotifications: requestNotificationAuthorization,
                availableProductSlots: isProUser ? nil : max(AppPlan.freeProductLimit - products.count, 0),
                onLimitReached: {
                    isShowingAddProduct = false
                    isShowingPaywall = true
                }
            ) { product in
                saveProduct(product, toastMessage: "登録しました")
            }
        }
        .sheet(item: $purchasingProduct) { product in
            PurchaseSheet(product: product, defaults: purchaseDefaults(for: product)) { quantity, price, store, purchasedAt in
                recordPurchase(product: product, quantity: quantity, price: price, store: store, purchasedAt: purchasedAt)
            }
        }
        .sheet(item: $selectedProduct) { product in
            ProductDetailView(
                product: product,
                purchases: purchases(for: product),
                usages: usages(for: product),
                onStillHave: extendPrediction,
                onFinished: finishUsing,
                onOpened: openProduct,
                onOpenPurchasePage: openPurchasePage,
                onSavePurchaseURL: savePurchaseURL,
                onRecordPurchase: recordPurchase,
                onEdit: updateProduct,
                onDelete: deleteProduct,
                onDeletePurchase: deletePurchaseRecord,
                onUpdatePurchase: updatePurchaseRecord,
                onDeleteUsage: deleteUsageRecord
            )
        }
        .fullScreenCover(isPresented: $isShowingOnboarding) {
            OnboardingView(
                notificationLeadDays: $notificationLeadDays,
                expirationNotificationLeadDays: $expirationNotificationLeadDays,
                defaultPurchaseProviderRawValue: $defaultPurchaseProviderRawValue,
                usesAIForPurchaseSearch: $usesAIForPurchaseSearch
            ) {
                hasCompletedOnboarding = true
                isShowingOnboarding = false
                showAddProductFlow()
            } onUseTemplates: { templates in
                registerStarterTemplates(templates)
                hasCompletedOnboarding = true
                isShowingOnboarding = false
            } onSkip: {
                hasCompletedOnboarding = true
                isShowingOnboarding = false
            }
        }
        .sheet(isPresented: $isShowingPaywall) {
            PaywallView(
                isProUser: isProUser,
                registeredCount: products.count,
                freeLimit: AppPlan.freeProductLimit,
                proProductDisplayPrice: proProduct?.displayPrice,
                storeStatusMessage: storeStatusMessage,
                isLoadingStoreProducts: isLoadingStoreProducts,
                isPurchasingPro: isPurchasingPro,
                onStartPro: {
                    Task {
                        await purchasePro()
                    }
                },
                onRestore: {
                    Task {
                        await restoreProPurchase()
                    }
                },
                onDismiss: {
                    isShowingPaywall = false
                }
            )
        }
        .sheet(isPresented: $isShowingTemplateLibrary) {
            TemplateSelectionView(
                title: "テンプレート",
                registeredNames: registeredProductNames,
                selectionLimit: templateSelectionLimit
            ) { templates in
                registerStarterTemplates(templates)
            }
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                ToastView(message: toastMessage)
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            if !hasCompletedOnboarding {
                isShowingOnboarding = true
            } else if qualityCheckOnLaunch {
                showQualityCheckToastIfNeeded()
            }
        }
        .task {
            await refreshProEntitlement()
            await loadStoreProducts()
        }
        .task {
            for await verificationResult in StoreKit.Transaction.updates {
                await handleProTransaction(verificationResult, shouldFinish: true)
            }
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.snappy) {
            toastMessage = message
        }

        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                withAnimation(.snappy) {
                    toastMessage = nil
                }
            }
        }
    }

    @MainActor private func loadStoreProducts() async {
        guard !isLoadingStoreProducts else { return }
        isLoadingStoreProducts = true
        defer { isLoadingStoreProducts = false }

        do {
            let products = try await Product.products(for: AppStoreProductID.all)
            proProduct = products.first { $0.id == AppStoreProductID.proMonthly }
            storeStatusMessage = proProduct == nil
                ? "App Store ConnectでPro商品を作成すると購入できます。"
                : "Proにすると登録数の上限を解除できます。"
        } catch {
            storeStatusMessage = "商品情報を取得できませんでした。通信状態を確認してください。"
        }
    }

    @MainActor private func purchasePro() async {
        if proProduct == nil {
            await loadStoreProducts()
        }

        guard let proProduct else {
            showToast("Pro商品がまだApp Store Connectに設定されていません")
            return
        }

        isPurchasingPro = true
        defer { isPurchasingPro = false }

        do {
            let result = try await proProduct.purchase()
            switch result {
            case .success(let verificationResult):
                let isActive = await handleProTransaction(verificationResult, shouldFinish: true)
                showToast(isActive ? "Proが有効になりました" : "購入を確認できませんでした")
            case .pending:
                showToast("購入は承認待ちです")
            case .userCancelled:
                showToast("購入をキャンセルしました")
            @unknown default:
                showToast("購入結果を確認できませんでした")
            }
        } catch {
            showToast("購入に失敗しました")
        }
    }

    @MainActor private func restoreProPurchase() async {
        do {
            try await AppStore.sync()
            await refreshProEntitlement()
            showToast(isProUser ? "購入を復元しました" : "復元できる購入はありません")
        } catch {
            showToast("購入復元に失敗しました")
        }
    }

    @MainActor private func refreshProEntitlement() async {
        var hasActivePro = false
        for await verificationResult in StoreKit.Transaction.currentEntitlements {
            if await handleProTransaction(verificationResult, shouldFinish: false) {
                hasActivePro = true
            }
        }
        isProUser = hasActivePro
    }

    @MainActor @discardableResult private func handleProTransaction(_ verificationResult: VerificationResult<StoreKit.Transaction>, shouldFinish: Bool) async -> Bool {
        guard case .verified(let transaction) = verificationResult else {
            storeStatusMessage = "購入情報を検証できませんでした。"
            return false
        }

        guard transaction.productID == AppStoreProductID.proMonthly else {
            if shouldFinish {
                await transaction.finish()
            }
            return false
        }

        if transaction.revocationDate != nil {
            isProUser = false
            storeStatusMessage = "Pro購入は取り消されています。"
            if shouldFinish {
                await transaction.finish()
            }
            return false
        }

        if let expirationDate = transaction.expirationDate, expirationDate < Date() {
            isProUser = false
            storeStatusMessage = "Proの有効期限が切れています。"
            if shouldFinish {
                await transaction.finish()
            }
            return false
        }

        isProUser = true
        storeStatusMessage = "Proが有効です。"
        if shouldFinish {
            await transaction.finish()
        }
        return true
    }

    private func showAddProductFlow() {
        if isProUser || products.count < AppPlan.freeProductLimit {
            isShowingAddProduct = true
        } else {
            isShowingPaywall = true
        }
    }

    private func showQualityCheckToastIfNeeded() {
        let attentionCount = AppDiagnosticsService
            .diagnostics(for: products, purchases: purchaseHistoryEntries, monthlyBudget: monthlyPurchaseBudget)
            .filter(\.isAttentionNeeded)
            .count
        if attentionCount > 0 {
            showToast("データ確認が必要な項目が\(attentionCount)件あります")
        }
    }

    private func navigateFromHomeSummary(tab: AppTab, shoppingFilter: ShoppingFilterOption?, stockFilter: StockFilterOption?) {
        if let shoppingFilter {
            shoppingFilterOption = shoppingFilter
        }
        if let stockFilter {
            stockFilterOption = stockFilter
        }
        selectedTab = tab
    }

    private var registeredProductNames: Set<String> {
        Set(products.map { $0.name.normalizedProductName })
    }

    private var templateSelectionLimit: Int? {
        isProUser ? nil : max(AppPlan.freeProductLimit - products.count, 0)
    }

    private func saveProduct(_ product: StockProduct, toastMessage message: String?) {
        if let existingItem = items.first(where: { $0.name.normalizedProductName == product.name.normalizedProductName }) {
            merge(product, into: existingItem)
            if message != nil {
                showToast("既存の商品に統合しました")
            }
        } else {
            modelContext.insert(Item(product: product))
            Task {
                await NotificationService.scheduleReminder(
                    for: product,
                    notificationsEnabled: notificationsEnabled,
                    leadDays: notificationLeadDays,
                    expirationLeadDays: expirationNotificationLeadDays,
                    preferredShoppingWeekday: preferredShoppingWeekday
                )
            }
            if let message {
                showToast(message)
            }
        }
    }

    private func merge(_ product: StockProduct, into item: Item) {
        item.unopenedCount += max(product.unopenedCount, 1)
        item.categoryRawValue = product.category.rawValue
        item.importanceRawValue = product.importance.rawValue
        item.averageUsageDays = max(item.averageUsageDays, product.averageUsageDays)
        item.productNotificationsEnabled = product.notificationsEnabled
        item.expirationDate = product.expirationDate ?? item.expirationDate
        item.minimumStockCount = max(item.minimumStockCount, product.minimumStockCount)
        if item.purchaseUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.purchaseUnit == "個" {
            item.purchaseUnit = product.normalizedPurchaseUnit
        }
        if item.usageScopeRawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.usageScopeRawValue = product.usageScope.rawValue
        }
        if item.preferredStore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.preferredStore = product.normalizedPreferredStore
        }
        if item.barcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.barcode = product.barcode
        }
        if item.memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.memo = product.memo
        }
        if item.storageLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.storageLocation = product.storageLocation
        }
        if item.tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.tags = product.tags
        }
        if item.photoData == nil {
            item.photoData = product.photoData
        }

        if item.stateRawValue == ProductState.unopened.rawValue, product.state == .inUse {
            item.stateRawValue = ProductState.inUse.rawValue
            item.daysRemaining = product.daysRemaining
            item.openedDate = product.openedDate
        }

        Task {
            await NotificationService.scheduleReminder(
                for: StockProduct(item: item),
                notificationsEnabled: notificationsEnabled,
                leadDays: notificationLeadDays,
                expirationLeadDays: expirationNotificationLeadDays,
                preferredShoppingWeekday: preferredShoppingWeekday
            )
        }
    }

    private func registerStarterTemplates(_ templates: [StarterTemplate]) {
        let existingNames = registeredProductNames
        let uniqueItems = templates
            .flatMap(\.items)
            .filter { !existingNames.contains($0.name.normalizedProductName) }
        let availableSlots = templateSelectionLimit ?? uniqueItems.count
        let selectedItems = Array(uniqueItems.prefix(availableSlots))
        guard !selectedItems.isEmpty else {
            showToast("追加できる商品がありません")
            return
        }
        let newProducts = selectedItems.map(\.product)

        withAnimation {
            for product in newProducts {
                saveProduct(product, toastMessage: nil)
            }
        }

        HapticFeedback.success()
        showToast("\(selectedItems.count)件を登録しました")

        if selectedItems.count < uniqueItems.count {
            isShowingPaywall = true
        }
    }

    private func importProducts(_ importedProducts: [StockProduct], mergeDuplicates: Bool = false) -> ProductImportSummary {
        guard !importedProducts.isEmpty else {
            showToast("読み込める商品がありません")
            return ProductImportSummary(importedCount: 0, skippedCount: 0)
        }

        let importPlan = ProductImportPlanner.plan(
            importedProducts: importedProducts,
            existingNames: registeredProductNames,
            availableSlots: isProUser ? nil : max(AppPlan.freeProductLimit - products.count, 0),
            mergeDuplicates: mergeDuplicates
        )

        guard !importPlan.productsToImport.isEmpty else {
            showToast("追加できる商品がありません")
            if importPlan.limitSkippedCount > 0 {
                isShowingPaywall = true
            }
            return ProductImportSummary(importedCount: 0, skippedCount: importPlan.skippedCount)
        }

        withAnimation {
            for product in importPlan.productsToImport {
                saveProduct(product, toastMessage: nil)
            }
        }

        HapticFeedback.success()
        showToast("\(importPlan.productsToImport.count)件を読み込みました")

        if importPlan.limitSkippedCount > 0 {
            isShowingPaywall = true
        }

        return ProductImportSummary(importedCount: importPlan.productsToImport.count, skippedCount: importPlan.skippedCount)
    }

    private func item(for product: StockProduct) -> Item? {
        items.first { $0.id == product.id }
    }

    @MainActor private func purchases(for product: StockProduct) -> [PurchaseHistoryEntry] {
        purchaseRecords
            .filter { $0.itemID == product.id }
            .map(PurchaseHistoryEntry.init)
    }

    @MainActor private func usages(for product: StockProduct) -> [UsageHistoryEntry] {
        usageRecords
            .filter { $0.itemID == product.id }
            .map(UsageHistoryEntry.init)
    }

    @MainActor private func purchaseDefaults(for product: StockProduct) -> PurchaseDefaults {
        let defaults = PurchaseDefaultsService.defaults(from: purchases(for: product))
        guard !product.normalizedPreferredStore.isEmpty else { return defaults }
        return PurchaseDefaults(
            price: defaults.price,
            averagePrice: defaults.averagePrice,
            store: product.normalizedPreferredStore
        )
    }

    @MainActor private var usageHistoryEntries: [UsageHistoryEntry] {
        usageRecords.map(UsageHistoryEntry.init)
    }

    @MainActor private var purchaseHistoryEntries: [PurchaseHistoryEntry] {
        purchaseRecords.map(PurchaseHistoryEntry.init)
    }

    private var householdProfile: HouseholdProfile {
        HouseholdProfile(adults: householdAdults, children: householdChildren, pets: householdPets)
    }

    private func recordPurchase(product: StockProduct, quantity: Int, price: Int?, store: String, purchasedAt: Date = Date()) {
        guard let item = item(for: product) else { return }
        item.unopenedCount += quantity
        modelContext.insert(PurchaseRecord(
            itemID: item.id,
            itemName: item.name,
            quantity: quantity,
            price: price,
            store: store.trimmingCharacters(in: .whitespacesAndNewlines),
            purchasedAt: purchasedAt
        ))
        refreshSelectedProduct(from: item)
        HapticFeedback.success()
        showToast("ストックに\(quantity)\(product.normalizedPurchaseUnit)追加しました")
    }

    private func updateProduct(_ product: StockProduct) {
        guard let item = item(for: product) else { return }
        item.name = product.name
        item.categoryRawValue = product.category.rawValue
        item.stateRawValue = product.state.rawValue
        item.daysRemaining = product.daysRemaining
        item.unopenedCount = product.unopenedCount
        item.accuracy = product.accuracy
        item.importanceRawValue = product.importance.rawValue
        item.openedDate = product.openedDate
        item.expirationDate = product.expirationDate
        item.averageUsageDays = product.averageUsageDays
        item.usageHistoryCount = product.usageHistoryCount
        item.minimumStockCount = product.minimumStockCount
        item.purchaseUnit = product.normalizedPurchaseUnit
        item.usageScopeRawValue = product.usageScope.rawValue
        item.preferredStore = product.normalizedPreferredStore
        item.barcode = product.barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        item.purchaseURLString = product.purchaseURLString
        item.memo = product.memo
        item.storageLocation = product.storageLocation
        item.tags = product.tags
        item.photoData = product.photoData
        item.productNotificationsEnabled = product.notificationsEnabled
        selectedProduct = product
        Task {
            await NotificationService.scheduleReminder(
                for: product,
                notificationsEnabled: notificationsEnabled,
                leadDays: notificationLeadDays,
                expirationLeadDays: expirationNotificationLeadDays,
                preferredShoppingWeekday: preferredShoppingWeekday
            )
        }
        showToast("商品を更新しました")
    }

    private func savePurchaseURL(product: StockProduct, urlString: String) {
        guard let item = item(for: product) else { return }
        item.purchaseURLString = PurchaseURLFormatter.normalizedURLString(from: urlString)
        selectedProduct = StockProduct(item: item)
        showToast(item.purchaseURLString.isEmpty ? "購入先をクリアしました" : "購入先を保存しました")
    }

    private func openPurchasePage(for product: StockProduct) async {
        if let url = product.purchaseURL {
            await MainActor.run {
                openURL(url)
                showToast("購入ページを開きました")
            }
            return
        }

        let provider = PurchaseProvider(rawValue: defaultPurchaseProviderRawValue) ?? .amazon
        let query = await PurchaseSearchQueryProvider.query(for: product, usesAI: usesAIForPurchaseSearch)

        guard let url = provider.searchURL(for: query) else {
            await MainActor.run {
                showToast("購入ページを開けませんでした")
            }
            return
        }

        await MainActor.run {
            openURL(url)
            showToast("\(provider.label)で検索しました")
        }
    }

    private func deleteProduct(_ product: StockProduct) {
        guard let item = item(for: product) else { return }

        for record in purchaseRecords where record.itemID == product.id {
            modelContext.delete(record)
        }
        for record in usageRecords where record.itemID == product.id {
            modelContext.delete(record)
        }

        modelContext.delete(item)
        NotificationService.cancelReminder(for: product)
        selectedProduct = nil
        showToast("商品を削除しました")
    }

    private func deletePurchaseRecord(_ entry: PurchaseHistoryEntry) {
        guard let record = purchaseRecords.first(where: { $0.id == entry.id }) else { return }
        if let item = items.first(where: { $0.id == record.itemID }) {
            item.unopenedCount = PurchaseInventoryService.unopenedCountAfterDeletingPurchase(
                currentCount: item.unopenedCount,
                deletedQuantity: record.quantity
            )
            refreshSelectedProduct(from: item)
        }

        modelContext.delete(record)
        showToast("購入履歴を削除しました")
    }

    private func updatePurchaseRecord(_ entry: PurchaseHistoryEntry, quantity: Int, price: Int?, store: String, purchasedAt: Date) {
        guard let record = purchaseRecords.first(where: { $0.id == entry.id }) else { return }
        if let item = items.first(where: { $0.id == record.itemID }) {
            item.unopenedCount = PurchaseInventoryService.unopenedCountAfterUpdatingPurchase(
                currentCount: item.unopenedCount,
                oldQuantity: record.quantity,
                newQuantity: quantity
            )
        }

        record.quantity = quantity
        record.price = price
        record.store = store.trimmingCharacters(in: .whitespacesAndNewlines)
        record.purchasedAt = purchasedAt
        if let item = items.first(where: { $0.id == record.itemID }) {
            refreshSelectedProduct(from: item)
        }
        showToast("購入履歴を更新しました")
    }

    private func repairData() {
        var repairedCount = 0
        for product in products {
            let repairedProduct = DataRepairService.repairedProduct(product)
            if repairedProduct != product, let item = item(for: product) {
                item.name = repairedProduct.name
                item.daysRemaining = repairedProduct.daysRemaining
                item.unopenedCount = repairedProduct.unopenedCount
                item.minimumStockCount = repairedProduct.minimumStockCount
                item.averageUsageDays = repairedProduct.averageUsageDays
                item.memo = repairedProduct.memo
                item.storageLocation = repairedProduct.storageLocation
                item.tags = repairedProduct.tags
                repairedCount += 1
            }
        }
        showToast(repairedCount == 0 ? "修復する項目はありません" : "\(repairedCount)件を修復しました")
    }

    private func applyCategorySuggestions() {
        var updatedCount = 0
        for product in products {
            guard let suggestedCategory = CategoryCorrectionService.suggestedCategory(for: product),
                  let item = item(for: product) else {
                continue
            }
            item.categoryRawValue = suggestedCategory.rawValue
            updatedCount += 1
        }
        showToast(updatedCount == 0 ? "カテゴリ補正候補はありません" : "\(updatedCount)件のカテゴリを補正しました")
    }

    private func deleteUsageRecord(_ entry: UsageHistoryEntry) {
        guard let record = usageRecords.first(where: { $0.id == entry.id }) else { return }

        if let item = items.first(where: { $0.id == record.itemID }) {
            restorePredictionIfNeeded(afterDeleting: record, for: item)
        }

        modelContext.delete(record)
        if let item = items.first(where: { $0.id == record.itemID }) {
            refreshSelectedProduct(from: item)
        }
        showToast("使用履歴を削除しました")
    }

    private func extendPrediction(for product: StockProduct) {
        guard let item = item(for: product) else { return }
        let before = item.daysRemaining
        let averageBefore = item.averageUsageDays
        item.daysRemaining = (item.daysRemaining ?? item.averageUsageDays) + 3
        item.averageUsageDays += 1
        item.accuracy = "高"
        modelContext.insert(UsageRecord(
            itemID: item.id,
            itemName: item.name,
            eventRawValue: UsageEvent.stillHave.rawValue,
            daysRemainingBefore: before,
            daysRemainingAfter: item.daysRemaining,
            openedAt: item.openedDate,
            actualUsageDays: nil,
            averageUsageDaysBefore: averageBefore
        ))
        refreshSelectedProduct(from: item)
        HapticFeedback.light()
        showToast("予測を少し延ばしました")
    }

    private func finishUsing(product: StockProduct, finishedAt: Date = Date()) {
        guard let item = item(for: product) else { return }
        let before = item.daysRemaining
        let openedAt = item.openedDate
        let averageBefore = item.averageUsageDays
        let actualUsageDays = UsagePredictionService.actualUsageDays(from: openedAt, to: finishedAt)
        let historicalUsageDays = usageRecords
            .filter { $0.itemID == item.id }
            .compactMap(\.actualUsageDays)
        let learnedAverage = UsagePredictionService.updatedAverage(
            currentAverage: item.averageUsageDays,
            actualUsageDays: actualUsageDays,
            historicalUsageDays: historicalUsageDays
        )
        item.usageHistoryCount += 1
        item.averageUsageDays = learnedAverage

        if item.unopenedCount > 0 {
            item.unopenedCount -= 1
            item.stateRawValue = ProductState.inUse.rawValue
            item.daysRemaining = learnedAverage
            item.openedDate = finishedAt
        } else {
            item.stateRawValue = ProductState.unopened.rawValue
            item.daysRemaining = nil
            item.openedDate = nil
        }

        item.accuracy = "高"
        modelContext.insert(UsageRecord(
            itemID: item.id,
            itemName: item.name,
            eventRawValue: UsageEvent.finished.rawValue,
            daysRemainingBefore: before,
            daysRemainingAfter: item.daysRemaining,
            openedAt: openedAt,
            actualUsageDays: actualUsageDays,
            averageUsageDaysBefore: averageBefore,
            recordedAt: finishedAt
        ))
        refreshSelectedProduct(from: item)
        HapticFeedback.success()
        Task {
            let comment = await UsageInsightService.comment(
                productName: item.name,
                actualUsageDays: actualUsageDays,
                previousAverage: averageBefore,
                learnedAverage: learnedAverage
            )
            showToast(comment)
        }
    }

    private func openProduct(product: StockProduct, openedAt: Date = Date()) {
        guard let item = item(for: product) else { return }
        let before = item.daysRemaining
        let adjustedDays = HouseholdUsageAdjustmentService.adjustedDays(
            baseDays: item.averageUsageDays,
            category: ProductCategory(rawValue: item.categoryRawValue) ?? .other,
            profile: householdProfile.scoped(to: UsageScope(rawValue: item.usageScopeRawValue) ?? .household)
        )
        item.stateRawValue = ProductState.inUse.rawValue
        item.daysRemaining = adjustedDays
        item.openedDate = openedAt
        item.unopenedCount = max(item.unopenedCount - 1, 0)
        modelContext.insert(UsageRecord(
            itemID: item.id,
            itemName: item.name,
            eventRawValue: UsageEvent.opened.rawValue,
            daysRemainingBefore: before,
            daysRemainingAfter: item.daysRemaining,
            openedAt: item.openedDate,
            actualUsageDays: nil,
            averageUsageDaysBefore: item.averageUsageDays,
            recordedAt: openedAt
        ))
        refreshSelectedProduct(from: item)
        HapticFeedback.success()
        showToast("使用中にしました")
    }

    private func restorePredictionIfNeeded(afterDeleting record: UsageRecord, for item: Item) {
        let event = UsageEvent(rawValue: record.eventRawValue)

        switch event {
        case .finished:
            item.usageHistoryCount = max(item.usageHistoryCount - 1, 0)
            item.averageUsageDays = UsagePredictionService.restoredAverage(
                currentAverage: item.averageUsageDays,
                previousAverage: record.averageUsageDaysBefore,
                remainingActualUsageDays: usageRecords
                    .filter { $0.itemID == item.id && $0.id != record.id }
                    .compactMap(\.actualUsageDays)
            )
        case .stillHave:
            item.daysRemaining = record.daysRemainingBefore
            if let previousAverage = record.averageUsageDaysBefore {
                item.averageUsageDays = previousAverage
            }
        case .opened, .none:
            break
        }
    }

    private func refreshSelectedProduct(from item: Item) {
        guard selectedProduct?.id == item.id else { return }
        selectedProduct = StockProduct(item: item)
    }

    private func requestNotificationAuthorization() async {
        _ = await NotificationService.requestAuthorization()
    }

    private func rescheduleAllNotifications() {
        Task {
            if !notificationsEnabled {
                NotificationService.cancelReminders(for: products)
                showToast("通知設定を更新しました")
                return
            }

            for product in products {
                await NotificationService.scheduleReminder(
                    for: product,
                    notificationsEnabled: notificationsEnabled,
                    leadDays: notificationLeadDays,
                    expirationLeadDays: expirationNotificationLeadDays,
                    preferredShoppingWeekday: preferredShoppingWeekday
                )
            }
            showToast("通知設定を更新しました")
        }
    }

    private func sendTestNotification() async {
        let authorized = await NotificationService.requestAuthorization()
        guard authorized else {
            showToast("通知が許可されていません")
            return
        }

        await NotificationService.scheduleTestNotification()
        showToast("テスト通知を送信しました")
    }
}

nonisolated enum UsagePredictionService {
    static func initialDaysRemaining(totalDays: Int, openedAt: Date, currentDate: Date = Date(), calendar: Calendar = .current) -> Int {
        let openedDay = calendar.startOfDay(for: openedAt)
        let currentDay = calendar.startOfDay(for: currentDate)
        let elapsedDays = max(calendar.dateComponents([.day], from: openedDay, to: currentDay).day ?? 0, 0)
        return min(max(totalDays - elapsedDays, 1), 365)
    }

    static func actualUsageDays(from openedAt: Date?, to finishedAt: Date, calendar: Calendar = .current) -> Int? {
        guard let openedAt else { return nil }
        let start = calendar.startOfDay(for: openedAt)
        let end = calendar.startOfDay(for: finishedAt)
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return min(max(days + 1, 1), 365)
    }

    static func updatedAverage(currentAverage: Int, actualUsageDays: Int?, historicalUsageDays: [Int]) -> Int {
        guard let actualUsageDays else { return currentAverage }

        let recentHistory = Array(historicalUsageDays.suffix(4))
        let weightedTotal = (currentAverage * 2) + actualUsageDays + recentHistory.reduce(0, +)
        let weight = 3 + recentHistory.count
        return min(max(Int((Double(weightedTotal) / Double(weight)).rounded()), 1), 365)
    }

    static func restoredAverage(currentAverage: Int, previousAverage: Int?, remainingActualUsageDays: [Int]) -> Int {
        if let previousAverage {
            return min(max(previousAverage, 1), 365)
        }

        guard !remainingActualUsageDays.isEmpty else { return currentAverage }

        let total = remainingActualUsageDays.reduce(0, +)
        return min(max(Int((Double(total) / Double(remainingActualUsageDays.count)).rounded()), 1), 365)
    }
}

nonisolated enum ExpirationService {
    static func daysRemaining(until expirationDate: Date?, from currentDate: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let expirationDate else { return nil }
        let start = calendar.startOfDay(for: currentDate)
        let end = calendar.startOfDay(for: expirationDate)
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    static func displayText(for expirationDate: Date?, from currentDate: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let daysRemaining = daysRemaining(until: expirationDate, from: currentDate, calendar: calendar) else { return nil }
        if daysRemaining < 0 { return "期限切れ" }
        if daysRemaining == 0 { return "今日まで" }
        return "期限まで\(daysRemaining)日"
    }

    static func isSoon(_ expirationDate: Date?, from currentDate: Date = Date(), thresholdDays: Int = 30, calendar: Calendar = .current) -> Bool {
        guard let daysRemaining = daysRemaining(until: expirationDate, from: currentDate, calendar: calendar) else { return false }
        return daysRemaining <= thresholdDays
    }
}

nonisolated enum JapaneseDateFormatter {
    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "ja_JP")).month(.defaultDigits).day())
    }

    static func fullDate(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "ja_JP")).year().month(.defaultDigits).day())
    }
}

nonisolated enum JapaneseCurrencyFormatter {
    static func yen(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.numberStyle = .decimal
        let numberText = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        return "\(numberText)円"
    }
}

struct HouseholdProfile: Equatable {
    var adults: Int
    var children: Int
    var pets: Int

    nonisolated var normalized: HouseholdProfile {
        HouseholdProfile(
            adults: min(max(adults, 1), 10),
            children: min(max(children, 0), 10),
            pets: min(max(pets, 0), 10)
        )
    }

    nonisolated var displayText: String {
        let profile = normalized
        var parts = ["大人\(profile.adults)人"]
        if profile.children > 0 {
            parts.append("子ども\(profile.children)人")
        }
        if profile.pets > 0 {
            parts.append("ペット\(profile.pets)匹")
        }
        return parts.joined(separator: "・")
    }

    nonisolated func scoped(to scope: UsageScope) -> HouseholdProfile {
        let profile = normalized
        switch scope {
        case .household:
            return profile
        case .adults:
            return HouseholdProfile(adults: profile.adults, children: 0, pets: 0)
        case .children:
            return HouseholdProfile(adults: 1, children: max(profile.children, 1), pets: 0)
        case .pets:
            return HouseholdProfile(adults: 1, children: 0, pets: max(profile.pets, 1))
        }
    }
}

nonisolated enum HouseholdUsageAdjustmentService {
    static func adjustedDays(baseDays: Int, category: ProductCategory, profile: HouseholdProfile) -> Int {
        let normalizedProfile = profile.normalized
        let clampedBaseDays = min(max(baseDays, 1), 365)
        let multiplier = consumptionMultiplier(category: category, profile: normalizedProfile)
        return min(max(Int((Double(clampedBaseDays) / multiplier).rounded()), 1), 365)
    }

    static func description(baseDays: Int, category: ProductCategory, profile: HouseholdProfile) -> String {
        let adjusted = adjustedDays(baseDays: baseDays, category: category, profile: profile)
        if adjusted == min(max(baseDays, 1), 365) {
            return "世帯構成による補正なし"
        }
        return "\(profile.normalized.displayText)を考慮して約\(adjusted)日に補正"
    }

    private static func consumptionMultiplier(category: ProductCategory, profile: HouseholdProfile) -> Double {
        let peopleMultiplier = 1.0 + (Double(max(profile.adults - 1, 0)) * 0.35) + (Double(profile.children) * 0.25)

        switch category {
        case .laundry, .bath, .daily, .food:
            return min(max(peopleMultiplier, 1.0), 5.0)
        case .pet:
            let petMultiplier = 1.0 + (Double(max(profile.pets, 0)) * 0.55)
            return min(max(petMultiplier, 1.0), 5.0)
        case .other:
            return 1.0
        }
    }
}

nonisolated enum AppDataCSVExportService {
    static func exportText(for products: [StockProduct]) -> String {
        let header = ["商品名", "カテゴリ", "状態", "残り日数", "未開封数", "最低ストック", "購入単位", "利用対象", "優先店舗", "バーコード", "平均使用日数", "重要度", "置き場所", "タグ", "メモ"]
        let rows = products.map { product in
            [
                product.name,
                product.category.rawValue,
                product.state.rawValue,
                product.daysRemaining.map(String.init) ?? "",
                String(product.unopenedCount),
                String(product.minimumStockCount),
                product.normalizedPurchaseUnit,
                product.usageScope.rawValue,
                product.normalizedPreferredStore,
                product.barcode,
                String(product.averageUsageDays),
                product.importance.rawValue,
                product.storageLocation,
                product.tags,
                product.memo
            ]
        }

        return ([header] + rows)
            .map { $0.map(csvEscaped).joined(separator: ",") }
            .joined(separator: "\n")
    }

    static func purchaseHistoryText(for purchases: [PurchaseHistoryEntry]) -> String {
        let header = ["購入日", "商品名", "数量", "価格", "店舗"]
        let rows = purchases.map { purchase in
            [
                JapaneseDateFormatter.fullDate(purchase.purchasedAt),
                purchase.itemName,
                String(purchase.quantity),
                purchase.price.map(String.init) ?? "",
                purchase.store
            ]
        }

        return ([header] + rows)
            .map { $0.map(csvEscaped).joined(separator: ",") }
            .joined(separator: "\n")
    }

    private static func csvEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\n") || escaped.contains("\"") {
            return "\"\(escaped)\""
        }
        return escaped
    }
}

nonisolated enum AppDiagnosticsService {
    static func diagnostics(for products: [StockProduct], purchases: [PurchaseHistoryEntry] = [], monthlyBudget: Int = 0) -> [AppDiagnostic] {
        let emptyNameCount = products.filter { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let normalizedNames = products.map(\.name.normalizedProductName).filter { !$0.isEmpty }
        let duplicateCount = normalizedNames.count - Set(normalizedNames).count
        let barcodes = products.map(\.barcode).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let duplicateBarcodeCount = barcodes.count - Set(barcodes).count
        let missingStoreCount = products.filter { $0.normalizedPreferredStore.isEmpty }.count
        let lowConfidenceCount = products.filter { $0.state == .inUse && $0.usageHistoryCount == 0 }.count
        let expiredCount = products.filter { (ExpirationService.daysRemaining(until: $0.expirationDate) ?? 1) < 0 }.count
        let notificationOffCount = products.filter { !$0.notificationsEnabled }.count
        let notificationTargetCount = NotificationSchedulePreviewService.previews(
            for: products,
            notificationsEnabled: true,
            leadDays: 3,
            expirationLeadDays: 7
        ).count
        let overstockedCount = products.filter {
            !$0.state.rawValue.isEmpty
                && PurchaseRecommendationService.recommendation(
                    for: $0,
                    householdProfile: HouseholdProfile(adults: 1, children: 0, pets: 0)
                ).shouldBuy == false
        }.count
        let spendingSummary = PurchaseSpendingSummaryService.summary(from: purchases, products: products)
        let spendingAttentionNeeded = spendingSummary.previousMonthTotal > 0
            && spendingSummary.currentMonthTotal > spendingSummary.previousMonthTotal * 2
        let budgetExceeded = monthlyBudget > 0 && spendingSummary.currentMonthTotal > monthlyBudget

        return [
            AppDiagnostic(title: "空の商品名", value: "\(emptyNameCount)件", isAttentionNeeded: emptyNameCount > 0),
            AppDiagnostic(title: "重複候補", value: "\(duplicateCount)件", isAttentionNeeded: duplicateCount > 0),
            AppDiagnostic(title: "バーコード重複", value: "\(duplicateBarcodeCount)件", isAttentionNeeded: duplicateBarcodeCount > 0),
            AppDiagnostic(title: "期限切れ", value: "\(expiredCount)件", isAttentionNeeded: expiredCount > 0),
            AppDiagnostic(title: "店舗未設定", value: "\(missingStoreCount)件", isAttentionNeeded: false),
            AppDiagnostic(title: "予測学習前", value: "\(lowConfidenceCount)件", isAttentionNeeded: lowConfidenceCount > 0),
            AppDiagnostic(title: "商品別通知オフ", value: "\(notificationOffCount)件", isAttentionNeeded: false),
            AppDiagnostic(title: "通知対象なし", value: notificationTargetCount == 0 && !products.isEmpty ? "確認" : "OK", isAttentionNeeded: notificationTargetCount == 0 && !products.isEmpty),
            AppDiagnostic(title: "買いすぎ候補", value: "\(overstockedCount)件", isAttentionNeeded: false),
            AppDiagnostic(title: "今月支出", value: JapaneseCurrencyFormatter.yen(spendingSummary.currentMonthTotal), isAttentionNeeded: spendingAttentionNeeded),
            AppDiagnostic(title: "予算", value: budgetExceeded ? "超過" : "OK", isAttentionNeeded: budgetExceeded)
        ]
    }
}

struct AppDiagnostic: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let value: String
    let isAttentionNeeded: Bool
}

nonisolated enum PredictionConfidenceService {
    static func explanation(for product: StockProduct) -> String {
        if product.usageHistoryCount >= 3 {
            return "使用履歴\(product.usageHistoryCount)回から高め"
        }
        if product.usageHistoryCount > 0 {
            return "使用履歴\(product.usageHistoryCount)回から学習中"
        }
        return "初期推定"
    }
}

nonisolated enum CategoryCorrectionService {
    static func suggestedCategory(for product: StockProduct) -> ProductCategory? {
        let inferred = ProductCategoryInferenceService.category(for: product.name)
        return inferred != .other && inferred != product.category ? inferred : nil
    }
}

nonisolated enum DataRepairService {
    static func repairedProduct(_ product: StockProduct) -> StockProduct {
        var repaired = product
        repaired.name = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
        repaired.unopenedCount = max(product.unopenedCount, 0)
        repaired.minimumStockCount = max(product.minimumStockCount, 0)
        repaired.purchaseUnit = product.normalizedPurchaseUnit
        repaired.preferredStore = product.normalizedPreferredStore
        repaired.barcode = product.barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        repaired.averageUsageDays = min(max(product.averageUsageDays, 1), 365)
        repaired.daysRemaining = product.daysRemaining.map { min(max($0, 1), 365) }
        repaired.memo = product.memo.trimmingCharacters(in: .whitespacesAndNewlines)
        repaired.storageLocation = product.storageLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        repaired.tags = product.tags.trimmingCharacters(in: .whitespacesAndNewlines)
        return repaired
    }
}

struct HomeRiskSummary: Equatable {
    let expiredCount: Int
    let overstockedCount: Int
    let lowConfidenceCount: Int
}

nonisolated enum HomeRiskSummaryService {
    static func summary(for products: [StockProduct]) -> HomeRiskSummary {
        HomeRiskSummary(
            expiredCount: products.filter { (ExpirationService.daysRemaining(until: $0.expirationDate) ?? 1) < 0 }.count,
            overstockedCount: products.filter {
                PurchaseRecommendationService.recommendation(for: $0, householdProfile: HouseholdProfile(adults: 1, children: 0, pets: 0)).shouldBuy == false
            }.count,
            lowConfidenceCount: products.filter { $0.usageHistoryCount == 0 && $0.state == .inUse }.count
        )
    }
}

struct NotificationSchedulePreview: Identifiable, Equatable {
    var id: String { "\(productID.uuidString)-\(kind.rawValue)" }
    let productID: UUID
    let productName: String
    let kind: Kind
    let daysUntilReminder: Int

    enum Kind: String {
        case refill = "補充"
        case expiration = "期限"
    }

    nonisolated var displayText: String {
        let timingText: String
        if daysUntilReminder <= 1 {
            timingText = "明日"
        } else {
            timingText = "約\(daysUntilReminder)日後"
        }
        return "\(timingText)・\(productName)（\(kind.rawValue)）"
    }
}

nonisolated enum NotificationSchedulePreviewService {
    static func previews(
        for products: [StockProduct],
        notificationsEnabled: Bool,
        leadDays: Int,
        expirationLeadDays: Int,
        preferredShoppingWeekday: Int = 0
    ) -> [NotificationSchedulePreview] {
        guard notificationsEnabled else { return [] }

        return products
            .filter(\.notificationsEnabled)
            .flatMap { product in
                previews(for: product, leadDays: leadDays, expirationLeadDays: expirationLeadDays, preferredShoppingWeekday: preferredShoppingWeekday)
            }
            .sorted { lhs, rhs in
                if lhs.daysUntilReminder != rhs.daysUntilReminder {
                    return lhs.daysUntilReminder < rhs.daysUntilReminder
                }
                return lhs.productName.localizedStandardCompare(rhs.productName) == .orderedAscending
            }
    }

    static func nextReminderText(
        for products: [StockProduct],
        notificationsEnabled: Bool,
        leadDays: Int,
        expirationLeadDays: Int,
        preferredShoppingWeekday: Int = 0
    ) -> String {
        previews(
            for: products,
            notificationsEnabled: notificationsEnabled,
            leadDays: leadDays,
            expirationLeadDays: expirationLeadDays,
            preferredShoppingWeekday: preferredShoppingWeekday
        )
        .first?
        .displayText ?? "対象なし"
    }

    private static func previews(for product: StockProduct, leadDays: Int, expirationLeadDays: Int, preferredShoppingWeekday: Int) -> [NotificationSchedulePreview] {
        var previews: [NotificationSchedulePreview] = []

        if let daysRemaining = product.daysRemaining {
            previews.append(NotificationSchedulePreview(
                productID: product.id,
                productName: product.name,
                kind: .refill,
                daysUntilReminder: NotificationService.refillReminderPreviewDays(
                    daysRemaining: daysRemaining,
                    leadDays: leadDays,
                    preferredShoppingWeekday: preferredShoppingWeekday
                )
            ))
        }

        if let expirationDaysRemaining = ExpirationService.daysRemaining(until: product.expirationDate), expirationDaysRemaining >= 0 {
            previews.append(NotificationSchedulePreview(
                productID: product.id,
                productName: product.name,
                kind: .expiration,
                daysUntilReminder: max(expirationDaysRemaining - expirationLeadDays, 1)
            ))
        }

        return previews
    }
}

private struct PurchaseStats: Equatable {
    let latestPrice: Int?
    let averagePrice: Int?
    let frequentStore: String?
    let purchaseCount: Int

    init(purchases: [PurchaseHistoryEntry]) {
        purchaseCount = purchases.count
        latestPrice = purchases.first?.price

        let prices = purchases.compactMap(\.price)
        if prices.isEmpty {
            averagePrice = nil
        } else {
            averagePrice = Int((Double(prices.reduce(0, +)) / Double(prices.count)).rounded())
        }

        frequentStore = Dictionary(grouping: purchases.map(\.store).filter { !$0.isEmpty }, by: { $0 })
            .max { lhs, rhs in lhs.value.count < rhs.value.count }?
            .key
    }
}

struct PurchaseDefaults: Equatable {
    let price: Int?
    let averagePrice: Int?
    let store: String

    nonisolated static let empty = PurchaseDefaults(price: nil, averagePrice: nil, store: "")
}

nonisolated enum PurchaseDefaultsService {
    static func defaults(from purchases: [PurchaseHistoryEntry]) -> PurchaseDefaults {
        guard !purchases.isEmpty else { return .empty }

        let latestPrice = purchases.first?.price
        let prices = purchases.compactMap(\.price)
        let averagePrice = prices.isEmpty ? nil : Int((Double(prices.reduce(0, +)) / Double(prices.count)).rounded())
        let frequentStore = Dictionary(grouping: purchases.map(\.store).filter { !$0.isEmpty }, by: { $0 })
            .max { lhs, rhs in lhs.value.count < rhs.value.count }?
            .key

        return PurchaseDefaults(
            price: latestPrice,
            averagePrice: averagePrice,
            store: frequentStore ?? purchases.first?.store ?? ""
        )
    }
}

struct PriceComparison: Equatable {
    enum Direction: Equatable {
        case higher
        case lower
        case usual
    }

    let direction: Direction
    let message: String
}

nonisolated enum PriceComparisonService {
    static func comparison(currentPrice: Int?, averagePrice: Int?) -> PriceComparison? {
        guard let currentPrice, currentPrice > 0, let averagePrice, averagePrice > 0 else {
            return nil
        }

        let ratio = Double(currentPrice - averagePrice) / Double(averagePrice)
        if ratio >= 0.10 {
            return PriceComparison(
                direction: .higher,
                message: "平均より約\(Int((ratio * 100).rounded()))%高めです"
            )
        }

        if ratio <= -0.10 {
            return PriceComparison(
                direction: .lower,
                message: "平均より約\(Int((abs(ratio) * 100).rounded()))%安めです"
            )
        }

        return PriceComparison(direction: .usual, message: "いつもの価格帯です")
    }
}

struct PurchaseCategorySpending: Equatable, Identifiable {
    var id: String { category.rawValue }
    let category: ProductCategory
    let total: Int
}

struct PurchaseSpendingSummary: Equatable {
    let currentMonthTotal: Int
    let previousMonthTotal: Int
    let currentMonthCount: Int
    let topStore: String?
    let categoryTotals: [PurchaseCategorySpending]

    var differenceFromPreviousMonth: Int {
        currentMonthTotal - previousMonthTotal
    }

    var trendText: String {
        if differenceFromPreviousMonth > 0 {
            return "先月より\(JapaneseCurrencyFormatter.yen(differenceFromPreviousMonth))多め"
        }

        if differenceFromPreviousMonth < 0 {
            return "先月より\(JapaneseCurrencyFormatter.yen(abs(differenceFromPreviousMonth)))少なめ"
        }

        return previousMonthTotal == 0 && currentMonthTotal == 0 ? "支出記録なし" : "先月と同じ"
    }
}

nonisolated enum PurchaseSpendingSummaryService {
    static func summary(
        from purchases: [PurchaseHistoryEntry],
        products: [StockProduct] = [],
        currentDate: Date = Date(),
        calendar: Calendar = .current
    ) -> PurchaseSpendingSummary {
        let currentMonthInterval = monthInterval(containing: currentDate, calendar: calendar)
        let previousMonthDate = calendar.date(byAdding: .month, value: -1, to: currentMonthInterval.start) ?? currentDate
        let previousMonthInterval = monthInterval(containing: previousMonthDate, calendar: calendar)

        let currentMonthPurchases = purchases.filter {
            currentMonthInterval.contains($0.purchasedAt) && $0.price != nil
        }
        let previousMonthPurchases = purchases.filter {
            previousMonthInterval.contains($0.purchasedAt) && $0.price != nil
        }

        let currentMonthTotal = currentMonthPurchases.compactMap(\.price).reduce(0, +)
        let previousMonthTotal = previousMonthPurchases.compactMap(\.price).reduce(0, +)
        let topStore = Dictionary(grouping: currentMonthPurchases.map(\.store).filter { !$0.isEmpty }, by: { $0 })
            .max { lhs, rhs in lhs.value.count < rhs.value.count }?
            .key
        let productCategoriesByName = Dictionary(uniqueKeysWithValues: products.map { ($0.name.normalizedProductName, $0.category) })
        let categoryTotals = Dictionary(grouping: currentMonthPurchases, by: { purchase in
            productCategoriesByName[purchase.itemName.normalizedProductName] ?? ProductCategoryInferenceService.category(for: purchase.itemName)
        })
        .map { category, purchases in
            PurchaseCategorySpending(category: category, total: purchases.compactMap(\.price).reduce(0, +))
        }
        .filter { $0.total > 0 }
        .sorted { lhs, rhs in
            if lhs.total != rhs.total {
                return lhs.total > rhs.total
            }
            return lhs.category.rawValue.localizedStandardCompare(rhs.category.rawValue) == .orderedAscending
        }

        return PurchaseSpendingSummary(
            currentMonthTotal: currentMonthTotal,
            previousMonthTotal: previousMonthTotal,
            currentMonthCount: currentMonthPurchases.count,
            topStore: topStore,
            categoryTotals: categoryTotals
        )
    }

    private static func monthInterval(containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 0)
    }
}

nonisolated enum AppDataExportService {
    static func exportText(for products: [StockProduct], generatedAt: Date = Date()) -> String {
        let export = AppDataExport(
            appName: "あとどれ？",
            schemaVersion: 1,
            generatedAt: generatedAt,
            products: products.map(ProductExportSnapshot.init)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard
            let data = try? encoder.encode(export),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }

        return text
    }

    static func importProducts(from text: String) throws -> [StockProduct] {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(AppDataExport.self, from: data)
        return export.products.map(\.product)
    }
}

nonisolated private struct AppDataExport: Codable {
    let appName: String
    let schemaVersion: Int
    let generatedAt: Date
    let products: [ProductExportSnapshot]
}

nonisolated private struct ProductExportSnapshot: Codable {
    let id: UUID
    let name: String
    let category: String
    let state: String
    let daysRemaining: Int?
    let unopenedCount: Int
    let accuracy: String
    let importance: String
    let openedDate: Date?
    let expirationDate: Date?
    let averageUsageDays: Int
    let usageHistoryCount: Int
    let minimumStockCount: Int?
    let purchaseUnit: String?
    let usageScope: String?
    let preferredStore: String?
    let barcode: String?
    let purchaseURLString: String
    let memo: String?
    let storageLocation: String?
    let tags: String?
    let notificationsEnabled: Bool

    init(product: StockProduct) {
        id = product.id
        name = product.name
        category = product.category.rawValue
        state = product.state.rawValue
        daysRemaining = product.daysRemaining
        unopenedCount = product.unopenedCount
        accuracy = product.accuracy
        importance = product.importance.rawValue
        openedDate = product.openedDate
        expirationDate = product.expirationDate
        averageUsageDays = product.averageUsageDays
        usageHistoryCount = product.usageHistoryCount
        minimumStockCount = product.minimumStockCount
        purchaseUnit = product.normalizedPurchaseUnit
        usageScope = product.usageScope.rawValue
        preferredStore = product.normalizedPreferredStore
        barcode = product.barcode
        purchaseURLString = product.purchaseURLString
        memo = product.memo
        storageLocation = product.storageLocation
        tags = product.tags
        notificationsEnabled = product.notificationsEnabled
    }

    var product: StockProduct {
        StockProduct(
            id: id,
            name: name,
            category: ProductCategory(rawValue: category) ?? .other,
            state: ProductState(rawValue: state) ?? .inUse,
            daysRemaining: daysRemaining,
            unopenedCount: unopenedCount,
            accuracy: accuracy,
            importance: Importance(rawValue: importance) ?? .medium,
            openedDate: openedDate,
            expirationDate: expirationDate,
            averageUsageDays: averageUsageDays,
            usageHistoryCount: usageHistoryCount,
            minimumStockCount: minimumStockCount ?? 0,
            purchaseUnit: purchaseUnit ?? "個",
            usageScope: UsageScope(rawValue: usageScope ?? "") ?? .household,
            preferredStore: preferredStore ?? "",
            barcode: barcode ?? "",
            purchaseURLString: purchaseURLString,
            memo: memo ?? "",
            storageLocation: storageLocation ?? "",
            tags: tags ?? "",
            notificationsEnabled: notificationsEnabled
        )
    }
}

struct ProductImportSummary: Equatable {
    let importedCount: Int
    let skippedCount: Int

    var message: String {
        if importedCount == 0 && skippedCount == 0 {
            return "読み込める商品がありませんでした。"
        }

        if skippedCount == 0 {
            return "\(importedCount)件の商品を読み込みました。"
        }

        return "\(importedCount)件の商品を読み込みました。\(skippedCount)件は登録上限または重複のためスキップしました。"
    }
}

struct ProductImportPlan {
    let productsToImport: [StockProduct]
    let skippedCount: Int
    let limitSkippedCount: Int
    let mergedDuplicateCount: Int
}

nonisolated enum ProductImportPlanner {
    static func plan(importedProducts: [StockProduct], existingNames: Set<String>, availableSlots: Int?, mergeDuplicates: Bool = false) -> ProductImportPlan {
        var remainingSlots = availableSlots ?? Int.max
        var newProductNames = Set<String>()
        var productsToImport: [StockProduct] = []
        var skippedCount = 0
        var limitSkippedCount = 0
        var mergedDuplicateCount = 0

        for product in importedProducts {
            let normalizedName = product.name.normalizedProductName
            guard !normalizedName.isEmpty else {
                skippedCount += 1
                continue
            }

            if existingNames.contains(normalizedName) || newProductNames.contains(normalizedName) {
                if mergeDuplicates {
                    productsToImport.append(product)
                    mergedDuplicateCount += 1
                } else {
                    skippedCount += 1
                }
            } else if remainingSlots > 0 {
                productsToImport.append(product)
                newProductNames.insert(normalizedName)
                remainingSlots -= 1
            } else {
                skippedCount += 1
                limitSkippedCount += 1
            }
        }

        return ProductImportPlan(
            productsToImport: productsToImport,
            skippedCount: skippedCount,
            limitSkippedCount: limitSkippedCount,
            mergedDuplicateCount: mergedDuplicateCount
        )
    }
}

nonisolated enum ShoppingMemoService {
    static func memoText(for products: [StockProduct], householdProfile: HouseholdProfile? = nil) -> String {
        let sortedProducts = products.sorted { lhs, rhs in
            (lhs.daysRemaining ?? .max) < (rhs.daysRemaining ?? .max)
        }
        guard !sortedProducts.isEmpty else {
            return "あとどれ？ 買い物メモ\n\n今日は買うものはありません。"
        }

        let lines = sortedProducts.map { product in
            let usageText = product.daysRemaining.map { "約\($0)日" } ?? "未開封"
            let detail = product.state == .unopened ? "ストック\(product.unopenedCount)\(product.normalizedPurchaseUnit)" : "あと\(usageText)"
            let recommendation = householdProfile.map {
                PurchaseRecommendationService.recommendation(for: product, householdProfile: $0)
            }
            let quantityText = recommendation.map { " / おすすめ\($0.quantity)\(product.normalizedPurchaseUnit)" } ?? ""
            return "- \(product.name)（\(product.category.rawValue) / \(detail)\(quantityText)）"
        }
        let profileLine = householdProfile.map { "世帯: \($0.displayText)" }
        return (["あとどれ？ 買い物メモ", profileLine, ""].compactMap { $0 } + lines).joined(separator: "\n")
    }

    static func intelligentMemoText(for products: [StockProduct], householdProfile: HouseholdProfile? = nil) async -> String {
#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *),
           let memo = await foundationModelMemoText(for: products, householdProfile: householdProfile) {
            return memo
        }
#endif

        return memoText(for: products, householdProfile: householdProfile)
    }

#if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func foundationModelMemoText(for products: [StockProduct], householdProfile: HouseholdProfile?) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability, !products.isEmpty else { return nil }

        do {
            let session = LanguageModelSession(instructions: """
            The person's locale is ja_JP.
            Create a short shopping memo grouped for easy use in a store.
            Consider household composition when prioritizing fast-consuming items.
            Keep the title "あとどれ？ 買い物メモ".
            Use concise bullet lines. Do not add explanations.
            """)
            let productText = products.map { product in
                let daysText = product.daysRemaining.map { "約\($0)日" } ?? "未開封"
                let recommendation = householdProfile.map {
                    PurchaseRecommendationService.recommendation(for: product, householdProfile: $0)
                }
                return "\(product.name) / \(product.category.rawValue) / \(product.state.rawValue) / \(daysText) / おすすめ数量:\(recommendation?.quantity ?? 1) / 理由:\(recommendation?.reason ?? "") / メモ:\(product.memo)"
            }.joined(separator: "\n")
            let response = try await session.respond(to: Prompt("世帯: \(householdProfile?.displayText ?? "未設定")\n\(productText)"))
            let text = String(response.content).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
#endif
}

struct ShoppingStoreGroup: Identifiable, Equatable {
    var id: String { storeName }
    let storeName: String
    let products: [StockProduct]
}

nonisolated enum StoreShoppingListService {
    static func groups(products: [StockProduct], preferredStore: (StockProduct) -> String) -> [ShoppingStoreGroup] {
        let grouped = Dictionary(grouping: products) { product in
            let store = preferredStore(product).trimmingCharacters(in: .whitespacesAndNewlines)
            return store.isEmpty ? "店舗未設定" : store
        }

        return grouped
            .map { storeName, products in
                ShoppingStoreGroup(
                    storeName: storeName,
                    products: products.sorted { lhs, rhs in
                        if (lhs.daysRemaining ?? .max) != (rhs.daysRemaining ?? .max) {
                            return (lhs.daysRemaining ?? .max) < (rhs.daysRemaining ?? .max)
                        }
                        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                )
            }
            .sorted { lhs, rhs in
                if lhs.storeName == "店舗未設定" { return false }
                if rhs.storeName == "店舗未設定" { return true }
                return lhs.storeName.localizedStandardCompare(rhs.storeName) == .orderedAscending
            }
    }

    static func memoText(groups: [ShoppingStoreGroup], householdProfile: HouseholdProfile) -> String {
        guard !groups.isEmpty else {
            return "あとどれ？ 買い物メモ\n\n今日は買うものはありません。"
        }

        let sections = groups.map { group in
            let lines = group.products.map { product in
                let recommendation = PurchaseRecommendationService.recommendation(for: product, householdProfile: householdProfile)
                return "- [ ] \(product.name) \(recommendation.quantity)\(product.normalizedPurchaseUnit)（\(recommendation.reason)）"
            }
            return (["【\(group.storeName)】"] + lines).joined(separator: "\n")
        }

        return (["あとどれ？ 買い物メモ", "世帯: \(householdProfile.displayText)", ""] + sections).joined(separator: "\n\n")
    }
}

nonisolated enum WidgetSnapshotService {
    static func snapshotText(for products: [StockProduct]) -> String {
        let buyNow = products.filter { product in
            product.state == .inUse && (product.daysRemaining ?? .max) <= 7
        }.count
        let expiring = products.filter { $0.isExpirationSoon }.count
        let nextProduct = products
            .filter { $0.state == .inUse }
            .sorted { ($0.daysRemaining ?? .max) < ($1.daysRemaining ?? .max) }
            .first

        let nextText = nextProduct.map { "\($0.name): \($0.daysText)" } ?? "対象なし"
        return "あとどれ？\n買うもの \(buyNow)件\n期限注意 \(expiring)件\n次: \(nextText)"
    }
}

private enum HomeInsightTextProvider {
    static func text(for products: [StockProduct], fallback: String) async -> String {
#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *),
           let text = await foundationModelText(for: products) {
            return text
        }
#endif

        return fallback
    }

#if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func foundationModelText(for products: [StockProduct]) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability, !products.isEmpty else { return nil }

        do {
            let session = LanguageModelSession(instructions: """
            The person's locale is ja_JP.
            Write one concise home inventory insight sentence.
            Mention only what the person should check today.
            Keep it under 60 Japanese characters.
            """)
            let productText = products.map { product in
                "\(product.name): \(product.category.rawValue), \(product.state.rawValue), \(product.daysText), 期限:\(product.expirationText ?? "なし"), メモ:\(product.memo)"
            }.joined(separator: "\n")
            let response = try await session.respond(to: Prompt(productText))
            let text = String(response.content)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
#endif
}

nonisolated enum UsageInsightService {
    static func comment(productName: String, actualUsageDays: Int?, previousAverage: Int, learnedAverage: Int) async -> String {
        let fallback = fallbackComment(actualUsageDays: actualUsageDays, previousAverage: previousAverage, learnedAverage: learnedAverage)

#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *),
           let comment = await foundationModelComment(productName: productName, actualUsageDays: actualUsageDays, previousAverage: previousAverage, learnedAverage: learnedAverage) {
            return comment
        }
#endif

        return fallback
    }

    static func fallbackComment(actualUsageDays: Int?, previousAverage: Int, learnedAverage: Int) -> String {
        guard let actualUsageDays else {
            return "予測を更新しました"
        }

        if actualUsageDays + 3 < previousAverage {
            return "少し早めに使い切りました。次回の予測を短めにしました。"
        }

        if actualUsageDays > previousAverage + 3 {
            return "前回より長持ちしました。次回の予測を少し延ばしました。"
        }

        if learnedAverage != previousAverage {
            return "使用ペースに合わせて予測を更新しました。"
        }

        return "予測を更新しました"
    }

#if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func foundationModelComment(productName: String, actualUsageDays: Int?, previousAverage: Int, learnedAverage: Int) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }

        do {
            let session = LanguageModelSession(instructions: """
            The person's locale is ja_JP.
            Write one short sentence explaining how a consumable prediction changed.
            Be concrete, calm, and under 36 Japanese characters.
            """)
            let response = try await session.respond(to: Prompt("商品: \(productName)\n実使用日数: \(actualUsageDays.map(String.init) ?? "不明")\n前の平均: \(previousAverage)\n新しい平均: \(learnedAverage)"))
            let text = String(response.content)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
#endif
}

nonisolated enum PurchaseInventoryService {
    static func unopenedCountAfterDeletingPurchase(currentCount: Int, deletedQuantity: Int) -> Int {
        max(currentCount - deletedQuantity, 0)
    }

    static func unopenedCountAfterUpdatingPurchase(currentCount: Int, oldQuantity: Int, newQuantity: Int) -> Int {
        max(currentCount + newQuantity - oldQuantity, 0)
    }
}

enum ShoppingFilterOption: String, CaseIterable, Identifiable {
    case thisWeek = "今週"
    case soon = "もうすぐ"
    case all = "すべて"

    var id: String { rawValue }
}

nonisolated enum ShoppingFilterService {
    static func products(_ products: [StockProduct], option: ShoppingFilterOption) -> [StockProduct] {
        let sortedProducts = StockSortService.sortedProducts(products, option: .recommended)

        switch option {
        case .thisWeek:
            return sortedProducts.filter { urgencyRank(for: $0) == 0 }
        case .soon:
            return sortedProducts.filter { urgencyRank(for: $0) == 1 }
        case .all:
            return sortedProducts.filter { $0.state == .inUse }
        }
    }

    private static func urgencyRank(for product: StockProduct) -> Int {
        guard product.state == .inUse, let daysRemaining = product.daysRemaining else {
            return 3
        }

        if daysRemaining <= 7 { return 0 }
        if daysRemaining <= 14 { return 1 }
        return 2
    }
}

struct PurchaseRecommendation: Equatable {
    let quantity: Int
    let reason: String
    let shouldBuy: Bool
}

nonisolated enum PurchaseRecommendationService {
    static func recommendation(for product: StockProduct, householdProfile: HouseholdProfile) -> PurchaseRecommendation {
        let profile = householdProfile.normalized
        let stockCoverageDays = max(product.unopenedCount, 0) * max(product.averageUsageDays, 1)
        let currentRemainingDays = product.daysRemaining ?? 0
        let totalCoverageDays = stockCoverageDays + currentRemainingDays
        let targetCoverageDays = targetCoverageDays(for: product, profile: profile)
        let shortageDays = max(targetCoverageDays - totalCoverageDays, 0)
        let shortageCount = max(product.minimumStockCount - product.unopenedCount, 0)
        let durationBasedQuantity = Int((Double(shortageDays) / Double(max(product.averageUsageDays, 1))).rounded(.up))
        let quantity = min(max(durationBasedQuantity, shortageCount, 1), 6)

        if shortageCount > 0 {
            return PurchaseRecommendation(quantity: quantity, reason: "最低ストックを下回っています", shouldBuy: true)
        }

        if shortageDays == 0 && product.unopenedCount > 0 {
            return PurchaseRecommendation(quantity: 0, reason: "ストックは十分です", shouldBuy: false)
        }

        if (product.daysRemaining ?? Int.max) <= 7 {
            return PurchaseRecommendation(quantity: max(quantity, 1), reason: "残りが少ないため優先", shouldBuy: true)
        }

        if product.unopenedCount == 0 && product.importance == .high {
            return PurchaseRecommendation(quantity: max(quantity, 1), reason: "予備がない重要品", shouldBuy: true)
        }

        if profile.children > 0 || profile.pets > 0 {
            return PurchaseRecommendation(quantity: max(quantity, 1), reason: "世帯構成を考慮", shouldBuy: true)
        }

        return PurchaseRecommendation(quantity: max(quantity, 1), reason: "次回までの予備", shouldBuy: true)
    }

    private static func targetCoverageDays(for product: StockProduct, profile: HouseholdProfile) -> Int {
        let baseDays: Int
        switch product.importance {
        case .high:
            baseDays = 45
        case .medium:
            baseDays = 30
        case .low:
            baseDays = 14
        }

        let householdExtraDays = min(max(profile.adults + profile.children - 1, 0) * 7, 28)
        let petExtraDays = product.category == .pet ? min(profile.pets * 10, 30) : 0
        return min(baseDays + householdExtraDays + petExtraDays, 90)
    }
}

struct HomeSummary: Equatable {
    let buyNowCount: Int
    let soonCount: Int
    let expiredCount: Int
    let expiringCount: Int
    let unopenedCount: Int

    var hasAttentionItems: Bool {
        buyNowCount > 0 || expiredCount > 0 || expiringCount > 0
    }
}

nonisolated enum HomeSummaryService {
    static func summary(for products: [StockProduct]) -> HomeSummary {
        HomeSummary(
            buyNowCount: products.filter { urgencyRank(for: $0) == 0 }.count,
            soonCount: products.filter { urgencyRank(for: $0) == 1 }.count,
            expiredCount: products.filter { (ExpirationService.daysRemaining(until: $0.expirationDate) ?? 1) < 0 }.count,
            expiringCount: products.filter {
                let daysRemaining = ExpirationService.daysRemaining(until: $0.expirationDate)
                return ExpirationService.isSoon($0.expirationDate) && (daysRemaining ?? 1) >= 0
            }.count,
            unopenedCount: products.filter { $0.state == .unopened || $0.unopenedCount > 0 }.count
        )
    }

    private static func urgencyRank(for product: StockProduct) -> Int {
        guard product.state == .inUse, let daysRemaining = product.daysRemaining else {
            return 3
        }

        if daysRemaining <= 7 { return 0 }
        if daysRemaining <= 14 { return 1 }
        return 2
    }
}

nonisolated enum StockSearchService {
    static func filteredProducts(_ products: [StockProduct], query: String) -> [StockProduct] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return products }

        return products.filter { product in
            product.name.localizedStandardContains(normalizedQuery)
                || product.category.rawValue.localizedStandardContains(normalizedQuery)
                || product.state.rawValue.localizedStandardContains(normalizedQuery)
                || product.importance.rawValue.localizedStandardContains(normalizedQuery)
                || product.memo.localizedStandardContains(normalizedQuery)
                || product.storageLocation.localizedStandardContains(normalizedQuery)
                || product.tags.localizedStandardContains(normalizedQuery)
        }
    }
}

enum StockSortOption: String, CaseIterable, Identifiable {
    case recommended = "おすすめ順"
    case remainingDays = "残り日数順"
    case name = "名前順"

    var id: String { rawValue }
}

enum StockFilterOption: String, CaseIterable, Identifiable {
    case all = "すべて"
    case expired = "期限切れ"
    case expiring = "期限"
    case inUse = "使用中"
    case unopened = "未開封"

    var id: String { rawValue }
}

nonisolated enum StockFilterService {
    static func products(_ products: [StockProduct], option: StockFilterOption) -> [StockProduct] {
        switch option {
        case .all:
            return products
        case .expired:
            return products.filter { (ExpirationService.daysRemaining(until: $0.expirationDate) ?? 1) < 0 }
        case .expiring:
            return products.filter {
                let daysRemaining = ExpirationService.daysRemaining(until: $0.expirationDate)
                return ExpirationService.isSoon($0.expirationDate) && (daysRemaining ?? 1) >= 0
            }
        case .inUse:
            return products.filter { $0.state == .inUse }
        case .unopened:
            return products.filter { $0.state == .unopened || $0.unopenedCount > 0 }
        }
    }
}

nonisolated enum StockSortService {
    static func sortedProducts(_ products: [StockProduct], option: StockSortOption) -> [StockProduct] {
        switch option {
        case .recommended:
            return products.sorted { lhs, rhs in
                let lhsRank = urgencyRank(for: lhs)
                let rhsRank = urgencyRank(for: rhs)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return remainingDaysSortValue(for: lhs) < remainingDaysSortValue(for: rhs)
            }
        case .remainingDays:
            return products.sorted {
                remainingDaysSortValue(for: $0) < remainingDaysSortValue(for: $1)
            }
        case .name:
            return products.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    private static func urgencyRank(for product: StockProduct) -> Int {
        guard product.state == .inUse, let daysRemaining = product.daysRemaining else {
            return 3
        }

        if daysRemaining <= 7 { return 0 }
        if daysRemaining <= 14 { return 1 }
        return 2
    }

    private static func remainingDaysSortValue(for product: StockProduct) -> Int {
        product.daysRemaining ?? Int.max
    }
}

struct ProductSuggestion: Equatable {
    var category: ProductCategory
    var estimate: DurationEstimate
    var customDurationDays = 30
    var importance: Importance
    var reason: String
    var source: SuggestionSource
    var isHouseholdAdjusted = false
}

enum SuggestionSource: Equatable {
    case appleIntelligence
    case ruleBased

    var label: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .ruleBased: "おすすめ"
        }
    }
}

struct NaturalLanguageProductDraft: Equatable {
    var name: String
    var category: ProductCategory
    var state: ProductState
    var duration: DurationEstimate
    var customDurationDays: Int
    var isHouseholdAdjusted = false
    var unopenedCount: Int
    var importance: Importance
    var memo: String
}

nonisolated enum ProductSuggestionProvider {
    static func suggestion(for name: String, householdProfile: HouseholdProfile? = nil) async -> ProductSuggestion {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return fallbackSuggestion(for: trimmedName, householdProfile: householdProfile)
        }

#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            if let suggestion = await foundationModelSuggestion(for: trimmedName, householdProfile: householdProfile) {
                return suggestion
            }
        }
#endif

        return fallbackSuggestion(for: trimmedName, householdProfile: householdProfile)
    }

    static func fallbackSuggestion(for name: String, householdProfile: HouseholdProfile? = nil) -> ProductSuggestion {
        let normalized = name.lowercased()
        let baseSuggestion: ProductSuggestion

        if normalized.contains("洗剤") || normalized.contains("柔軟") || normalized.contains("漂白") {
            baseSuggestion = ProductSuggestion(category: .laundry, estimate: .oneMonth, importance: .medium, reason: "洗濯用品としてよく登録されます。", source: .ruleBased)
        } else if normalized.contains("シャンプ") || normalized.contains("リンス") || normalized.contains("ボディ") || normalized.contains("石けん") {
            baseSuggestion = ProductSuggestion(category: .bath, estimate: .oneMonth, importance: .medium, reason: "バス用品として扱うと探しやすくなります。", source: .ruleBased)
        } else if normalized.contains("トイレ") || normalized.contains("ティッシュ") || normalized.contains("ペーパー") {
            baseSuggestion = ProductSuggestion(category: .daily, estimate: .twoWeeks, importance: .high, reason: "切らすと困りやすい日用品です。", source: .ruleBased)
        } else if normalized.contains("ドッグ") || normalized.contains("キャット") || normalized.contains("ペット") || normalized.contains("フード") {
            baseSuggestion = ProductSuggestion(category: .pet, estimate: .oneMonth, importance: .high, reason: "ペット用品は早めの補充が安心です。", source: .ruleBased)
        } else if normalized.contains("コーヒ") || normalized.contains("米") || normalized.contains("茶") || normalized.contains("水") {
            baseSuggestion = ProductSuggestion(category: .food, estimate: .oneMonth, importance: .medium, reason: "食品として補充タイミングを見ます。", source: .ruleBased)
        } else {
            baseSuggestion = ProductSuggestion(category: .other, estimate: .oneMonth, importance: .medium, reason: "まずは約1ヶ月で予測します。", source: .ruleBased)
        }

        return householdAdjustedSuggestion(baseSuggestion, householdProfile: householdProfile)
    }

    private static func householdAdjustedSuggestion(_ suggestion: ProductSuggestion, householdProfile: HouseholdProfile?) -> ProductSuggestion {
        guard let householdProfile,
              let baseDays = suggestion.estimate.predictedDays
        else {
            return suggestion
        }

        let adjustedDays = HouseholdUsageAdjustmentService.adjustedDays(
            baseDays: baseDays,
            category: suggestion.category,
            profile: householdProfile
        )
        guard adjustedDays != baseDays else {
            return suggestion
        }

        var adjustedSuggestion = suggestion
        adjustedSuggestion.estimate = .custom
        adjustedSuggestion.customDurationDays = adjustedDays
        adjustedSuggestion.reason = "世帯構成から約\(adjustedDays)日で予測します。"
        adjustedSuggestion.isHouseholdAdjusted = true
        return adjustedSuggestion
    }

#if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func foundationModelSuggestion(for name: String, householdProfile: HouseholdProfile?) async -> ProductSuggestion? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }

        do {
            let fallback = fallbackSuggestion(for: name, householdProfile: householdProfile)
            let session = LanguageModelSession(instructions: """
            The person's locale is ja_JP.
            You suggest defaults for a household consumable registration form using household composition.
            Choose only from these categories: 洗濯, バス, 日用品, ペット, 食品, その他.
            Choose only these duration labels: 1週間, 2週間, 1ヶ月, 2ヶ月, その他.
            Set customDurationDays to the predicted duration in days.
            Choose only these importance labels: かなり困る, 少し困る, 困らない.
            Keep the reason under 24 Japanese characters.
            """)

            let response = try await session.respond(
                to: Prompt("商品名: \(name)\n世帯: \(householdProfile?.displayText ?? "未設定")"),
                generating: AIProductSuggestion.self
            )
            let content = response.content
            let estimate = DurationEstimate(rawValue: content.duration) ?? fallback.estimate
            return ProductSuggestion(
                category: ProductCategory(rawValue: content.category) ?? fallback.category,
                estimate: estimate,
                customDurationDays: min(max(content.customDurationDays, 1), 365),
                importance: Importance(rawValue: content.importance) ?? fallback.importance,
                reason: content.reason.isEmpty ? fallback.reason : content.reason,
                source: .appleIntelligence,
                isHouseholdAdjusted: householdProfile != nil
            )
        } catch {
            return nil
        }
    }

    @Generable(description: "Suggested defaults for registering a household consumable")
    struct AIProductSuggestion {
        @Guide(description: "One of 洗濯, バス, 日用品, ペット, 食品, その他")
        var category: String

        @Guide(description: "One of 1週間, 2週間, 1ヶ月, 2ヶ月, その他")
        var duration: String

        @Guide(description: "Predicted duration days")
        var customDurationDays: Int

        @Guide(description: "One of かなり困る, 少し困る, 困らない")
        var importance: String

        @Guide(description: "Short Japanese reason")
        var reason: String
    }
#endif
}

nonisolated enum NaturalLanguageProductParser {
    static func draft(from text: String, householdProfile: HouseholdProfile? = nil) async -> NaturalLanguageProductDraft? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *),
           let draft = await foundationModelDraft(from: trimmedText, householdProfile: householdProfile) {
            return draft
        }
#endif

        return fallbackDraft(from: trimmedText, householdProfile: householdProfile)
    }

    static func fallbackDraft(from text: String, householdProfile: HouseholdProfile? = nil) -> NaturalLanguageProductDraft {
        let normalized = text.lowercased()
        let quantity = quantity(from: normalized)
        let state: ProductState = normalized.contains("買った") || normalized.contains("購入") || normalized.contains("ストック") ? .unopened : .inUse
        let duration = duration(from: normalized)
        let explicitCustomDays = customDurationDays(from: normalized)
        let name = productName(from: text)
        let category = ProductCategoryInferenceService.category(for: name)
        let suggestion = ProductSuggestionProvider.fallbackSuggestion(for: name)
        let baseDays = explicitCustomDays ?? duration.predictedDays ?? 30
        let adjustedDays = explicitCustomDays == nil
            ? householdProfile.map {
                HouseholdUsageAdjustmentService.adjustedDays(baseDays: baseDays, category: category, profile: $0)
            } ?? baseDays
            : baseDays
        let isHouseholdAdjusted = adjustedDays != baseDays

        return NaturalLanguageProductDraft(
            name: name,
            category: category,
            state: state,
            duration: isHouseholdAdjusted ? .custom : duration,
            customDurationDays: adjustedDays,
            isHouseholdAdjusted: isHouseholdAdjusted,
            unopenedCount: max(quantity, 1),
            importance: suggestion.importance,
            memo: text
        )
    }

    private static func productName(from text: String) -> String {
        var name = text
            .replacingOccurrences(of: #"\d+\s*(個|本|袋|箱|枚|パック)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(を|は|が).*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if name.isEmpty {
            name = text.components(separatedBy: .whitespacesAndNewlines).first ?? text
        }

        return String(name.prefix(32))
    }

    private static func quantity(from text: String) -> Int {
        guard let match = text.range(of: #"(\d+)\s*(個|本|袋|箱|枚|パック)"#, options: .regularExpression) else {
            return 1
        }

        let matchedText = String(text[match])
        let digits = matchedText.filter(\.isNumber)
        return Int(digits) ?? 1
    }

    private static func duration(from text: String) -> DurationEstimate {
        if text.contains("1週間") || text.contains("一週間") { return .oneWeek }
        if text.contains("2週間") || text.contains("二週間") { return .twoWeeks }
        if text.contains("1ヶ月") || text.contains("1か月") || text.contains("一ヶ月") || text.contains("一か月") { return .oneMonth }
        if text.contains("2ヶ月") || text.contains("2か月") || text.contains("二ヶ月") || text.contains("二か月") { return .twoMonths }
        return customDurationDays(from: text) == nil ? .oneMonth : .custom
    }

    private static func customDurationDays(from text: String) -> Int? {
        guard let match = text.range(of: #"(\d+)\s*日"#, options: .regularExpression) else {
            return nil
        }

        let matchedText = String(text[match])
        let digits = matchedText.filter(\.isNumber)
        return Int(digits).map { min(max($0, 1), 365) }
    }

#if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func foundationModelDraft(from text: String, householdProfile: HouseholdProfile?) async -> NaturalLanguageProductDraft? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }

        do {
            let fallback = fallbackDraft(from: text, householdProfile: householdProfile)
            let session = LanguageModelSession(instructions: """
            The person's locale is ja_JP.
            Extract a household consumable registration draft from natural Japanese text.
            Consider household composition only when the text does not explicitly say the usage duration.
            Choose only these categories: 洗濯, バス, 日用品, ペット, 食品, その他.
            Choose only these states: 今使っている, 未開封.
            Choose only these duration labels: 1週間, 2週間, 1ヶ月, 2ヶ月, その他.
            Choose only these importance labels: かなり困る, 少し困る, 困らない.
            Keep memo short and useful.
            """)
            let response = try await session.respond(to: Prompt("世帯: \(householdProfile?.displayText ?? "未設定")\n入力: \(text)"), generating: AINaturalLanguageProductDraft.self)
            let content = response.content
            let duration = DurationEstimate(rawValue: content.duration) ?? fallback.duration

            return NaturalLanguageProductDraft(
                name: content.name.isEmpty ? fallback.name : content.name,
                category: ProductCategory(rawValue: content.category) ?? fallback.category,
                state: ProductState(rawValue: content.state) ?? fallback.state,
                duration: duration,
                customDurationDays: min(max(content.customDurationDays, 1), 365),
                isHouseholdAdjusted: householdProfile != nil && !explicitDurationExists(in: text),
                unopenedCount: min(max(content.quantity, 1), 99),
                importance: Importance(rawValue: content.importance) ?? fallback.importance,
                memo: content.memo.isEmpty ? fallback.memo : content.memo
            )
        } catch {
            return nil
        }
    }

    @Generable(description: "Draft product values extracted from natural language")
    struct AINaturalLanguageProductDraft {
        @Guide(description: "Product name")
        var name: String

        @Guide(description: "One of 洗濯, バス, 日用品, ペット, 食品, その他")
        var category: String

        @Guide(description: "One of 今使っている, 未開封")
        var state: String

        @Guide(description: "One of 1週間, 2週間, 1ヶ月, 2ヶ月, その他")
        var duration: String

        @Guide(description: "Custom duration days when duration is その他")
        var customDurationDays: Int

        @Guide(description: "Purchased or stocked quantity")
        var quantity: Int

        @Guide(description: "One of かなり困る, 少し困る, 困らない")
        var importance: String

        @Guide(description: "Short note")
        var memo: String
    }
#endif

    private static func explicitDurationExists(in text: String) -> Bool {
        customDurationDays(from: text) != nil
            || text.contains("1週間")
            || text.contains("一週間")
            || text.contains("2週間")
            || text.contains("二週間")
            || text.contains("1ヶ月")
            || text.contains("1か月")
            || text.contains("一ヶ月")
            || text.contains("一か月")
            || text.contains("2ヶ月")
            || text.contains("2か月")
            || text.contains("二ヶ月")
            || text.contains("二か月")
    }
}

nonisolated enum ProductCategoryInferenceService {
    static func category(for name: String) -> ProductCategory {
        let normalized = name.lowercased()

        if normalized.contains("洗剤") || normalized.contains("柔軟") || normalized.contains("漂白") {
            return .laundry
        }

        if normalized.contains("シャンプ") || normalized.contains("リンス") || normalized.contains("ボディ") || normalized.contains("石けん") {
            return .bath
        }

        if normalized.contains("トイレ") || normalized.contains("ティッシュ") || normalized.contains("ペーパー") {
            return .daily
        }

        if normalized.contains("ドッグ") || normalized.contains("キャット") || normalized.contains("ペット") || normalized.contains("フード") {
            return .pet
        }

        if normalized.contains("コーヒ") || normalized.contains("米") || normalized.contains("茶") || normalized.contains("水") || normalized.contains("牛乳") || normalized.contains("卵") {
            return .food
        }

        return .other
    }
}

nonisolated enum TagSuggestionService {
    static func tagsText(for name: String, category: ProductCategory) -> String {
        suggestedTags(for: name, category: category).joined(separator: "、")
    }

    static func mergedTagsText(existing: String, suggested: String) -> String {
        let existingTags = splitTags(existing)
        let suggestedTags = splitTags(suggested)
        let merged = existingTags + suggestedTags.filter { tag in
            !existingTags.contains { $0.normalizedProductName == tag.normalizedProductName }
        }
        return merged.prefix(8).joined(separator: "、")
    }

    static func suggestedTags(for name: String, category: ProductCategory) -> [String] {
        var tags = [category.rawValue]
        let normalized = name.lowercased()

        switch category {
        case .laundry:
            tags.append(contentsOf: ["詰め替え", "洗面所"])
        case .bath:
            tags.append(contentsOf: ["浴室", "詰め替え"])
        case .daily:
            tags.append(contentsOf: ["日常", "まとめ買い"])
        case .pet:
            tags.append(contentsOf: ["ペット", "定期購入"])
        case .food:
            tags.append(contentsOf: ["食品", "期限あり"])
        case .other:
            tags.append("その他")
        }

        if normalized.contains("詰め替") || normalized.contains("refill") {
            tags.append("詰め替え")
        }
        if normalized.contains("米") || normalized.contains("水") || normalized.contains("保存") {
            tags.append("備蓄")
        }
        if normalized.contains("牛乳") || normalized.contains("卵") || normalized.contains("日焼け") {
            tags.append("期限短め")
        }

        var seen = Set<String>()
        return tags.filter { tag in
            seen.insert(tag.normalizedProductName).inserted
        }
    }

    private static func splitTags(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "、, \n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private enum PurchaseProvider: String, CaseIterable, Identifiable {
    case amazon
    case rakuten
    case yahoo
    case google

    var id: String { rawValue }

    var label: String {
        switch self {
        case .amazon: "Amazon"
        case .rakuten: "楽天市場"
        case .yahoo: "Yahoo!ショッピング"
        case .google: "Google"
        }
    }

    private var baseURLString: String {
        switch self {
        case .amazon: "https://www.amazon.co.jp/s?k="
        case .rakuten: "https://search.rakuten.co.jp/search/mall/"
        case .yahoo: "https://shopping.yahoo.co.jp/search?p="
        case .google: "https://www.google.com/search?q="
        }
    }

    func searchURL(for query: String) -> URL? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty,
              let encodedQuery = trimmedQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }

        return URL(string: baseURLString + encodedQuery)
    }
}

enum PurchaseURLFormatter {
    static func normalizedURLString(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lowercased = trimmed.lowercased()

        let urlString: String
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            urlString = trimmed
        } else {
            urlString = "https://\(trimmed)"
        }

        guard
            let components = URLComponents(string: urlString),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            components.url != nil
        else {
            return ""
        }

        return urlString
    }
}

private enum PurchaseSearchQueryProvider {
    static func query(for product: StockProduct, usesAI: Bool) async -> String {
        if usesAI {
#if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *),
               let query = await foundationModelQuery(for: product) {
                return query
            }
#endif
        }

        return fallbackQuery(for: product)
    }

    static func fallbackQuery(for product: StockProduct) -> String {
        let categoryKeyword: String
        switch product.category {
        case .laundry, .bath:
            categoryKeyword = "詰め替え"
        case .daily:
            categoryKeyword = "まとめ買い"
        case .pet:
            categoryKeyword = "定期便"
        case .food:
            categoryKeyword = "大容量"
        case .other:
            categoryKeyword = ""
        }

        let memoKeywords = product.memo
            .components(separatedBy: CharacterSet(charactersIn: "、,。 \n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)

        return ([product.name, categoryKeyword] + memoKeywords)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

#if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func foundationModelQuery(for product: StockProduct) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }

        do {
            let session = LanguageModelSession(instructions: """
            The person's locale is ja_JP.
            Create a concise shopping search keyword for a household consumable.
            Return only the search keyword, no explanation.
            Keep it under 24 Japanese characters.
            Include the product name and useful buying intent such as refill, bulk, or subscription when appropriate.
            """)
            let response = try await session.respond(to: Prompt("商品名: \(product.name)\nカテゴリ: \(product.category.rawValue)\nメモ: \(product.memo)"))
            let query = String(response.content)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return query.isEmpty ? nil : query
        } catch {
            return nil
        }
    }
#endif
}

private enum HapticFeedback {
    static func success() {
#if canImport(UIKit)
        DispatchQueue.main.async {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
#endif
    }

    static func light() {
#if canImport(UIKit)
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
#endif
    }
}

struct ReceiptCandidate: Identifiable, Hashable {
    let id: UUID
    let name: String
    let category: ProductCategory

    nonisolated init(id: UUID = UUID(), name: String, category: ProductCategory? = nil) {
        self.id = id
        self.name = name
        self.category = category ?? ProductCategoryInferenceService.category(for: name)
    }
}

nonisolated enum ReceiptCandidateExtractor {
    static func candidates(from lines: [String]) -> [ReceiptCandidate] {
        var seenNames = Set<String>()

        return lines
            .map(cleanedName)
            .filter(isLikelyProductName)
            .compactMap { name in
                guard seenNames.insert(name).inserted else { return nil }
                return ReceiptCandidate(name: name)
            }
            .prefix(12)
            .map { $0 }
    }

    private static func cleanedName(_ line: String) -> String {
        line
            .replacingOccurrences(of: #"^[\*\s\-・]+|[\*\s\-・]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+[xX×]\s*\d+.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+[\d,]+円?$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLikelyProductName(_ name: String) -> Bool {
        guard (2...32).contains(name.count) else { return false }

        let lowercased = name.lowercased()
        let excludedWords = [
            "合計", "小計", "消費税", "税率", "対象", "税込", "税抜", "内税", "外税",
            "現金", "釣", "お預り", "クレジット", "ポイント", "領収", "レシート",
            "登録番号", "電話", "tel", "日時", "担当", "店舗", "店", "円"
        ]

        if excludedWords.contains(where: { lowercased.contains($0.lowercased()) }) {
            return false
        }

        if name.range(of: #"^[\d\s,.\-/:%]+$"#, options: .regularExpression) != nil {
            return false
        }

        return true
    }
}

nonisolated enum ReceiptCandidateRefinementService {
    static func refinedCandidates(from candidates: [ReceiptCandidate]) async -> [ReceiptCandidate] {
        let fallback = fallbackRefinedCandidates(from: candidates)

#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *),
           let refined = await foundationModelRefinedCandidates(from: fallback),
           !refined.isEmpty {
            return refined
        }
#endif

        return fallback
    }

    static func fallbackRefinedCandidates(from candidates: [ReceiptCandidate]) -> [ReceiptCandidate] {
        var seenNames = Set<String>()

        return candidates.compactMap { candidate in
            let name = normalizedReceiptProductName(candidate.name)
            guard !name.isEmpty, seenNames.insert(name.normalizedProductName).inserted else { return nil }
            return ReceiptCandidate(name: name, category: ProductCategoryInferenceService.category(for: name))
        }
    }

    private static func normalizedReceiptProductName(_ name: String) -> String {
        name
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "トイレトP", with: "トイレットペーパー")
            .replacingOccurrences(of: "トイレットP", with: "トイレットペーパー")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

#if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func foundationModelRefinedCandidates(from candidates: [ReceiptCandidate]) async -> [ReceiptCandidate]? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }

        do {
            let session = LanguageModelSession(instructions: """
            The person's locale is ja_JP.
            Clean OCR receipt product candidates.
            Remove non-products, fix obvious OCR mistakes, and return one product per line.
            Keep names concise. Do not include prices, quantities, totals, store names, or explanations.
            """)
            let prompt = candidates.map(\.name).joined(separator: "\n")
            let response = try await session.respond(to: Prompt(prompt))
            let lines = String(response.content)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            return fallbackRefinedCandidates(from: lines.map { ReceiptCandidate(name: $0) })
        } catch {
            return nil
        }
    }
#endif
}

#if canImport(Vision) && canImport(UIKit)
private enum ReceiptOCRService {
    static func candidates(from image: UIImage) async -> [ReceiptCandidate] {
        guard let cgImage = image.cgImage else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ja-JP", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
            let lines = (request.results ?? [])
                .compactMap { observation in
                    observation.topCandidates(1).first?.string
                }
            return ReceiptCandidateExtractor.candidates(from: lines)
        } catch {
            return []
        }
    }
}
#endif

private enum NotificationService {
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    static func scheduleTestNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "あとどれ？ テスト通知"
        content.body = "通知は正しく設定されています。"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        let request = UNNotificationRequest(identifier: "test-notification", content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func scheduleReminder(for product: StockProduct, notificationsEnabled: Bool, leadDays: Int, expirationLeadDays: Int, preferredShoppingWeekday: Int = 0) async {
        cancelReminder(for: product)
        guard notificationsEnabled, product.notificationsEnabled else { return }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        if let daysRemaining = product.daysRemaining {
            let daysUntilReminder = refillReminderPreviewDays(
                daysRemaining: daysRemaining,
                leadDays: leadDays,
                preferredShoppingWeekday: preferredShoppingWeekday
            )
            let content = UNMutableNotificationContent()
            content.title = "そろそろ買い時です"
            content.body = "\(product.name)を買っておくと安心です。"
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(daysUntilReminder * 24 * 60 * 60), repeats: false)
            let request = UNNotificationRequest(identifier: refillIdentifier(for: product), content: content, trigger: trigger)

            try? await UNUserNotificationCenter.current().add(request)
        }

        if let expirationDaysRemaining = product.expirationDaysRemaining, expirationDaysRemaining >= 0 {
            let daysUntilReminder = max(expirationDaysRemaining - expirationLeadDays, 1)
            let content = UNMutableNotificationContent()
            content.title = "期限が近づいています"
            content.body = "\(product.name)の期限を確認しましょう。"
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(daysUntilReminder * 24 * 60 * 60), repeats: false)
            let request = UNNotificationRequest(identifier: expirationIdentifier(for: product), content: content, trigger: trigger)

            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    static func cancelReminder(for product: StockProduct) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
            refillIdentifier(for: product),
            expirationIdentifier(for: product)
        ])
    }

    static func cancelReminders(for products: [StockProduct]) {
        let identifiers = products.flatMap { product in
            [
                refillIdentifier(for: product),
                expirationIdentifier(for: product)
            ]
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    static func pendingReminderCount() async -> Int {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return requests.filter { request in
            request.identifier.hasPrefix("refill-") || request.identifier.hasPrefix("expiration-")
        }.count
    }

    private static func refillIdentifier(for product: StockProduct) -> String {
        "refill-\(product.id.uuidString)"
    }

    private static func expirationIdentifier(for product: StockProduct) -> String {
        "expiration-\(product.id.uuidString)"
    }

    nonisolated static func refillReminderPreviewDays(daysRemaining: Int, leadDays: Int, preferredShoppingWeekday: Int, calendar: Calendar = .current) -> Int {
        let baseDays = max(daysRemaining - leadDays, 1)
        guard (1...7).contains(preferredShoppingWeekday) else { return baseDays }

        let today = calendar.startOfDay(for: Date())
        guard let targetDate = calendar.date(byAdding: .day, value: baseDays, to: today) else {
            return baseDays
        }

        var cursor = targetDate
        for _ in 0..<7 {
            if calendar.component(.weekday, from: cursor) == preferredShoppingWeekday {
                return max(calendar.dateComponents([.day], from: today, to: cursor).day ?? baseDays, 1)
            }
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }

        return baseDays
    }
}

private enum AppTab {
    case home
    case shopping
    case stock
    case settings
}

private enum AppTheme {
    static let primary = Color(red: 0.09, green: 0.32, blue: 0.91)
    static let ink = Color(red: 0.07, green: 0.08, blue: 0.12)
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let elevatedSurface = Color(uiColor: .tertiarySystemGroupedBackground)
    static let softBlue = Color(red: 0.90, green: 0.94, blue: 1.0)
    static let softMint = Color(red: 0.90, green: 0.98, blue: 0.94)
    static let softOrange = Color(red: 1.0, green: 0.95, blue: 0.86)
}

private enum AppPlan {
    static let freeProductLimit = 10
}

private enum AppStoreProductID {
    static let proMonthly = "com.freeplanets001.atodore.pro.monthly"
    static let all = [proMonthly]
}

private enum AppAPIConfiguration {
    static var barcodeLookupProxyURLString: String {
        Bundle.main.object(forInfoDictionaryKey: "BarcodeLookupProxyURL") as? String ?? ""
    }
}

private struct StarterTemplate: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let items: [StarterTemplateItem]

    static let all: [StarterTemplate] = [
        StarterTemplate(
            id: "daily",
            title: "生活用品",
            subtitle: "まず切らしたくない定番",
            symbol: "house.fill",
            items: [
                StarterTemplateItem(name: "トイレットペーパー", category: .daily, averageUsageDays: 24, importance: .high),
                StarterTemplateItem(name: "洗濯洗剤", category: .laundry, averageUsageDays: 30, importance: .medium),
                StarterTemplateItem(name: "柔軟剤", category: .laundry, averageUsageDays: 45, importance: .low),
                StarterTemplateItem(name: "シャンプー", category: .bath, averageUsageDays: 35, importance: .medium),
                StarterTemplateItem(name: "ボディソープ", category: .bath, averageUsageDays: 30, importance: .medium),
                StarterTemplateItem(name: "歯みがき粉", category: .daily, averageUsageDays: 45, importance: .medium),
                StarterTemplateItem(name: "ティッシュ", category: .daily, averageUsageDays: 20, importance: .medium)
            ]
        ),
        StarterTemplate(
            id: "food",
            title: "食材",
            subtitle: "よく補充する食品",
            symbol: "fork.knife",
            items: [
                StarterTemplateItem(name: "米", category: .food, averageUsageDays: 30, importance: .high, expirationAfterDays: 180),
                StarterTemplateItem(name: "コーヒー", category: .food, averageUsageDays: 28, importance: .medium, expirationAfterDays: 180),
                StarterTemplateItem(name: "水", category: .food, averageUsageDays: 14, importance: .high, expirationAfterDays: 365),
                StarterTemplateItem(name: "お茶", category: .food, averageUsageDays: 21, importance: .medium, expirationAfterDays: 180),
                StarterTemplateItem(name: "牛乳", category: .food, averageUsageDays: 7, importance: .medium, expirationAfterDays: 7),
                StarterTemplateItem(name: "卵", category: .food, averageUsageDays: 10, importance: .medium, expirationAfterDays: 14),
                StarterTemplateItem(name: "パスタ", category: .food, averageUsageDays: 45, importance: .low, expirationAfterDays: 365)
            ]
        ),
        StarterTemplate(
            id: "pet",
            title: "ペットあり",
            subtitle: "早めに補充したいもの",
            symbol: "pawprint.fill",
            items: [
                StarterTemplateItem(name: "ドッグフード", category: .pet, averageUsageDays: 30, importance: .high, expirationAfterDays: 180),
                StarterTemplateItem(name: "ペットシーツ", category: .pet, averageUsageDays: 21, importance: .high),
                StarterTemplateItem(name: "消臭スプレー", category: .daily, averageUsageDays: 45, importance: .medium),
                StarterTemplateItem(name: "ペット用ウェットティッシュ", category: .pet, averageUsageDays: 30, importance: .medium),
                StarterTemplateItem(name: "猫砂", category: .pet, averageUsageDays: 28, importance: .high),
                StarterTemplateItem(name: "ペット用おやつ", category: .pet, averageUsageDays: 20, importance: .low, expirationAfterDays: 120)
            ]
        ),
        StarterTemplate(
            id: "hobby",
            title: "娯楽・趣味",
            subtitle: "なくなると地味に困るもの",
            symbol: "sparkles",
            items: [
                StarterTemplateItem(name: "電池", category: .daily, averageUsageDays: 60, importance: .medium),
                StarterTemplateItem(name: "プリンター用紙", category: .other, averageUsageDays: 90, importance: .low),
                StarterTemplateItem(name: "インクカートリッジ", category: .other, averageUsageDays: 120, importance: .medium),
                StarterTemplateItem(name: "充電ケーブル", category: .other, averageUsageDays: 180, importance: .low),
                StarterTemplateItem(name: "掃除シート", category: .daily, averageUsageDays: 30, importance: .medium)
            ]
        ),
        StarterTemplate(
            id: "beauty",
            title: "美容・ケア",
            subtitle: "洗面台まわりの定番",
            symbol: "heart.fill",
            items: [
                StarterTemplateItem(name: "洗顔料", category: .bath, averageUsageDays: 45, importance: .medium, expirationAfterDays: 365),
                StarterTemplateItem(name: "化粧水", category: .daily, averageUsageDays: 45, importance: .medium, expirationAfterDays: 365),
                StarterTemplateItem(name: "乳液", category: .daily, averageUsageDays: 60, importance: .medium, expirationAfterDays: 365),
                StarterTemplateItem(name: "日焼け止め", category: .daily, averageUsageDays: 60, importance: .medium, expirationAfterDays: 365),
                StarterTemplateItem(name: "コットン", category: .daily, averageUsageDays: 45, importance: .low)
            ]
        ),
        StarterTemplate(
            id: "disaster",
            title: "防災ストック",
            subtitle: "期限前に確認したい備え",
            symbol: "cross.case.fill",
            items: [
                StarterTemplateItem(name: "保存水", category: .food, averageUsageDays: 180, importance: .high, expirationAfterDays: 365),
                StarterTemplateItem(name: "非常食", category: .food, averageUsageDays: 180, importance: .high, expirationAfterDays: 365),
                StarterTemplateItem(name: "乾電池", category: .daily, averageUsageDays: 180, importance: .high, expirationAfterDays: 365),
                StarterTemplateItem(name: "ウェットティッシュ", category: .daily, averageUsageDays: 90, importance: .medium, expirationAfterDays: 365),
                StarterTemplateItem(name: "マスク", category: .daily, averageUsageDays: 60, importance: .medium, expirationAfterDays: 365)
            ]
        )
    ]
}

private struct StarterTemplateItem: Hashable {
    let name: String
    let category: ProductCategory
    let averageUsageDays: Int
    let importance: Importance
    var expirationAfterDays: Int?

    var product: StockProduct {
        StockProduct(
            name: name,
            category: category,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 1,
            accuracy: "中",
            importance: importance,
            openedDate: nil,
            expirationDate: expirationDate,
            averageUsageDays: averageUsageDays,
            usageHistoryCount: 0
        )
    }

    private var expirationDate: Date? {
        guard let expirationAfterDays else { return nil }
        return Calendar.current.date(byAdding: .day, value: expirationAfterDays, to: Date())
    }
}

enum ProductCategory: String, CaseIterable, Identifiable {
    case laundry = "洗濯"
    case bath = "バス"
    case daily = "日用品"
    case pet = "ペット"
    case food = "食品"
    case other = "その他"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .laundry, .bath: "bubbles.and.sparkles.fill"
        case .daily: "shippingbox.fill"
        case .pet: "pawprint.fill"
        case .food: "fork.knife"
        case .other: "circle.grid.2x2.fill"
        }
    }
}

enum ProductState: String, CaseIterable, Identifiable {
    case inUse = "今使っている"
    case unopened = "未開封"

    var id: String { rawValue }
}

private enum StartTiming: String, CaseIterable, Identifiable {
    case today = "今日"
    case weekAgo = "1週間くらい前"
    case chooseDate = "日付を選ぶ"
    case unknown = "わからない"

    var id: String { rawValue }
}

enum DurationEstimate: String, CaseIterable, Identifiable {
    case oneWeek = "1週間"
    case twoWeeks = "2週間"
    case oneMonth = "1ヶ月"
    case twoMonths = "2ヶ月"
    case unknown = "わからない"
    case custom = "その他"

    var id: String { rawValue }

    nonisolated var predictedDays: Int? {
        switch self {
        case .oneWeek: 7
        case .twoWeeks: 14
        case .oneMonth: 30
        case .twoMonths: 60
        case .unknown, .custom: nil
        }
    }

    func resolvedDays(customDays: Int) -> Int {
        predictedDays ?? min(max(customDays, 1), 365)
    }
}

enum Importance: String, CaseIterable, Identifiable {
    case high = "かなり困る"
    case medium = "少し困る"
    case low = "困らない"

    var id: String { rawValue }
}

enum UsageScope: String, CaseIterable, Identifiable {
    case household = "家族全体"
    case adults = "大人中心"
    case children = "子ども中心"
    case pets = "ペット用"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .household: "person.3.fill"
        case .adults: "person.2.fill"
        case .children: "figure.2.and.child.holdinghands"
        case .pets: "pawprint.fill"
        }
    }
}

private enum UsageEvent: String {
    case stillHave = "まだある"
    case opened = "開けました"
    case finished = "なくなった"

    var symbol: String {
        switch self {
        case .stillHave: "clock.arrow.circlepath"
        case .opened: "shippingbox.fill"
        case .finished: "checkmark.circle.fill"
        }
    }
}

struct StockProduct: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var category: ProductCategory
    var state: ProductState
    var daysRemaining: Int?
    var unopenedCount: Int
    var accuracy: String
    var importance: Importance
    var openedDate: Date?
    var expirationDate: Date?
    var averageUsageDays: Int
    var usageHistoryCount: Int
    var minimumStockCount = 0
    var purchaseUnit = "個"
    var usageScope = UsageScope.household
    var preferredStore = ""
    var barcode = ""
    var purchaseURLString = ""
    var memo = ""
    var storageLocation = ""
    var tags = ""
    var photoData: Data?
    var notificationsEnabled = true

    nonisolated var urgency: ProductUrgency {
        guard state == .inUse, let daysRemaining else { return .unopened }

        if daysRemaining <= 7 { return .critical }
        if daysRemaining <= 14 { return .soon }
        return .fine
    }

    nonisolated var daysText: String {
        guard let daysRemaining else { return "未開封" }
        return "約\(daysRemaining)日"
    }

    var expectedEndDate: Date? {
        guard let daysRemaining else { return nil }
        return Calendar.current.date(byAdding: .day, value: daysRemaining, to: Date())
    }

    var recommendedBuyDate: Date? {
        guard let daysRemaining else { return nil }
        let daysUntilPurchase = max(daysRemaining - 3, 0)
        return Calendar.current.date(byAdding: .day, value: daysUntilPurchase, to: Date())
    }

    var expirationDaysRemaining: Int? {
        ExpirationService.daysRemaining(until: expirationDate)
    }

    var expirationText: String? {
        ExpirationService.displayText(for: expirationDate)
    }

    nonisolated var isExpirationSoon: Bool {
        ExpirationService.isSoon(expirationDate)
    }

    var purchaseURL: URL? {
        let normalized = PurchaseURLFormatter.normalizedURLString(from: purchaseURLString)
        guard !normalized.isEmpty else { return nil }
        return URL(string: normalized)
    }

    nonisolated var normalizedPurchaseUnit: String {
        let trimmed = purchaseUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "個" : trimmed
    }

    nonisolated var normalizedPreferredStore: String {
        preferredStore.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let samples: [StockProduct] = [
        StockProduct(name: "ドッグフード", category: .pet, state: .inUse, daysRemaining: 6, unopenedCount: 0, accuracy: "高", importance: .high, openedDate: .daysAgo(24), averageUsageDays: 30, usageHistoryCount: 5),
        StockProduct(name: "洗濯洗剤", category: .laundry, state: .inUse, daysRemaining: 3, unopenedCount: 0, accuracy: "高", importance: .medium, openedDate: .daysAgo(27), averageUsageDays: 31, usageHistoryCount: 6),
        StockProduct(name: "トイレットペーパー", category: .daily, state: .unopened, daysRemaining: nil, unopenedCount: 2, accuracy: "中", importance: .high, openedDate: nil, averageUsageDays: 24, usageHistoryCount: 4),
        StockProduct(name: "シャンプー", category: .bath, state: .inUse, daysRemaining: 21, unopenedCount: 1, accuracy: "中", importance: .medium, openedDate: .daysAgo(9), averageUsageDays: 30, usageHistoryCount: 3),
        StockProduct(name: "コーヒー", category: .food, state: .inUse, daysRemaining: 28, unopenedCount: 0, accuracy: "低", importance: .low, openedDate: .daysAgo(2), averageUsageDays: 30, usageHistoryCount: 1)
    ]
}

private extension StockProduct {
    init(item: Item) {
        id = item.id
        name = item.name
        category = ProductCategory(rawValue: item.categoryRawValue) ?? .other
        state = ProductState(rawValue: item.stateRawValue) ?? .inUse
        daysRemaining = item.daysRemaining
        unopenedCount = item.unopenedCount
        accuracy = item.accuracy
        importance = Importance(rawValue: item.importanceRawValue) ?? .medium
        openedDate = item.openedDate
        expirationDate = item.expirationDate
        averageUsageDays = item.averageUsageDays
        usageHistoryCount = item.usageHistoryCount
        minimumStockCount = item.minimumStockCount
        purchaseUnit = item.purchaseUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "個" : item.purchaseUnit
        usageScope = UsageScope(rawValue: item.usageScopeRawValue) ?? .household
        preferredStore = item.preferredStore
        barcode = item.barcode
        purchaseURLString = item.purchaseURLString
        memo = item.memo
        storageLocation = item.storageLocation
        tags = item.tags
        photoData = item.photoData
        notificationsEnabled = item.productNotificationsEnabled
    }
}

private extension Item {
    convenience init(product: StockProduct) {
        self.init(
            id: product.id,
            name: product.name,
            categoryRawValue: product.category.rawValue,
            stateRawValue: product.state.rawValue,
            daysRemaining: product.daysRemaining,
            unopenedCount: product.unopenedCount,
            accuracy: product.accuracy,
            importanceRawValue: product.importance.rawValue,
            openedDate: product.openedDate,
            expirationDate: product.expirationDate,
            averageUsageDays: product.averageUsageDays,
            usageHistoryCount: product.usageHistoryCount,
            minimumStockCount: product.minimumStockCount,
            purchaseUnit: product.normalizedPurchaseUnit,
            usageScopeRawValue: product.usageScope.rawValue,
            preferredStore: product.normalizedPreferredStore,
            barcode: product.barcode.trimmingCharacters(in: .whitespacesAndNewlines),
            purchaseURLString: product.purchaseURLString,
            memo: product.memo,
            storageLocation: product.storageLocation,
            tags: product.tags,
            photoData: product.photoData,
            productNotificationsEnabled: product.notificationsEnabled
        )
    }
}

struct PriceInsight: Equatable {
    let latestPrice: Int
    let minPrice: Int
    let maxPrice: Int
    let previousPrice: Int?

    var previousComparisonText: String {
        guard let previousPrice else { return "前回比なし" }
        let difference = latestPrice - previousPrice
        if difference == 0 { return "前回と同じ" }
        let amount = JapaneseCurrencyFormatter.yen(abs(difference))
        return difference > 0 ? "前回より\(amount)高い" : "前回より\(amount)安い"
    }

    var rangeText: String {
        "最安 \(JapaneseCurrencyFormatter.yen(minPrice)) / 最高 \(JapaneseCurrencyFormatter.yen(maxPrice))"
    }
}

nonisolated enum PriceInsightService {
    static func insight(from purchases: [PurchaseHistoryEntry]) -> PriceInsight? {
        let pricedPurchases = purchases
            .filter { $0.price != nil }
            .sorted { $0.purchasedAt > $1.purchasedAt }
        guard let latest = pricedPurchases.first?.price else { return nil }

        let prices = pricedPurchases.compactMap(\.price)
        return PriceInsight(
            latestPrice: latest,
            minPrice: prices.min() ?? latest,
            maxPrice: prices.max() ?? latest,
            previousPrice: pricedPurchases.dropFirst().first?.price
        )
    }
}

struct PurchaseHistoryEntry: Identifiable, Hashable {
    let id: UUID
    let itemName: String
    let quantity: Int
    let price: Int?
    let store: String
    let purchasedAt: Date

    init(record: PurchaseRecord) {
        id = record.id
        itemName = record.itemName
        quantity = record.quantity
        price = record.price
        store = record.store
        purchasedAt = record.purchasedAt
    }
}

private struct UsageHistoryEntry: Identifiable, Hashable {
    let id: UUID
    let itemName: String
    let event: UsageEvent
    let daysRemainingBefore: Int?
    let daysRemainingAfter: Int?
    let openedAt: Date?
    let actualUsageDays: Int?
    let recordedAt: Date

    init(record: UsageRecord) {
        id = record.id
        itemName = record.itemName
        event = UsageEvent(rawValue: record.eventRawValue) ?? .stillHave
        daysRemainingBefore = record.daysRemainingBefore
        daysRemainingAfter = record.daysRemainingAfter
        openedAt = record.openedAt
        actualUsageDays = record.actualUsageDays
        recordedAt = record.recordedAt
    }
}

enum UsageDeletionMessage {
    fileprivate static func text(for usage: UsageHistoryEntry) -> String {
        text(forEventRawValue: usage.event.rawValue)
    }

    static func text(forEventRawValue eventRawValue: String) -> String {
        switch UsageEvent(rawValue: eventRawValue) {
        case .finished:
            return "この使い切り記録を削除すると、平均使用期間の予測も削除前の状態へ戻します。この操作は取り消せません。"
        case .stillHave:
            return "この「まだある」記録を削除すると、残り日数の予測も削除前の状態へ戻します。この操作は取り消せません。"
        case .opened:
            return "この開封記録を削除します。現在の商品状態はそのまま残ります。この操作は取り消せません。"
        case .none:
            return "この使用履歴を削除します。この操作は取り消せません。"
        }
    }
}

enum PurchaseDeletionMessage {
    static func text(quantity: Int) -> String {
        "\(quantity)個分を未開封ストックからも差し引きます。この操作は取り消せません。"
    }
}

enum ProductUrgency {
    case critical
    case soon
    case fine
    case unopened

    var statusText: String {
        switch self {
        case .critical: "今買っておくと安心"
        case .soon: "そろそろ買い時"
        case .fine: "まだ大丈夫"
        case .unopened: "未開封"
        }
    }

    var tint: Color {
        switch self {
        case .critical: Color(red: 0.90, green: 0.18, blue: 0.20)
        case .soon: Color(red: 0.91, green: 0.49, blue: 0.08)
        case .fine: Color(red: 0.08, green: 0.58, blue: 0.32)
        case .unopened: .secondary
        }
    }
}

private struct HomeView: View {
    let products: [StockProduct]
    let onAdd: () -> Void
    let onSelect: (StockProduct) -> Void
    let onNavigate: (AppTab, ShoppingFilterOption?, StockFilterOption?) -> Void
    @State private var isSoonExpanded = false
    @State private var isFineExpanded = false
    @State private var isShowingHomeInsight = false

    private var buyNowProducts: [StockProduct] {
        products.filter { $0.urgency == .critical }
    }

    private var soonProducts: [StockProduct] {
        products.filter { $0.urgency == .soon }
    }

    private var fineProducts: [StockProduct] {
        products.filter { $0.urgency == .fine }
    }

    private var summary: HomeSummary {
        HomeSummaryService.summary(for: products)
    }

    private var riskSummary: HomeRiskSummary {
        HomeRiskSummaryService.summary(for: products)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if products.isEmpty {
                        ContentUnavailableView {
                            Label("まだ登録されていません", systemImage: "shippingbox")
                        } description: {
                            Text("まずは、よく使うものを1つだけ登録してみましょう。")
                        } actions: {
                            Button("商品を追加", action: onAdd)
                                .buttonStyle(.borderedProminent)
                        }
                    } else if buyNowProducts.isEmpty {
                        HomeGreetingHeader(
                            title: "おはようございます",
                            subtitle: "必要なものだけ確認できます",
                            onInsight: { isShowingHomeInsight = true }
                        )
                        HomeSummaryGrid(summary: summary, onNavigate: onNavigate)
                        HomeRiskSummaryCard(summary: riskSummary)
                        NoShoppingNeededView(nextProduct: soonProducts.first ?? fineProducts.first)
                    } else {
                        HomeGreetingHeader(
                            title: "おはようございます",
                            subtitle: "今日買うと安心なものがあります",
                            onInsight: { isShowingHomeInsight = true }
                        )
                        HomeSummaryGrid(summary: summary, onNavigate: onNavigate)
                        HomeRiskSummaryCard(summary: riskSummary)
                        SectionHeader("今日の補充")

                        ForEach(buyNowProducts) { product in
                            Button {
                                onSelect(product)
                            } label: {
                                PriorityProductCard(product: product)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !soonProducts.isEmpty {
                        Divider()
                        ProductRowsSection(
                            title: "もうすぐ",
                            products: soonProducts,
                            isExpanded: $isSoonExpanded,
                            onSelect: onSelect
                        )
                    }

                    if !fineProducts.isEmpty {
                        Divider()
                        ProductRowsSection(
                            title: "まだ大丈夫",
                            products: fineProducts,
                            isExpanded: $isFineExpanded,
                            onSelect: onSelect
                        )
                    }
                }
                .padding()
            }
            .background(AppTheme.pageBackground)
            .navigationTitle("あとどれ？")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("商品を追加")
                }
            }
        }
        .sheet(isPresented: $isShowingHomeInsight) {
            HomeInsightView(products: products, onSelect: onSelect)
        }
    }
}

private struct HomeSummaryGrid: View {
    let summary: HomeSummary
    let onNavigate: (AppTab, ShoppingFilterOption?, StockFilterOption?) -> Void

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                HomeSummaryCard(title: "今週", value: summary.buyNowCount, symbol: "cart.badge.plus", tint: .red) {
                    onNavigate(.shopping, .thisWeek, nil)
                }
                HomeSummaryCard(title: "もうすぐ", value: summary.soonCount, symbol: "clock.badge.exclamationmark", tint: .orange) {
                    onNavigate(.shopping, .soon, nil)
                }
            }

            GridRow {
                HomeSummaryCard(title: summary.expiredCount > 0 ? "期限切れ" : "期限", value: summary.expiredCount > 0 ? summary.expiredCount : summary.expiringCount, symbol: "calendar.badge.clock", tint: .purple) {
                    onNavigate(.stock, nil, summary.expiredCount > 0 ? .expired : .expiring)
                }
                HomeSummaryCard(title: "ストック", value: summary.unopenedCount, symbol: "shippingbox.fill", tint: .blue) {
                    onNavigate(.stock, nil, .unopened)
                }
            }
        }
    }
}

private struct HomeSummaryCard: View {
    let title: String
    let value: Int
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.headline)
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(value)件")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(12)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(value)件")
    }
}

private struct HomeRiskSummaryCard: View {
    let summary: HomeRiskSummary

    var body: some View {
        if summary.expiredCount > 0 || summary.overstockedCount > 0 || summary.lowConfidenceCount > 0 {
            VStack(alignment: .leading, spacing: 10) {
                Label("確認ポイント", systemImage: "checklist")
                    .font(.headline)
                HStack(spacing: 12) {
                    RiskPill(title: "期限切れ", value: summary.expiredCount, tint: .purple)
                    RiskPill(title: "買いすぎ", value: summary.overstockedCount, tint: .blue)
                    RiskPill(title: "初期推定", value: summary.lowConfidenceCount, tint: .orange)
                }
            }
            .premiumSurface()
        }
    }
}

private struct RiskPill: View {
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.title3.weight(.bold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct OnboardingView: View {
    @Binding var notificationLeadDays: Int
    @Binding var expirationNotificationLeadDays: Int
    @Binding var defaultPurchaseProviderRawValue: String
    @Binding var usesAIForPurchaseSearch: Bool

    let onStart: () -> Void
    let onUseTemplates: ([StarterTemplate]) -> Void
    let onSkip: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.softBlue, AppTheme.softMint, Color(uiColor: .systemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 18) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 76, weight: .semibold))
                        .foregroundStyle(AppTheme.primary)
                        .symbolRenderingMode(.hierarchical)

                    VStack(spacing: 10) {
                        Text("必要な時だけ、知らせます")
                            .font(.largeTitle.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text("あとどれ？は、日用品の残り日数を見て、買い時だけを控えめに伝えます。")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                    }
                }

                VStack(spacing: 12) {
                    OnboardingPoint(symbol: "sparkles", title: "商品名だけで入力を提案", text: "カテゴリや持ちそうな期間を自動で補助します。")
                    OnboardingPoint(symbol: "calendar.badge.clock", title: "買い時や期限前に通知", text: "必要なタイミングだけリマインドします。")
                    OnboardingPoint(symbol: "chart.line.uptrend.xyaxis", title: "使うほど予測が育つ", text: "使い切り履歴から平均使用期間を更新します。")
                }

                InitialSetupSection(
                    notificationLeadDays: $notificationLeadDays,
                    expirationNotificationLeadDays: $expirationNotificationLeadDays,
                    defaultPurchaseProviderRawValue: $defaultPurchaseProviderRawValue,
                    usesAIForPurchaseSearch: $usesAIForPurchaseSearch
                )

                TemplateSelectionContent(
                    registeredNames: [],
                    selectionLimit: AppPlan.freeProductLimit,
                    primaryButtonTitle: "選んだテンプレートを登録",
                    onRegister: onUseTemplates
                )

                VStack(spacing: 12) {
                    Button("よく使うものを1つ登録", action: onStart)
                        .buttonStyle(PremiumSecondaryButtonStyle())
                    Button("あとで", action: onSkip)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
            .padding(24)
            }
        }
    }
}

private struct StarterTemplateRow: View {
    let template: StarterTemplate
    let isSelected: Bool
    let registeredCount: Int
    let selectableCount: Int
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: template.symbol)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : AppTheme.primary)
                    .frame(width: 42, height: 42)
                    .background(isSelected ? AppTheme.primary : AppTheme.softBlue, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(template.title)
                        .font(.headline)
                    Text(template.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AppTheme.primary : .secondary)
            }
            .premiumSurface(background: .white.opacity(0.76), stroke: isSelected ? AppTheme.primary.opacity(0.35) : .white.opacity(0.55))
        }
        .buttonStyle(.plain)
    }

    private var summaryText: String {
        if registeredCount > 0 {
            return "\(selectableCount)件追加可能・\(registeredCount)件は登録済み\(expirationSummary)"
        }

        return template.items.map(\.name).joined(separator: "・") + expirationSummary
    }

    private var expirationSummary: String {
        let count = template.items.filter { $0.expirationAfterDays != nil }.count
        return count > 0 ? "・期限目安\(count)件" : ""
    }
}

private struct TemplateSelectionView: View {
    let title: String
    let registeredNames: Set<String>
    let selectionLimit: Int?
    let onRegister: ([StarterTemplate]) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                TemplateSelectionContent(
                    registeredNames: registeredNames,
                    selectionLimit: selectionLimit,
                    primaryButtonTitle: "選んだテンプレートを追加"
                ) { templates in
                    onRegister(templates)
                    dismiss()
                }
                .padding()
            }
            .background(AppTheme.pageBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

private struct TemplateSelectionContent: View {
    let registeredNames: Set<String>
    let selectionLimit: Int?
    let primaryButtonTitle: String
    let onRegister: ([StarterTemplate]) -> Void

    @State private var selectedTemplateIDs: Set<StarterTemplate.ID> = [StarterTemplate.all[0].id]

    private var selectedTemplates: [StarterTemplate] {
        StarterTemplate.all.filter { selectedTemplateIDs.contains($0.id) }
    }

    private var selectedNewItemCount: Int {
        selectedTemplates
            .flatMap(\.items)
            .filter { !registeredNames.contains($0.name.normalizedProductName) }
            .count
    }

    private var registrableItemCount: Int {
        min(selectedNewItemCount, selectionLimit ?? selectedNewItemCount)
    }

    private var canRegister: Bool {
        registrableItemCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("テンプレートを選ぶ")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(StarterTemplate.all) { template in
                let registeredCount = template.items.filter { registeredNames.contains($0.name.normalizedProductName) }.count
                StarterTemplateRow(
                    template: template,
                    isSelected: selectedTemplateIDs.contains(template.id),
                    registeredCount: registeredCount,
                    selectableCount: template.items.count - registeredCount
                ) {
                    toggle(template)
                }
            }

            Text(limitText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                onRegister(selectedTemplates)
            } label: {
                Label("\(primaryButtonTitle)（\(registrableItemCount)件）", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(PremiumActionButtonStyle())
            .disabled(!canRegister)
        }
    }

    private var limitText: String {
        guard let selectionLimit else {
            return "登録済みの商品は自動で除外します。"
        }

        if selectionLimit == 0 {
            return "登録済みの商品は除外します。Freeの登録上限に達しています。"
        }

        return "登録済みの商品は除外します。Freeでは残り\(selectionLimit)件まで追加できます。"
    }

    private func toggle(_ template: StarterTemplate) {
        if selectedTemplateIDs.contains(template.id) {
            if selectedTemplateIDs.count > 1 {
                selectedTemplateIDs.remove(template.id)
            }
        } else {
            selectedTemplateIDs.insert(template.id)
        }
    }
}

private struct OnboardingPoint: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.primary)
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .premiumSurface(background: .white.opacity(0.76), stroke: .white.opacity(0.55))
    }
}

private struct InitialSetupSection: View {
    @Binding var notificationLeadDays: Int
    @Binding var expirationNotificationLeadDays: Int
    @Binding var defaultPurchaseProviderRawValue: String
    @Binding var usesAIForPurchaseSearch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("初期設定")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 14) {
                Picker("通知タイミング", selection: $notificationLeadDays) {
                    Text("1日前").tag(1)
                    Text("3日前").tag(3)
                    Text("7日前").tag(7)
                }

                Picker("期限通知", selection: $expirationNotificationLeadDays) {
                    Text("3日前").tag(3)
                    Text("7日前").tag(7)
                    Text("14日前").tag(14)
                    Text("30日前").tag(30)
                }

                Picker("購入先", selection: $defaultPurchaseProviderRawValue) {
                    ForEach(PurchaseProvider.allCases) { provider in
                        Text(provider.label).tag(provider.rawValue)
                    }
                }

                Toggle("AI提案を使う", isOn: $usesAIForPurchaseSearch)
            }
            .premiumSurface(background: .white.opacity(0.76), stroke: .white.opacity(0.55))
        }
    }
}

private struct PaywallView: View {
    let isProUser: Bool
    let registeredCount: Int
    let freeLimit: Int
    let proProductDisplayPrice: String?
    let storeStatusMessage: String
    let isLoadingStoreProducts: Bool
    let isPurchasingPro: Bool
    let onStartPro: () -> Void
    let onRestore: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "shippingbox.and.arrow.backward.fill")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(AppTheme.primary)
                            .frame(width: 72, height: 72)
                            .background(AppTheme.softBlue, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Text(isProUser ? "あとどれ？ Pro" : "もっと登録したくなったら")
                            .font(.largeTitle.weight(.bold))
                        Text("家中の消耗品をまとめて登録できます。")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        PaywallFeatureRow(text: "商品登録無制限")
                        PaywallFeatureRow(text: "買い時の商品だけを整理")
                        PaywallFeatureRow(text: "購入履歴と使用履歴で予測を改善")
                    }
                    .premiumSurface()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Free")
                                .font(.headline)
                            Spacer()
                            Text("\(min(registeredCount, freeLimit)) / \(freeLimit)")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }

                        ProgressView(value: Double(min(registeredCount, freeLimit)), total: Double(freeLimit))
                            .tint(AppTheme.primary)
                    }
                    .premiumSurface(background: AppTheme.softMint)

                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Pro月額", value: proProductDisplayPrice ?? "未設定")
                        Text(storeStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .premiumSurface()

                    VStack(spacing: 12) {
                        Button(proButtonTitle, action: onStartPro)
                            .buttonStyle(PremiumActionButtonStyle())
                            .disabled(isProUser || proProductDisplayPrice == nil || isLoadingStoreProducts || isPurchasingPro)
                        Button("購入を復元", action: onRestore)
                            .buttonStyle(PremiumSecondaryButtonStyle())
                            .disabled(isPurchasingPro)
                        Button("今はやめておく", action: onDismiss)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                }
                .padding()
            }
            .background(AppTheme.pageBackground)
            .navigationTitle("あとどれ？ Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる", action: onDismiss)
                }
            }
        }
    }

    private var proButtonTitle: String {
        if isProUser {
            return "Proは有効です"
        }
        if isPurchasingPro {
            return "購入処理中"
        }
        if isLoadingStoreProducts {
            return "商品情報を読み込み中"
        }
        if let proProductDisplayPrice {
            return "Proを始める \(proProductDisplayPrice)"
        }
        return "Pro商品が未設定です"
    }
}

private struct PaywallFeatureRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.body.weight(.medium))
            Spacer()
        }
    }
}

private struct HomeGreetingHeader: View {
    let title: String
    let subtitle: String
    let onInsight: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onInsight) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.primary)
                    .frame(width: 42, height: 42)
                    .background(AppTheme.softBlue, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("今日の提案")
        }
    }
}

private struct HomeInsightView: View {
    let products: [StockProduct]
    let onSelect: (StockProduct) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var generatedSummaryText: String?

    private var buyNowProducts: [StockProduct] {
        products.filter { $0.urgency == .critical }
    }

    private var soonProducts: [StockProduct] {
        products.filter { $0.urgency == .soon }
    }

    private var nextProduct: StockProduct? {
        (buyNowProducts + soonProducts + products.filter { $0.urgency == .fine }).first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(AppTheme.primary)
                            .frame(width: 58, height: 58)
                            .background(AppTheme.softBlue, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Text("今日の提案")
                            .font(.largeTitle.weight(.bold))
                        Text(generatedSummaryText ?? summaryText)
                            .foregroundStyle(.secondary)
                    }

                    if let nextProduct {
                        Button {
                            dismiss()
                            onSelect(nextProduct)
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(nextProductLabel)
                                    .font(.headline)
                                HStack(spacing: 12) {
                                    CategoryIcon(category: nextProduct.category, tint: nextProduct.urgency.tint)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(nextProduct.name)
                                            .font(.title3.weight(.semibold))
                                        Text(nextProduct.state == .unopened ? "ストック \(nextProduct.unopenedCount)\(nextProduct.normalizedPurchaseUnit)" : "あと\(nextProduct.daysText)")
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.bold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .premiumSurface(background: nextProduct.urgency.tint.opacity(0.08), stroke: nextProduct.urgency.tint.opacity(0.18))
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("見方")
                            .font(.headline)
                        Text("この提案は、残り日数・重要度・ストック状況から今日見るべき商品を整理しています。Apple Intelligence が使える環境では、今後ここにより自然な提案文を追加できます。")
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                    }
                    .premiumSurface()
                }
                .padding()
            }
            .background(AppTheme.pageBackground)
            .navigationTitle("今日の提案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .task(id: products.map(\.id).description) {
            generatedSummaryText = await HomeInsightTextProvider.text(for: products, fallback: summaryText)
        }
    }

    private var summaryText: String {
        if products.isEmpty {
            return "まずはよく使うものを1つ登録すると、買い時を提案できます。"
        }

        if !buyNowProducts.isEmpty {
            return "今日は\(buyNowProducts.count)件、買っておくと安心なものがあります。"
        }

        if !soonProducts.isEmpty {
            return "今日は急がなくて大丈夫です。次の買い時が近いものだけ確認しましょう。"
        }

        return "今日は買わなくて大丈夫です。必要な時だけ見れば十分です。"
    }

    private var nextProductLabel: String {
        if !buyNowProducts.isEmpty { return "今見るもの" }
        if !soonProducts.isEmpty { return "次に買い時になるもの" }
        return "次に確認するもの"
    }
}

private struct NoShoppingNeededView: View {
    let nextProduct: StockProduct?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 6) {
                    Text("今日は買わなくて大丈夫です")
                        .font(.title2.weight(.bold))
                    Text("次に必要になるものだけ控えめに表示します")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let nextProduct {
                VStack(alignment: .leading, spacing: 8) {
                    Text("次に買い時になるもの")
                        .font(.headline)
                    Text(nextProduct.name)
                        .font(.title3.weight(.semibold))
                    Text("あと\(nextProduct.daysText)")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.primary)
                }
                .premiumSurface()
            }
        }
        .premiumSurface(background: AppTheme.softMint)
    }
}

private struct PriorityProductCard: View {
    let product: StockProduct

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CategoryIcon(category: product.category, tint: product.urgency.tint)
                Text(product.name)
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("あと")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(product.daysRemaining ?? 0)")
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("日")
                        .font(.title2.weight(.semibold))
                }
            }

            Text(product.urgency.statusText)
                .font(.headline)
            Text("予測精度：\(product.accuracy)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .premiumSurface(background: product.urgency.tint.opacity(0.08), stroke: product.urgency.tint.opacity(0.20))
    }
}

private struct ProductRowsSection: View {
    let title: String
    let products: [StockProduct]
    @Binding var isExpanded: Bool
    let onSelect: (StockProduct) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    SectionHeader(title)
                    Text("\(products.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) \(products.count)件")
            .accessibilityHint(isExpanded ? "閉じます" : "開きます")

            if isExpanded {
                ForEach(products) { product in
                    Button {
                        onSelect(product)
                    } label: {
                        ProductRow(product: product)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else if let firstProduct = products.first {
                Button {
                    onSelect(firstProduct)
                } label: {
                    ProductRow(product: firstProduct)
                }
                .buttonStyle(.plain)
                .opacity(0.72)
            }
        }
    }
}

private struct ProductRow: View {
    let product: StockProduct
    var secondaryText: String?

    var body: some View {
        HStack(spacing: 12) {
            ProductPhotoView(product: product, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(product.name)
                    .font(.body.weight(.medium))
                if !product.storageLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(product.storageLocation, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(secondaryText ?? (product.state == .unopened ? "\(product.unopenedCount)\(product.normalizedPurchaseUnit)" : product.daysText))
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ShoppingView: View {
    let products: [StockProduct]
    @Binding var filterOption: ShoppingFilterOption
    let householdProfile: HouseholdProfile
    let purchaseDefaults: (StockProduct) -> PurchaseDefaults
    let onSelect: (StockProduct) -> Void
    let onSavedPurchase: (StockProduct, Int, Int?, String, Date) -> Void

    @State private var purchasingProduct: StockProduct?
    @State private var shareMemoText = ""
    @State private var groupsByStore = false
    @AppStorage("completedShoppingItemIDs") private var completedShoppingItemIDsText = ""

    private var completedPurchaseIDs: Set<UUID> {
        ShoppingCompletionStore.ids(from: completedShoppingItemIDsText)
    }

    private var displayedProducts: [StockProduct] {
        ShoppingFilterService.products(products, option: filterOption)
    }

    private var buyableProducts: [StockProduct] {
        displayedProducts.filter {
            PurchaseRecommendationService.recommendation(for: $0, householdProfile: householdProfile).shouldBuy
        }
    }

    private var deferredProducts: [StockProduct] {
        displayedProducts.filter {
            !PurchaseRecommendationService.recommendation(for: $0, householdProfile: householdProfile).shouldBuy
        }
    }

    private var buyableStoreGroups: [ShoppingStoreGroup] {
        StoreShoppingListService.groups(
            products: buyableProducts,
            preferredStore: { product in
                product.normalizedPreferredStore.isEmpty ? purchaseDefaults(product).store : product.normalizedPreferredStore
            }
        )
    }

    private var emptyMessage: String {
        switch filterOption {
        case .thisWeek: "今週買うものはありません"
        case .soon: "もうすぐ買うものはありません"
        case .all: "買い物対象の商品はありません"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("表示", selection: $filterOption) {
                        ForEach(ShoppingFilterOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if displayedProducts.isEmpty {
                    ContentUnavailableView(emptyMessage, systemImage: "checkmark.circle", description: Text("必要なものが出てきたらここに表示します。"))
                } else if filterOption == .thisWeek {
                    if groupsByStore {
                        ForEach(buyableStoreGroups) { group in
                            Section(group.storeName) {
                                ForEach(group.products) { product in
                                    shoppingCard(for: product)
                                }
                            }
                        }
                    } else {
                        Section(filterOption.rawValue) {
                            ForEach(buyableProducts) { product in
                                shoppingCard(for: product)
                            }
                        }
                    }
                } else {
                    Section(filterOption.rawValue) {
                        ForEach(buyableProducts) { product in
                            shoppingCard(for: product)
                        }
                    }
                }

                if !deferredProducts.isEmpty {
                    Section("今回は見送り") {
                        ForEach(deferredProducts) { product in
                            ProductRow(
                                product: product,
                                secondaryText: PurchaseRecommendationService.recommendation(for: product, householdProfile: householdProfile).reason
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect(product)
                            }
                        }
                    }
                }
            }
            .navigationTitle("買い物")
            .toolbar {
                if !completedPurchaseIDs.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("完了をクリア") {
                            withAnimation(.snappy) {
                                completedShoppingItemIDsText = ""
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }

                if !buyableProducts.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Toggle(isOn: $groupsByStore) {
                            Image(systemName: "storefront")
                        }
                        .toggleStyle(.button)
                        .accessibilityLabel("店舗別に表示")
                    }
                }

                if !buyableProducts.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(
                            item: shareMemoText.isEmpty ? storeGroupedMemoText : shareMemoText,
                            subject: Text("あとどれ？ 買い物メモ")
                        ) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("買い物メモを共有")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .task(id: "\(buyableProducts.map(\.id).description)-\(householdProfile.displayText)") {
                shareMemoText = storeGroupedMemoText
            }
        }
        .sheet(item: $purchasingProduct) { product in
            PurchaseSheet(
                product: product,
                initialQuantity: PurchaseRecommendationService.recommendation(for: product, householdProfile: householdProfile).quantity,
                defaults: purchaseDefaults(product)
            ) { quantity, price, store, purchasedAt in
                onSavedPurchase(product, quantity, price, store, purchasedAt)
                markPurchaseCompleted(for: product)
            }
            .presentationDetents([.medium])
        }
    }

    private func markPurchaseCompleted(for product: StockProduct) {
        var ids = completedPurchaseIDs
        _ = ids.insert(product.id)
        withAnimation(.snappy) {
            completedShoppingItemIDsText = ShoppingCompletionStore.text(from: ids)
        }
    }

    private var storeGroupedMemoText: String {
        StoreShoppingListService.memoText(
            groups: buyableStoreGroups,
            householdProfile: householdProfile
        )
    }

    private func shoppingCard(for product: StockProduct) -> some View {
        ShoppingCard(
            product: product,
            recommendation: PurchaseRecommendationService.recommendation(for: product, householdProfile: householdProfile),
            isCompleted: completedPurchaseIDs.contains(product.id)
        ) {
            purchasingProduct = product
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(product)
        }
    }
}

nonisolated enum ShoppingCompletionStore {
    static func ids(from text: String) -> Set<UUID> {
        Set(
            text
                .split(separator: ",")
                .compactMap { UUID(uuidString: String($0)) }
        )
    }

    static func text(from ids: Set<UUID>) -> String {
        ids
            .map(\.uuidString)
            .sorted()
            .joined(separator: ",")
    }
}

private struct ShoppingCard: View {
    let product: StockProduct
    let recommendation: PurchaseRecommendation
    let isCompleted: Bool
    let onBought: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CategoryIcon(category: product.category, tint: product.urgency.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.name)
                        .font(.headline)
                    Text("あと\(product.daysText)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Label("おすすめ \(recommendation.quantity)\(product.normalizedPurchaseUnit)", systemImage: "cart.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primary)
                Spacer()
                Text(recommendation.reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if isCompleted {
                Label("記録済み", systemImage: "checkmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                Button("買いました", action: onBought)
                    .buttonStyle(PremiumActionButtonStyle())
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct StockView: View {
    let products: [StockProduct]
    @Binding var filterOption: StockFilterOption
    let usageHistories: [UsageHistoryEntry]
    let onAdd: () -> Void
    let onSelect: (StockProduct) -> Void
    let onBought: (StockProduct) -> Void
    let onOpened: (StockProduct) -> Void
    let onFinished: (StockProduct) -> Void
    let onDeleteUsage: (UsageHistoryEntry) -> Void

    @State private var searchText = ""
    @State private var sortOption = StockSortOption.recommended
    @State private var isShowingUsageArchive = false

    private var filteredProducts: [StockProduct] {
        let filteredByMode = StockFilterService.products(products, option: filterOption)
        let filteredBySearch = StockSearchService.filteredProducts(filteredByMode, query: searchText)
        return StockSortService.sortedProducts(filteredBySearch, option: sortOption)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inUseProducts: [StockProduct] {
        filteredProducts.filter { $0.state == .inUse }
    }

    private var expiringProducts: [StockProduct] {
        filteredProducts
            .filter { $0.isExpirationSoon && ($0.expirationDaysRemaining ?? 1) >= 0 }
            .sorted { ($0.expirationDaysRemaining ?? .max) < ($1.expirationDaysRemaining ?? .max) }
    }

    private var expiredProducts: [StockProduct] {
        filteredProducts
            .filter { ($0.expirationDaysRemaining ?? 1) < 0 }
            .sorted { ($0.expirationDaysRemaining ?? .max) < ($1.expirationDaysRemaining ?? .max) }
    }

    private var unopenedProducts: [StockProduct] {
        filteredProducts.filter { $0.state == .unopened || $0.unopenedCount > 0 }
    }

    private var emptyMessage: String {
        if isSearching {
            return "見つかりませんでした"
        }

        switch filterOption {
        case .all: return "商品がありません"
        case .expired: return "期限切れの商品はありません"
        case .expiring: return "期限が近い商品はありません"
        case .inUse: return "使用中の商品はありません"
        case .unopened: return "未開封の商品はありません"
        }
    }

    @ViewBuilder private var unopenedRows: some View {
        ForEach(unopenedProducts) { product in
            HStack(spacing: 12) {
                CategoryIcon(category: product.category, tint: .secondary)
                Text(product.name)
                Spacer()
                Text("\(max(product.unopenedCount, 1))\(product.normalizedPurchaseUnit)")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect(product)
            }
            .swipeActions(edge: .leading) {
                Button("買いました") {
                    onBought(product)
                }
                .tint(AppTheme.primary)

                Button("開けました") {
                    onOpened(product)
                }
                .tint(.green)
            }
        }
    }

    private func stockRow(for product: StockProduct, secondaryText: String? = nil) -> some View {
        ProductRow(product: product, secondaryText: secondaryText)
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect(product)
            }
            .swipeActions(edge: .leading) {
                Button("買いました") {
                    onBought(product)
                }
                .tint(AppTheme.primary)

                if product.state == .unopened || product.unopenedCount > 0 {
                    Button("開けました") {
                        onOpened(product)
                    }
                    .tint(.green)
                }
            }
            .swipeActions(edge: .trailing) {
                if product.state == .inUse {
                    Button("なくなった") {
                        onFinished(product)
                    }
                    .tint(.orange)
                }
            }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("表示", selection: $filterOption) {
                        ForEach(StockFilterOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("行をタップすると詳細を確認できます。左スワイプで「買いました」「開けました」「なくなった」を記録できます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if filteredProducts.isEmpty {
                    ContentUnavailableView(
                        emptyMessage,
                        systemImage: "magnifyingglass",
                        description: Text("商品名、カテゴリ、状態を変えて検索してください。")
                    )
                } else {
                    switch filterOption {
                    case .all:
                        if !expiredProducts.isEmpty {
                            Section("期限切れ") {
                                ForEach(expiredProducts) { product in
                                    stockRow(for: product, secondaryText: product.expirationText)
                                }
                            }
                        }

                        if !expiringProducts.isEmpty {
                            Section("期限が近い") {
                                ForEach(expiringProducts) { product in
                                    stockRow(for: product, secondaryText: product.expirationText)
                                }
                            }
                        }

                        Section("使用中") {
                            ForEach(inUseProducts) { product in
                                stockRow(for: product)
                            }
                        }

                        Section("未開封") {
                            unopenedRows
                        }
                    case .expired:
                        Section("期限切れ") {
                            ForEach(expiredProducts) { product in
                                stockRow(for: product, secondaryText: product.expirationText)
                            }
                        }
                    case .expiring:
                        Section("期限が近い") {
                            ForEach(expiringProducts) { product in
                                stockRow(for: product, secondaryText: product.expirationText)
                                }
                        }
                    case .inUse:
                        Section("使用中") {
                            ForEach(inUseProducts) { product in
                                stockRow(for: product)
                            }
                        }
                    case .unopened:
                        Section("未開封") {
                            unopenedRows
                        }
                    }

                    Section("使い切り") {
                        Button {
                            isShowingUsageArchive = true
                        } label: {
                            HStack {
                                Label("過去の商品を見る", systemImage: "clock.arrow.circlepath")
                                Spacer()
                                Text("\(usageHistories.count)件")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("ストック")
            .searchable(text: $searchText, prompt: "商品を検索")
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Menu {
                            Picker("並び替え", selection: $sortOption) {
                                ForEach(StockSortOption.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .accessibilityLabel("並び替え")

                        Button(action: onAdd) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("商品を追加")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingUsageArchive) {
            AllUsageHistoryView(usages: usageHistories, onDelete: onDeleteUsage)
        }
    }
}

private struct ProductDetailView: View {
    let product: StockProduct
    let purchases: [PurchaseHistoryEntry]
    let usages: [UsageHistoryEntry]
    let onStillHave: (StockProduct) -> Void
    let onFinished: (StockProduct, Date) -> Void
    let onOpened: (StockProduct, Date) -> Void
    let onOpenPurchasePage: (StockProduct) async -> Void
    let onSavePurchaseURL: (StockProduct, String) -> Void
    let onRecordPurchase: (StockProduct, Int, Int?, String, Date) -> Void
    let onEdit: (StockProduct) -> Void
    let onDelete: (StockProduct) -> Void
    let onDeletePurchase: (PurchaseHistoryEntry) -> Void
    let onUpdatePurchase: (PurchaseHistoryEntry, Int, Int?, String, Date) -> Void
    let onDeleteUsage: (UsageHistoryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isShowingFinishedDialog = false
    @State private var isShowingOpenedDialog = false
    @State private var isShowingDeleteDialog = false
    @State private var isShowingExpiredDiscardDialog = false
    @State private var isShowingFinishedDateSheet = false
    @State private var isShowingOpenedDateSheet = false
    @State private var isShowingUsageHistory = false
    @State private var isShowingPurchaseHistory = false
    @State private var isShowingPurchaseActions = false
    @State private var isShowingPurchaseSheet = false
    @State private var isShowingPurchaseURLSheet = false
    @State private var isShowingEditSheet = false
    @State private var finishedDate = Date()
    @State private var openedDate = Date()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        ProductPhotoView(product: product, size: 92)
                        Text(product.name)
                            .font(.title2.weight(.semibold))

                        if product.state == .inUse, let daysRemaining = product.daysRemaining {
                            VStack(spacing: 4) {
                                Text("あと")
                                    .foregroundStyle(.secondary)
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text("\(daysRemaining)")
                                        .font(.system(size: 58, weight: .bold, design: .rounded))
                                    Text("日")
                                        .font(.title2.weight(.semibold))
                                }
                                Text("予測精度：\(product.accuracy)")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("未開封")
                                .font(.largeTitle.weight(.bold))
                            Text("ストック \(max(product.unopenedCount, 1))個")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    if (product.expirationDaysRemaining ?? 1) < 0 {
                        ExpiredProductActionCard(
                            product: product,
                            onClearExpiration: clearExpiration,
                            onDiscard: {
                                isShowingExpiredDiscardDialog = true
                            }
                        )
                    }

                    if let priceInsight = PriceInsightService.insight(from: purchases) {
                        PriceInsightCard(insight: priceInsight)
                    }

                    if product.state == .inUse {
                        InUseDetailContent(
                            product: product,
                            purchaseStats: PurchaseStats(purchases: purchases),
                            onStillHave: {
                                onStillHave(product)
                            },
                            onFinished: {
                                isShowingFinishedDialog = true
                            },
                            onBought: {
                                isShowingPurchaseActions = true
                            },
                            onShowUsageHistory: {
                                isShowingUsageHistory = true
                            },
                            onShowPurchaseHistory: {
                                isShowingPurchaseHistory = true
                            },
                            onDeleteRequest: {
                                isShowingDeleteDialog = true
                            }
                        )
                    } else {
                        UnopenedDetailContent(
                            product: product,
                            latestPurchaseDate: purchases.first?.purchasedAt,
                            purchaseStats: PurchaseStats(purchases: purchases),
                            onOpened: { isShowingOpenedDialog = true },
                            onBought: { isShowingPurchaseSheet = true },
                            onDeleteRequest: { isShowingDeleteDialog = true }
                        )
                    }
                }
                .padding()
            }
            .background(AppTheme.pageBackground)
            .navigationTitle("商品詳細")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("編集") {
                        isShowingEditSheet = true
                    }
                }
            }
            .confirmationDialog("使い切りましたか？", isPresented: $isShowingFinishedDialog, titleVisibility: .visible) {
                Button("今日なくなった") {
                    onFinished(product, Date())
                    dismiss()
                }
                Button("日付を変更") {
                    finishedDate = Date()
                    isShowingFinishedDateSheet = true
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("この情報を使って次回の予測を改善します。")
            }
            .confirmationDialog("今日から使い始めますか？", isPresented: $isShowingOpenedDialog, titleVisibility: .visible) {
                Button("今日から使う") {
                    onOpened(product, Date())
                }
                Button("日付を変更") {
                    openedDate = Date()
                    isShowingOpenedDateSheet = true
                }
                Button("キャンセル", role: .cancel) {}
            }
            .confirmationDialog("商品を削除しますか？", isPresented: $isShowingDeleteDialog, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    onDelete(product)
                    dismiss()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("購入履歴と使用履歴も削除されます。")
            }
            .confirmationDialog("期限切れの商品を破棄しますか？", isPresented: $isShowingExpiredDiscardDialog, titleVisibility: .visible) {
                Button("破棄する", role: .destructive) {
                    onDelete(product)
                    dismiss()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("商品、購入履歴、使用履歴をまとめて削除します。期限だけ外す場合は「期限を外す」を使ってください。")
            }
            .confirmationDialog("いつもの商品を買う", isPresented: $isShowingPurchaseActions, titleVisibility: .visible) {
                Button("購入ページを開く") {
                    Task {
                        await onOpenPurchasePage(product)
                    }
                }
                Button("買いました") {
                    isShowingPurchaseSheet = true
                }
                Button(product.purchaseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "いつもの購入先を設定" : "購入先を編集") {
                    isShowingPurchaseURLSheet = true
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("URLが未設定の場合は、設定した購入先で検索します。")
            }
            .sheet(isPresented: $isShowingUsageHistory) {
                UsageHistoryView(productName: product.name, usages: usages, onDelete: onDeleteUsage)
            }
            .sheet(isPresented: $isShowingPurchaseHistory) {
                PurchaseHistoryView(
                    productName: product.name,
                    purchaseUnit: product.normalizedPurchaseUnit,
                    purchases: purchases,
                    onUpdate: onUpdatePurchase,
                    onDelete: onDeletePurchase
                )
            }
            .sheet(isPresented: $isShowingPurchaseSheet) {
                PurchaseSheet(product: product, defaults: preferredPurchaseDefaults) { quantity, price, store, purchasedAt in
                    onRecordPurchase(product, quantity, price, store, purchasedAt)
                }
            }
            .sheet(isPresented: $isShowingPurchaseURLSheet) {
                PurchaseURLSettingsSheet(product: product) { urlString in
                    onSavePurchaseURL(product, urlString)
                }
            }
            .sheet(isPresented: $isShowingEditSheet) {
                EditProductView(product: product) { editedProduct in
                    onEdit(editedProduct)
                }
            }
            .sheet(isPresented: $isShowingFinishedDateSheet) {
                DateSelectionSheet(title: "使い切った日", date: $finishedDate, range: ...Date()) {
                    onFinished(product, finishedDate)
                    isShowingFinishedDateSheet = false
                    dismiss()
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isShowingOpenedDateSheet) {
                DateSelectionSheet(title: "開けた日", date: $openedDate, range: ...Date()) {
                    onOpened(product, openedDate)
                    isShowingOpenedDateSheet = false
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func clearExpiration() {
        var editedProduct = product
        editedProduct.expirationDate = nil
        onEdit(editedProduct)
    }

    private var preferredPurchaseDefaults: PurchaseDefaults {
        let defaults = PurchaseDefaultsService.defaults(from: purchases)
        guard !product.normalizedPreferredStore.isEmpty else { return defaults }
        return PurchaseDefaults(price: defaults.price, averagePrice: defaults.averagePrice, store: product.normalizedPreferredStore)
    }
}

private struct ExpiredProductActionCard: View {
    let product: StockProduct
    let onClearExpiration: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("期限切れです", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("\(product.name)の期限を確認してください。消費済み・期限入力ミスなら期限を外し、不要なら破棄できます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("期限を外す", action: onClearExpiration)
                    .buttonStyle(.bordered)
                Button("破棄する", role: .destructive, action: onDiscard)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PriceInsightCard: View {
    let insight: PriceInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("価格メモ", systemImage: "chart.line.uptrend.xyaxis")
                .font(.headline)
                .foregroundStyle(AppTheme.primary)
            HStack {
                LabeledContent("直近", value: JapaneseCurrencyFormatter.yen(insight.latestPrice))
                Spacer()
            }
            Text(insight.previousComparisonText)
                .font(.subheadline.weight(.semibold))
            Text(insight.rangeText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct InUseDetailContent: View {
    let product: StockProduct
    let purchaseStats: PurchaseStats
    let onStillHave: () -> Void
    let onFinished: () -> Void
    let onBought: () -> Void
    let onShowUsageHistory: () -> Void
    let onShowPurchaseHistory: () -> Void
    let onDeleteRequest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text(product.urgency.statusText)
                    .font(.title3.weight(.semibold))
                DetailDateRow(title: "予想終了日", date: product.expectedEndDate)
                DetailDateRow(title: "推奨購入日", date: product.recommendedBuyDate)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("今の状態を教えてください")
                    .font(.headline)
                Button("まだある", action: onStillHave)
                    .buttonStyle(PremiumSecondaryButtonStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("なくなった", action: onFinished)
                    .buttonStyle(PremiumActionButtonStyle(tint: product.urgency.tint))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Button {
                onBought()
            } label: {
                Label("いつもの商品を買う", systemImage: "cart.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PremiumSecondaryButtonStyle())

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("使用情報")
                    .font(.headline)
                DetailInfoRow(title: "開封日", value: product.openedDate.map(JapaneseDateFormatter.shortDate) ?? "不明")
                DetailInfoRow(title: "平均使用期間", value: "約\(product.averageUsageDays)日")
                DetailInfoRow(title: "予測根拠", value: PredictionConfidenceService.explanation(for: product))
                DetailInfoRow(title: "最低ストック", value: "\(product.minimumStockCount)\(product.normalizedPurchaseUnit)")
                DetailInfoRow(title: "購入単位", value: product.normalizedPurchaseUnit)
                DetailInfoRow(title: "利用対象", value: product.usageScope.rawValue)
                DetailInfoRow(title: "期限", value: product.expirationText ?? "未設定")
                DetailInfoRow(title: "使用履歴", value: "\(product.usageHistoryCount)回")
                DetailInfoRow(title: "通知", value: product.notificationsEnabled ? "オン" : "オフ")
                if !product.storageLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DetailInfoRow(title: "置き場所", value: product.storageLocation)
                }
                if !product.normalizedPreferredStore.isEmpty {
                    DetailInfoRow(title: "優先店舗", value: product.normalizedPreferredStore)
                }
                if !product.barcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DetailInfoRow(title: "バーコード", value: product.barcode)
                }
                if !product.tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DetailInfoRow(title: "タグ", value: product.tags)
                }
                if !product.memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DetailInfoRow(title: "メモ", value: product.memo)
                }

                if purchaseStats.purchaseCount > 0 {
                    DetailInfoRow(title: "購入回数", value: "\(purchaseStats.purchaseCount)回")
                    DetailInfoRow(title: "直近価格", value: purchaseStats.latestPrice.map(JapaneseCurrencyFormatter.yen) ?? "未記録")
                    DetailInfoRow(title: "平均価格", value: purchaseStats.averagePrice.map(JapaneseCurrencyFormatter.yen) ?? "未記録")
                    if let frequentStore = purchaseStats.frequentStore {
                        DetailInfoRow(title: "よく買う店", value: frequentStore)
                    }
                }

                Button("使用履歴を見る", action: onShowUsageHistory)
                Button("購入履歴を見る", action: onShowPurchaseHistory)
            }

            Divider()

            Button(role: .destructive) {
                onDeleteRequest()
            } label: {
                Label("商品を削除", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct UnopenedDetailContent: View {
    let product: StockProduct
    let latestPurchaseDate: Date?
    let purchaseStats: PurchaseStats
    let onOpened: () -> Void
    let onBought: () -> Void
    let onDeleteRequest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Divider()
            DetailInfoRow(title: "最終購入日", value: latestPurchaseDate.map(JapaneseDateFormatter.shortDate) ?? "未記録")
            DetailInfoRow(title: "期限", value: product.expirationText ?? "未設定")
            DetailInfoRow(title: "最低ストック", value: "\(product.minimumStockCount)\(product.normalizedPurchaseUnit)")
            DetailInfoRow(title: "購入単位", value: product.normalizedPurchaseUnit)
            DetailInfoRow(title: "利用対象", value: product.usageScope.rawValue)
            if !product.storageLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DetailInfoRow(title: "置き場所", value: product.storageLocation)
            }
            if !product.normalizedPreferredStore.isEmpty {
                DetailInfoRow(title: "優先店舗", value: product.normalizedPreferredStore)
            }
            if !product.barcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DetailInfoRow(title: "バーコード", value: product.barcode)
            }
            if !product.tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DetailInfoRow(title: "タグ", value: product.tags)
            }
            if !product.memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DetailInfoRow(title: "メモ", value: product.memo)
            }
            if purchaseStats.purchaseCount > 0 {
                DetailInfoRow(title: "購入回数", value: "\(purchaseStats.purchaseCount)回")
                DetailInfoRow(title: "直近価格", value: purchaseStats.latestPrice.map(JapaneseCurrencyFormatter.yen) ?? "未記録")
                DetailInfoRow(title: "平均価格", value: purchaseStats.averagePrice.map(JapaneseCurrencyFormatter.yen) ?? "未記録")
            }
            Button("開けました", action: onOpened)
                .buttonStyle(PremiumActionButtonStyle())
            Button("買いました", action: onBought)
                .buttonStyle(PremiumSecondaryButtonStyle())
            Divider()
            Button(role: .destructive) {
                onDeleteRequest()
            } label: {
                Label("商品を削除", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageHistoryView: View {
    let productName: String
    let usages: [UsageHistoryEntry]
    let onDelete: (UsageHistoryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: UsageHistoryEntry?

    var body: some View {
        NavigationStack {
            List {
                if usages.isEmpty {
                    ContentUnavailableView("使用履歴はまだありません", systemImage: "clock", description: Text("使い切りや状態更新をするとここに残ります。"))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(usages) { usage in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(usage.event.rawValue, systemImage: usage.event.symbol)
                                    .font(.headline)
                                Spacer()
                                Text(JapaneseDateFormatter.shortDate(usage.recordedAt))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            if let before = usage.daysRemainingBefore, let after = usage.daysRemainingAfter {
                                Text("あと約\(before)日 → 約\(after)日")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else if let after = usage.daysRemainingAfter {
                                Text("あと約\(after)日から予測開始")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            if let actualUsageDays = usage.actualUsageDays {
                                Text("実際の使用期間 約\(actualUsageDays)日")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .swipeActions {
                            Button("削除", role: .destructive) {
                                pendingDeletion = usage
                            }
                        }
                    }
                }
            }
            .navigationTitle(productName)
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .confirmationDialog("使用履歴を削除しますか？", isPresented: isConfirmingDeletion, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if let pendingDeletion {
                        onDelete(pendingDeletion)
                    }
                    pendingDeletion = nil
                }
                Button("キャンセル", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: {
                if let pendingDeletion {
                    Text(UsageDeletionMessage.text(for: pendingDeletion))
                } else {
                    Text("この操作は取り消せません。")
                }
            }
        }
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }
}

private struct AllUsageHistoryView: View {
    let usages: [UsageHistoryEntry]
    let onDelete: (UsageHistoryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: UsageHistoryEntry?

    var body: some View {
        NavigationStack {
            List {
                if usages.isEmpty {
                    ContentUnavailableView("過去の商品はまだありません", systemImage: "clock", description: Text("使い切りや開封を記録するとここに残ります。"))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(usages) { usage in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                Label(usage.event.rawValue, systemImage: usage.event.symbol)
                                    .font(.headline)
                                Spacer()
                                Text(JapaneseDateFormatter.shortDate(usage.recordedAt))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Text(usage.itemName)
                                .font(.subheadline.weight(.semibold))

                            if let actualUsageDays = usage.actualUsageDays {
                                Text("実際の使用期間 約\(actualUsageDays)日")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else if let before = usage.daysRemainingBefore, let after = usage.daysRemainingAfter {
                                Text("あと約\(before)日 → 約\(after)日")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else if let after = usage.daysRemainingAfter {
                                Text("あと約\(after)日から予測開始")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .swipeActions {
                            Button("削除", role: .destructive) {
                                pendingDeletion = usage
                            }
                        }
                    }
                }
            }
            .navigationTitle("過去の商品")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .confirmationDialog("使用履歴を削除しますか？", isPresented: isConfirmingDeletion, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if let pendingDeletion {
                        onDelete(pendingDeletion)
                    }
                    pendingDeletion = nil
                }
                Button("キャンセル", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: {
                if let pendingDeletion {
                    Text(UsageDeletionMessage.text(for: pendingDeletion))
                } else {
                    Text("この操作は取り消せません。")
                }
            }
        }
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }
}

private struct PurchaseHistoryView: View {
    let productName: String
    let purchaseUnit: String
    let purchases: [PurchaseHistoryEntry]
    let onUpdate: (PurchaseHistoryEntry, Int, Int?, String, Date) -> Void
    let onDelete: (PurchaseHistoryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editingPurchase: PurchaseHistoryEntry?
    @State private var pendingDeletion: PurchaseHistoryEntry?

    var body: some View {
        NavigationStack {
            List {
                if purchases.isEmpty {
                    ContentUnavailableView("購入履歴はまだありません", systemImage: "cart", description: Text("買いましたを保存するとここに残ります。"))
                        .listRowBackground(Color.clear)
                } else {
                    PriceHistoryChartView(purchases: purchases)

                    ForEach(purchases) { purchase in
                        Button {
                            editingPurchase = purchase
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label("\(purchase.quantity)\(purchaseUnit)", systemImage: "cart.fill")
                                        .font(.headline)
                                    Spacer()
                                    Text(JapaneseDateFormatter.shortDate(purchase.purchasedAt))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: 12) {
                                    if let price = purchase.price {
                                        Text(JapaneseCurrencyFormatter.yen(price))
                                    }
                                    if !purchase.store.isEmpty {
                                        Text(purchase.store)
                                    }
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 6)
                        .swipeActions {
                            Button("削除", role: .destructive) {
                                pendingDeletion = purchase
                            }
                        }
                    }
                }
            }
            .navigationTitle(productName)
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .confirmationDialog("購入履歴を削除しますか？", isPresented: isConfirmingDeletion, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if let pendingDeletion {
                        onDelete(pendingDeletion)
                    }
                    pendingDeletion = nil
                }
                Button("キャンセル", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: {
                if let pendingDeletion {
                    Text(PurchaseDeletionMessage.text(quantity: pendingDeletion.quantity))
                } else {
                    Text("この操作は取り消せません。")
                }
            }
            .sheet(item: $editingPurchase) { purchase in
                PurchaseSheet(productName: productName, purchaseUnit: purchaseUnit, purchase: purchase) { quantity, price, store, purchasedAt in
                    onUpdate(purchase, quantity, price, store, purchasedAt)
                }
            }
        }
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }
}

private struct PriceHistoryChartView: View {
    let purchases: [PurchaseHistoryEntry]

    private var pricePoints: [PurchaseHistoryEntry] {
        purchases
            .filter { $0.price != nil }
            .sorted { $0.purchasedAt < $1.purchasedAt }
            .suffix(8)
            .map { $0 }
    }

    private var maxPrice: Int {
        pricePoints.compactMap(\.price).max() ?? 1
    }

    var body: some View {
        if !pricePoints.isEmpty {
            Section("価格推移") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(pricePoints) { purchase in
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(AppTheme.primary.gradient)
                                    .frame(height: barHeight(for: purchase.price ?? 0))
                                Text(JapaneseDateFormatter.shortDate(purchase.purchasedAt))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 120)

                    HStack {
                        Text("最高 \(JapaneseCurrencyFormatter.yen(maxPrice))")
                        Spacer()
                        if let latestPrice = pricePoints.last?.price {
                            Text("直近 \(JapaneseCurrencyFormatter.yen(latestPrice))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func barHeight(for price: Int) -> CGFloat {
        guard maxPrice > 0 else { return 12 }
        return max(12, CGFloat(price) / CGFloat(maxPrice) * 86)
    }
}

private struct DateSelectionSheet: View {
    let title: String
    @Binding var date: Date
    let range: PartialRangeThrough<Date>
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(title, selection: $date, in: range, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: onSave)
                }
            }
        }
    }
}

private struct EditProductView: View {
    let product: StockProduct
    let onSave: (StockProduct) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var category: ProductCategory
    @State private var productState: ProductState
    @State private var daysRemaining: Int
    @State private var unopenedCount: Int
    @State private var minimumStockCount: Int
    @State private var purchaseUnit: String
    @State private var usageScope: UsageScope
    @State private var averageUsageDays: Int
    @State private var importance: Importance
    @State private var hasExpirationDate: Bool
    @State private var expirationDate: Date
    @State private var purchaseURLString: String
    @State private var preferredStore: String
    @State private var barcode: String
    @State private var memo: String
    @State private var storageLocation: String
    @State private var tags: String
    @State private var photoData: Data?
    @State private var productNotificationsEnabled: Bool

    init(product: StockProduct, onSave: @escaping (StockProduct) -> Void) {
        self.product = product
        self.onSave = onSave
        _name = State(initialValue: product.name)
        _category = State(initialValue: product.category)
        _productState = State(initialValue: product.state)
        _daysRemaining = State(initialValue: product.daysRemaining ?? product.averageUsageDays)
        _unopenedCount = State(initialValue: product.unopenedCount)
        _minimumStockCount = State(initialValue: product.minimumStockCount)
        _purchaseUnit = State(initialValue: product.normalizedPurchaseUnit)
        _usageScope = State(initialValue: product.usageScope)
        _averageUsageDays = State(initialValue: product.averageUsageDays)
        _importance = State(initialValue: product.importance)
        _hasExpirationDate = State(initialValue: product.expirationDate != nil)
        _expirationDate = State(initialValue: product.expirationDate ?? Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date())
        _purchaseURLString = State(initialValue: product.purchaseURLString)
        _preferredStore = State(initialValue: product.normalizedPreferredStore)
        _barcode = State(initialValue: product.barcode)
        _memo = State(initialValue: product.memo)
        _storageLocation = State(initialValue: product.storageLocation)
        _tags = State(initialValue: product.tags)
        _photoData = State(initialValue: product.photoData)
        _productNotificationsEnabled = State(initialValue: product.notificationsEnabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本情報") {
                    TextField("商品名", text: $name)
                    Picker("カテゴリ", selection: $category) {
                        ForEach(ProductCategory.allCases) { category in
                            Label(category.rawValue, systemImage: category.symbol)
                                .tag(category)
                        }
                    }
                }

                ProductPhotoPickerSection(photoData: $photoData)

                Section("状態") {
                    Picker("状態", selection: $productState) {
                        ForEach(ProductState.allCases) { state in
                            Text(state.rawValue).tag(state)
                        }
                    }

                    if productState == .inUse {
                        Stepper("あと約\(daysRemaining)日", value: $daysRemaining, in: 1...365)
                    }

                    Stepper("未開封 \(unopenedCount)\(normalizedPurchaseUnit)", value: $unopenedCount, in: 0...99)
                    Stepper("最低ストック \(minimumStockCount)\(normalizedPurchaseUnit)", value: $minimumStockCount, in: 0...20)
                    TextField("購入単位", text: $purchaseUnit)
                    Picker("利用対象", selection: $usageScope) {
                        ForEach(UsageScope.allCases) { scope in
                            Label(scope.rawValue, systemImage: scope.symbol)
                                .tag(scope)
                        }
                    }
                }

                Section("予測") {
                    Stepper("平均使用期間 約\(averageUsageDays)日", value: $averageUsageDays, in: 1...365)
                    Picker("切らすと困りますか？", selection: $importance) {
                        ForEach(Importance.allCases) { importance in
                            Text(importance.rawValue).tag(importance)
                        }
                    }
                }

                Section("期限") {
                    Toggle("賞味期限・使用期限を設定", isOn: $hasExpirationDate)

                    if hasExpirationDate {
                        DatePicker("期限日", selection: $expirationDate, displayedComponents: .date)
                            .environment(\.locale, Locale(identifier: "ja_JP"))
                    }
                }

                Section("通知") {
                    Toggle("この商品の通知", isOn: $productNotificationsEnabled)
                    Text("オフにすると、全体の通知設定がオンでもこの商品だけ通知しません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("購入") {
                    TextField("優先店舗", text: $preferredStore)
                    TextField("バーコード", text: $barcode)
                        .keyboardType(.numberPad)
                    TextField("いつもの購入先URL", text: $purchaseURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("未設定の場合は、設定した購入先で商品名を検索します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("メモ") {
                    TextField("サイズ、色、置き場所など", text: $memo, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("整理") {
                    TextField("置き場所", text: $storageLocation)
                    TextField("タグ", text: $tags)
                    Button {
                        tags = TagSuggestionService.mergedTagsText(
                            existing: tags,
                            suggested: TagSuggestionService.tagsText(for: name, category: category)
                        )
                    } label: {
                        Label("タグ候補を反映", systemImage: "tag.fill")
                    }
                }
            }
            .navigationTitle("商品を編集")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        var editedProduct = product
        editedProduct.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        editedProduct.category = category
        editedProduct.state = productState
        editedProduct.daysRemaining = productState == .inUse ? daysRemaining : nil
        editedProduct.unopenedCount = unopenedCount
        editedProduct.minimumStockCount = minimumStockCount
        editedProduct.purchaseUnit = purchaseUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "個" : purchaseUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        editedProduct.usageScope = usageScope
        editedProduct.averageUsageDays = averageUsageDays
        editedProduct.importance = importance
        editedProduct.openedDate = productState == .inUse ? (product.openedDate ?? Date()) : nil
        editedProduct.expirationDate = hasExpirationDate ? expirationDate : nil
        editedProduct.preferredStore = preferredStore.trimmingCharacters(in: .whitespacesAndNewlines)
        editedProduct.barcode = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        editedProduct.purchaseURLString = PurchaseURLFormatter.normalizedURLString(from: purchaseURLString)
        editedProduct.memo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        editedProduct.storageLocation = storageLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        editedProduct.tags = tags.trimmingCharacters(in: .whitespacesAndNewlines)
        editedProduct.photoData = photoData
        editedProduct.notificationsEnabled = productNotificationsEnabled
        onSave(editedProduct)
        dismiss()
    }

    private var normalizedPurchaseUnit: String {
        let trimmed = purchaseUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "個" : trimmed
    }
}

private struct AddProductView: View {
    let householdProfile: HouseholdProfile
    let barcodeLookupProxyURLString: String
    let onRequestNotifications: () async -> Void
    let availableProductSlots: Int?
    let onLimitReached: () -> Void
    let onAdd: (StockProduct) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var step = 1
    @State private var name = ""
    @State private var category = ProductCategory.laundry
    @State private var productState = ProductState.inUse
    @State private var unopenedCount = 1
    @State private var minimumStockCount = 0
    @State private var purchaseUnit = "個"
    @State private var usageScope = UsageScope.household
    @State private var startTiming = StartTiming.today
    @State private var selectedStartDate = Date()
    @State private var estimate = DurationEstimate.oneMonth
    @State private var customEstimateDays = 30
    @State private var isEstimateHouseholdAdjusted = false
    @State private var importance = Importance.medium
    @State private var preferredStore = ""
    @State private var barcode = ""
    @State private var memo = ""
    @State private var storageLocation = ""
    @State private var tags = ""
    @State private var photoData: Data?
    @State private var barcodeLookupMessage: String?
    @State private var isLookingUpBarcode = false
    @State private var isShowingNotificationPrompt = false
    @State private var didComplete = false
    @State private var suggestion: ProductSuggestion?
    @State private var isSuggesting = false
    @State private var isShowingNaturalLanguageInput = false
    @State private var addedInSession = 0
    @State private var isShowingReceiptScanner = false
    @State private var isShowingBarcodeScanner = false
    @State private var lastRegisteredDaysRemaining: Int?

    var body: some View {
        NavigationStack {
            Group {
                if didComplete {
                    CompletionView(name: name, predictedDays: lastRegisteredDaysRemaining) {
                        dismiss()
                    } onAddAnother: {
                        if canAddAnother {
                            resetForm()
                        } else {
                            dismiss()
                            onLimitReached()
                        }
                    }
                } else {
                    Form {
                        Section {
                            AddStepProgressView(step: step)
                            if step > 1 {
                                Button {
                                    withAnimation(.snappy) {
                                        step -= 1
                                    }
                                } label: {
                                    Label("前の入力に戻る", systemImage: "chevron.left")
                                }
                            }
                        }
                        .listRowBackground(Color.clear)

                        switch step {
                        case 1:
                            StepOneView(
                                name: $name,
                                category: $category,
                                photoData: $photoData,
                                barcodeLookupMessage: barcodeLookupMessage,
                                isLookingUpBarcode: isLookingUpBarcode,
                                suggestion: suggestion,
                                isSuggesting: isSuggesting,
                                onSuggest: suggestDefaults,
                                onScanReceipt: { isShowingReceiptScanner = true },
                                onScanBarcode: { isShowingBarcodeScanner = true },
                                onNaturalLanguageInput: { isShowingNaturalLanguageInput = true },
                                onPhotoLoaded: suggestFromPhoto,
                                onApplySuggestion: applySuggestion
                            )
                        case 2:
                            StepTwoView(productState: $productState, unopenedCount: $unopenedCount, startTiming: $startTiming, selectedStartDate: $selectedStartDate)
                        default:
                            StepThreeView(
                                estimate: $estimate,
                                customEstimateDays: $customEstimateDays,
                                importance: $importance,
                                memo: $memo,
                                storageLocation: $storageLocation,
                                tags: $tags,
                                photoData: $photoData,
                                minimumStockCount: $minimumStockCount,
                                purchaseUnit: $purchaseUnit,
                                usageScope: $usageScope,
                                preferredStore: $preferredStore,
                                barcode: $barcode,
                                category: category,
                                householdProfile: householdProfile
                            )
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(AppTheme.pageBackground)
                }
            }
            .navigationTitle(didComplete ? "登録完了" : "商品を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !didComplete {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(step == 3 ? "登録する" : "次へ") {
                            advance()
                        }
                        .disabled(step == 1 && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .confirmationDialog("買い時や期限前にお知らせしますか？", isPresented: $isShowingNotificationPrompt, titleVisibility: .visible) {
                Button("通知をオンにする") {
                    Task {
                        await onRequestNotifications()
                        completeRegistration()
                    }
                }
                Button("あとで") {
                    completeRegistration()
                }
            } message: {
                Text("補充や期限確認が必要なタイミングだけ通知します。")
            }
            .sheet(isPresented: $isShowingReceiptScanner) {
                ReceiptScannerView(selectionLimit: remainingReceiptSlots) { candidates in
                    registerReceiptCandidates(candidates)
                }
            }
            .sheet(isPresented: $isShowingNaturalLanguageInput) {
                NaturalLanguageProductInputSheet(householdProfile: householdProfile) { draft in
                    applyNaturalLanguageDraft(draft)
                    isShowingNaturalLanguageInput = false
                }
            }
            .sheet(isPresented: $isShowingBarcodeScanner) {
                BarcodeScannerSheet { code in
                    applyBarcode(code)
                    isShowingBarcodeScanner = false
                }
            }
        }
    }

    private func advance() {
        if step < 3 {
            withAnimation(.snappy) {
                step += 1
            }
        } else {
            isShowingNotificationPrompt = true
        }
    }

    private func completeRegistration() {
        let baseUsageDays = estimate.resolvedDays(customDays: customEstimateDays)
        let averageUsageDays = isEstimateHouseholdAdjusted
            ? min(max(baseUsageDays, 1), 365)
            : HouseholdUsageAdjustmentService.adjustedDays(
                baseDays: baseUsageDays,
                category: category,
                profile: householdProfile.scoped(to: usageScope)
            )
        let openedDate = productState == .inUse ? resolvedOpenedDate : nil
        let daysRemaining = openedDate.map {
            UsagePredictionService.initialDaysRemaining(totalDays: averageUsageDays, openedAt: $0)
        }
        let product = StockProduct(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            state: productState,
            daysRemaining: daysRemaining,
            unopenedCount: productState == .unopened ? unopenedCount : 0,
            accuracy: estimate == .unknown ? "低" : "中",
            importance: importance,
            openedDate: openedDate,
            averageUsageDays: averageUsageDays,
            usageHistoryCount: 0,
            minimumStockCount: minimumStockCount,
            purchaseUnit: normalizedPurchaseUnit,
            usageScope: usageScope,
            preferredStore: preferredStore.trimmingCharacters(in: .whitespacesAndNewlines),
            barcode: barcode.trimmingCharacters(in: .whitespacesAndNewlines),
            memo: memo.trimmingCharacters(in: .whitespacesAndNewlines),
            storageLocation: storageLocation.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: tags.trimmingCharacters(in: .whitespacesAndNewlines),
            photoData: photoData
        )

        lastRegisteredDaysRemaining = daysRemaining
        onAdd(product)
        addedInSession += 1
        HapticFeedback.success()
        withAnimation(.snappy) {
            didComplete = true
        }
    }

    private func resetForm() {
        step = 1
        name = ""
        category = .laundry
        productState = .inUse
        unopenedCount = 1
        minimumStockCount = 0
        purchaseUnit = "個"
        usageScope = .household
        startTiming = .today
        selectedStartDate = Date()
        estimate = .oneMonth
        customEstimateDays = 30
        isEstimateHouseholdAdjusted = false
        importance = .medium
        preferredStore = ""
        barcode = ""
        memo = ""
        storageLocation = ""
        tags = ""
        photoData = nil
        barcodeLookupMessage = nil
        isLookingUpBarcode = false
        suggestion = nil
        isSuggesting = false
        isShowingNaturalLanguageInput = false
        isShowingReceiptScanner = false
        isShowingBarcodeScanner = false
        lastRegisteredDaysRemaining = nil
        didComplete = false
    }

    private var canAddAnother: Bool {
        guard let availableProductSlots else { return true }
        return addedInSession < availableProductSlots
    }

    private var remainingReceiptSlots: Int? {
        guard let availableProductSlots else { return nil }
        return max(availableProductSlots - addedInSession, 0)
    }

    private var resolvedOpenedDate: Date {
        switch startTiming {
        case .today:
            Date()
        case .weekAgo:
            Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        case .chooseDate:
            selectedStartDate
        case .unknown:
            Date()
        }
    }

    private func suggestDefaults() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        isSuggesting = true
        Task {
            let newSuggestion = await ProductSuggestionProvider.suggestion(for: trimmedName, householdProfile: householdProfile)
            await MainActor.run {
                suggestion = newSuggestion
                isSuggesting = false
                applySuggestion(newSuggestion)
            }
        }
    }

    private func suggestFromPhoto(_ data: Data) {
#if canImport(UIKit) && canImport(Vision)
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isSuggesting = true
        Task {
            let candidate = await PhotoProductSuggestionService.candidate(from: data)
            await MainActor.run {
                if let candidate {
                    name = candidate.name
                    category = candidate.category
                    let newSuggestion = ProductSuggestionProvider.fallbackSuggestion(for: candidate.name, householdProfile: householdProfile)
                    suggestion = newSuggestion
                    applySuggestion(newSuggestion)
                }
                isSuggesting = false
            }
        }
#endif
    }

    private func applySuggestion(_ suggestion: ProductSuggestion) {
        category = suggestion.category
        estimate = suggestion.estimate
        customEstimateDays = suggestion.customDurationDays
        importance = suggestion.importance
        isEstimateHouseholdAdjusted = suggestion.isHouseholdAdjusted
        tags = TagSuggestionService.mergedTagsText(
            existing: tags,
            suggested: TagSuggestionService.tagsText(for: name, category: suggestion.category)
        )
    }

    private func applyBarcode(_ code: String) {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else { return }

        barcode = trimmedCode
        barcodeLookupMessage = "商品情報を検索しています。"
        isLookingUpBarcode = true

        Task {
            let result = await BarcodeProductLookupService.lookup(
                barcode: trimmedCode,
                proxyURLString: barcodeLookupProxyURLString
            )
            await MainActor.run {
                isLookingUpBarcode = false
                guard let result else {
                    barcodeLookupMessage = "商品情報は見つかりませんでした。商品名を入力してください。"
                    return
                }

                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    name = result.productName
                    category = ProductCategoryInferenceService.category(for: result.productName)
                    if category == .other {
                        category = .food
                    }
                    let newSuggestion = ProductSuggestionProvider.fallbackSuggestion(for: result.productName, householdProfile: householdProfile)
                    suggestion = newSuggestion
                    applySuggestion(newSuggestion)
                }

                if memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let brand = result.brand {
                    memo = "ブランド: \(brand)"
                }

                barcodeLookupMessage = "\(result.sourceName)から商品候補を取得しました。内容を確認してください。"
            }
        }
    }

    private func applyNaturalLanguageDraft(_ draft: NaturalLanguageProductDraft) {
        name = draft.name
        category = draft.category
        productState = draft.state
        unopenedCount = draft.unopenedCount
        estimate = draft.duration
        customEstimateDays = draft.customDurationDays
        isEstimateHouseholdAdjusted = draft.isHouseholdAdjusted
        importance = draft.importance
        memo = draft.memo
        tags = TagSuggestionService.mergedTagsText(
            existing: tags,
            suggested: TagSuggestionService.tagsText(for: draft.name, category: draft.category)
        )
    }

    private func registerReceiptCandidates(_ candidates: [ReceiptCandidate]) {
        let limitedCandidates = Array(candidates.prefix(remainingReceiptSlots ?? candidates.count))
        guard !limitedCandidates.isEmpty else {
            onLimitReached()
            return
        }

        for candidate in limitedCandidates {
            onAdd(product(from: candidate))
        }

        addedInSession += limitedCandidates.count
        name = limitedCandidates.count == 1 ? limitedCandidates[0].name : "\(limitedCandidates.count)件の商品"
        estimate = .oneMonth
        customEstimateDays = 30
        lastRegisteredDaysRemaining = nil
        HapticFeedback.success()

        withAnimation(.snappy) {
            didComplete = true
        }
    }

    private func product(from candidate: ReceiptCandidate) -> StockProduct {
        let receiptSuggestion = ProductSuggestionProvider.fallbackSuggestion(for: candidate.name)
        return StockProduct(
            name: candidate.name,
            category: candidate.category,
            state: .unopened,
            daysRemaining: nil,
            unopenedCount: 1,
            accuracy: "中",
            importance: receiptSuggestion.importance,
            openedDate: nil,
            averageUsageDays: HouseholdUsageAdjustmentService.adjustedDays(
                baseDays: receiptSuggestion.estimate.predictedDays ?? 30,
                category: candidate.category,
                profile: householdProfile
            ),
            usageHistoryCount: 0,
            minimumStockCount: 1,
            purchaseUnit: "個",
            usageScope: candidate.category == .pet ? .pets : .household,
            tags: TagSuggestionService.tagsText(for: candidate.name, category: candidate.category)
        )
    }

    private var normalizedPurchaseUnit: String {
        let trimmed = purchaseUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "個" : trimmed
    }
}

private struct AddStepProgressView: View {
    let step: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("STEP \(step) / 3")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.primary)
                Spacer()
                Text(progressTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(AppTheme.primary)
                        .frame(width: proxy.size.width * CGFloat(step) / 3)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
    }

    private var progressTitle: String {
        switch step {
        case 1: "商品"
        case 2: "状態"
        default: "予測"
        }
    }
}

private struct ReceiptScannerView: View {
    let selectionLimit: Int?
    let onRegister: ([ReceiptCandidate]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ReceiptCandidate] = []
    @State private var selectedCandidateIDs = Set<ReceiptCandidate.ID>()
    @State private var editingCandidate: ReceiptCandidate?
    @State private var isProcessing = false
    @State private var message = "レシートの商品名が写るように撮影してください。"
#if canImport(UIKit)
    @State private var isShowingCamera = false
#endif
#if canImport(PhotosUI)
    @State private var selectedPhotoItem: PhotosPickerItem?
#endif

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("レシート読み取り", systemImage: "doc.text.viewfinder")
                            .font(.headline)
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("読み取り") {
#if canImport(UIKit)
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            isShowingCamera = true
                        } label: {
                            Label("カメラで撮影", systemImage: "camera.fill")
                        }
                    }
#endif

#if canImport(PhotosUI)
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("写真から選ぶ", systemImage: "photo.fill")
                    }
#endif
                }

                Section("候補") {
                    if isProcessing {
                        HStack {
                            ProgressView()
                            Text("読み取り中")
                                .foregroundStyle(.secondary)
                        }
                    } else if candidates.isEmpty {
                        ContentUnavailableView("候補はまだありません", systemImage: "text.magnifyingglass", description: Text("撮影または写真選択後に候補が表示されます。"))
                    } else {
                        ForEach(candidates) { candidate in
                            Button {
                                toggleSelection(candidate)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(candidate.name)
                                            .font(.body.weight(.medium))
                                        Label(candidate.category.rawValue, systemImage: candidate.category.symbol)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: selectedCandidateIDs.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedCandidateIDs.contains(candidate.id) ? AppTheme.primary : .secondary)
                                }
                            }
                            .disabled(!selectedCandidateIDs.contains(candidate.id) && !canSelectMore)
                            .swipeActions(edge: .leading) {
                                Button("編集") {
                                    editingCandidate = candidate
                                }
                                .tint(AppTheme.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("レシートから追加")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("登録") {
                        registerSelectedCandidates()
                    }
                    .disabled(selectedCandidates.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(item: $editingCandidate) { candidate in
                ReceiptCandidateEditSheet(candidate: candidate) { editedName, category in
                    update(candidate, name: editedName, category: category)
                }
            }
#if canImport(UIKit)
            .sheet(isPresented: $isShowingCamera) {
                CameraImagePicker { image in
                    Task {
                        await scan(image)
                    }
                }
            }
#endif
#if canImport(PhotosUI)
            .onChange(of: selectedPhotoItem) { _, item in
                guard let item else { return }
                Task {
                    await loadPhoto(item)
                }
            }
#endif
        }
    }

    private func update(_ candidate: ReceiptCandidate, name: String, category: ProductCategory) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = candidates.firstIndex(where: { $0.id == candidate.id }) else {
            return
        }

        candidates[index] = ReceiptCandidate(id: candidate.id, name: trimmedName, category: category)
    }

    private var selectedCandidates: [ReceiptCandidate] {
        candidates.filter { selectedCandidateIDs.contains($0.id) }
    }

    private var canSelectMore: Bool {
        guard let selectionLimit else { return true }
        return selectedCandidateIDs.count < selectionLimit
    }

    private func toggleSelection(_ candidate: ReceiptCandidate) {
        if selectedCandidateIDs.contains(candidate.id) {
            selectedCandidateIDs.remove(candidate.id)
        } else if canSelectMore {
            selectedCandidateIDs.insert(candidate.id)
        }
    }

    private func registerSelectedCandidates() {
        let selected = selectedCandidates
        guard !selected.isEmpty else { return }
        onRegister(selected)
        dismiss()
    }

#if canImport(UIKit)
    private func scan(_ image: UIImage) async {
        isProcessing = true
        message = "レシートを解析しています。"
#if canImport(Vision)
        let newCandidates = await ReceiptCandidateRefinementService.refinedCandidates(from: ReceiptOCRService.candidates(from: image))
#else
        let newCandidates: [ReceiptCandidate] = []
#endif
        await MainActor.run {
            candidates = newCandidates
            selectedCandidateIDs = []
            message = newCandidates.isEmpty ? "商品候補を見つけられませんでした。明るい場所で撮り直してください。" : "\(newCandidates.count)件の候補を見つけました。"
            isProcessing = false
        }
    }
#endif

#if canImport(PhotosUI) && canImport(UIKit)
    private func loadPhoto(_ item: PhotosPickerItem) async {
        isProcessing = true
        message = "写真を読み込んでいます。"

        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            await MainActor.run {
                message = "写真を読み込めませんでした。"
                isProcessing = false
            }
            return
        }

        await scan(image)
    }
#endif
}

private struct ReceiptCandidateEditSheet: View {
    let candidate: ReceiptCandidate
    let onSave: (String, ProductCategory) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var category: ProductCategory

    init(candidate: ReceiptCandidate, onSave: @escaping (String, ProductCategory) -> Void) {
        self.candidate = candidate
        self.onSave = onSave
        _name = State(initialValue: candidate.name)
        _category = State(initialValue: candidate.category)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("商品名", text: $name)
                } footer: {
                    Text("レシート読み取りの誤字を登録前に修正できます。")
                }

                Section("カテゴリ") {
                    Picker("カテゴリ", selection: $category) {
                        ForEach(ProductCategory.allCases) { category in
                            Label(category.rawValue, systemImage: category.symbol)
                                .tag(category)
                        }
                    }
                }
            }
            .navigationTitle("候補を編集")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(name, category)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

#if canImport(UIKit) && canImport(Vision)
private enum BarcodeOCRService {
    static func barcode(from image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }

        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
            return request.results?
                .compactMap(\.payloadStringValue)
                .first
        } catch {
            return nil
        }
    }
}
#endif

struct BarcodeProductLookupResult: Equatable {
    let productName: String
    let brand: String?
    let sourceName: String
}

nonisolated enum BarcodeProductLookupService {
    static func lookup(barcode: String, proxyURLString: String = "") async -> BarcodeProductLookupResult? {
        let digits = barcode.filter(\.isNumber)
        guard digits.count >= 8 else { return nil }

        if let proxyResult = await proxyResult(barcode: digits, proxyURLString: proxyURLString) {
            return proxyResult
        }

        return await openFoodFactsResult(barcode: digits)
    }

    private static func proxyResult(barcode: String, proxyURLString: String) async -> BarcodeProductLookupResult? {
        let trimmedProxyURLString = proxyURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProxyURLString.isEmpty,
              var components = URLComponents(string: trimmedProxyURLString) else { return nil }

        components.queryItems = [
            URLQueryItem(name: "barcode", value: barcode)
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            let decoded = try JSONDecoder().decode(BarcodeLookupProxyResponse.self, from: data)
            let name = decoded.productName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard decoded.found, !name.isEmpty else { return nil }

            return BarcodeProductLookupResult(
                productName: name,
                brand: decoded.brand,
                sourceName: decoded.sourceName ?? "バーコード検索"
            )
        } catch {
            return nil
        }
    }

    private static func openFoodFactsResult(barcode digits: String) async -> BarcodeProductLookupResult? {
        guard var components = URLComponents(string: "https://world.openfoodfacts.org/api/v2/product/\(digits).json") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "fields", value: "product_name,product_name_ja,brands")
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("atodore/1.0 (iOS; product lookup)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            let decoded = try JSONDecoder().decode(OpenFoodFactsProductResponse.self, from: data)
            guard decoded.status == 1 else { return nil }

            let productName = [
                decoded.product.productNameJA,
                decoded.product.productName
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

            guard let productName else { return nil }

            let brand = decoded.product.brands?
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }

            return BarcodeProductLookupResult(
                productName: productName,
                brand: brand,
                sourceName: "Open Food Facts"
            )
        } catch {
            return nil
        }
    }
}

nonisolated private struct BarcodeLookupProxyResponse: Decodable {
    let found: Bool
    let productName: String
    let brand: String?
    let sourceName: String?
}

nonisolated private struct OpenFoodFactsProductResponse: Decodable {
    let status: Int
    let product: OpenFoodFactsProduct
}

nonisolated private struct OpenFoodFactsProduct: Decodable {
    let productName: String?
    let productNameJA: String?
    let brands: String?

    enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case productNameJA = "product_name_ja"
        case brands
    }
}

private struct BarcodeScannerSheet: View {
    let onDetected: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var manualCode = ""
    @State private var message = "バーコード番号を商品に保存します。商品名は自動確定しません。"
    @State private var isProcessing = false
#if canImport(PhotosUI)
    @State private var selectedPhotoItem: PhotosPickerItem?
#endif
#if canImport(UIKit)
    @State private var isShowingCamera = false
#endif

    var body: some View {
        NavigationStack {
            Form {
                Section("読み取り") {
#if canImport(UIKit)
                    Button {
                        isShowingCamera = true
                    } label: {
                        Label("カメラで読み取る", systemImage: "camera.viewfinder")
                    }
#endif
#if canImport(PhotosUI)
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("写真から読み取る", systemImage: "photo.on.rectangle")
                    }
#endif
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("手入力") {
                    TextField("バーコード番号", text: $manualCode)
                        .keyboardType(.numberPad)
                    Text("商品名は登録画面で確認してから入力してください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if isProcessing {
                    Section {
                        HStack {
                            ProgressView()
                            Text("解析中")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("バーコード")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("反映") {
                        onDetected(manualCode)
                        dismiss()
                    }
                    .disabled(manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
#if canImport(UIKit)
            .sheet(isPresented: $isShowingCamera) {
                CameraImagePicker { image in
                    Task {
                        await scan(image)
                    }
                }
            }
#endif
#if canImport(PhotosUI)
            .onChange(of: selectedPhotoItem) { _, item in
                guard let item else { return }
                Task {
                    await loadPhoto(item)
                }
            }
#endif
        }
    }

#if canImport(UIKit) && canImport(Vision)
    private func scan(_ image: UIImage) async {
        isProcessing = true
        message = "バーコードを解析しています。"
        let code = await BarcodeOCRService.barcode(from: image)
        await MainActor.run {
            if let code {
                manualCode = code
                message = "バーコードを読み取りました。"
            } else {
                message = "バーコードを見つけられませんでした。"
            }
            isProcessing = false
        }
    }
#endif

#if canImport(PhotosUI) && canImport(UIKit)
    private func loadPhoto(_ item: PhotosPickerItem) async {
        isProcessing = true
        message = "写真を読み込んでいます。"
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            await MainActor.run {
                message = "写真を読み込めませんでした。"
                isProcessing = false
            }
            return
        }
        await scan(image)
    }
#endif
}

private struct NaturalLanguageProductInputSheet: View {
    let householdProfile: HouseholdProfile
    let onApply: (NaturalLanguageProductDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isParsing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例: 洗濯洗剤を2個買った。詰め替え用で1ヶ月持つ", text: $text, axis: .vertical)
                        .lineLimit(4...8)
                } footer: {
                    Text("商品名、数量、期間、メモを文章から読み取ります。期間が曖昧な場合は世帯構成も考慮します。")
                }

                if isParsing {
                    Section {
                        HStack {
                            ProgressView()
                            Text("読み取り中")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("文章から入力")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("反映") {
                        parse()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isParsing)
                }
            }
        }
    }

    private func parse() {
        isParsing = true
        errorMessage = nil

        Task {
            let draft = await NaturalLanguageProductParser.draft(from: text, householdProfile: householdProfile)
            await MainActor.run {
                isParsing = false
                if let draft {
                    onApply(draft)
                    dismiss()
                } else {
                    errorMessage = "読み取れる商品情報がありませんでした。"
                }
            }
        }
    }
}

#if canImport(UIKit)
private struct CameraImagePicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        let dismiss: DismissAction

        init(onImage: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onImage = onImage
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
#endif

private struct StepOneView: View {
    @Binding var name: String
    @Binding var category: ProductCategory
    @Binding var photoData: Data?
    let barcodeLookupMessage: String?
    let isLookingUpBarcode: Bool
    let suggestion: ProductSuggestion?
    let isSuggesting: Bool
    let onSuggest: () -> Void
    let onScanReceipt: () -> Void
    let onScanBarcode: () -> Void
    let onNaturalLanguageInput: () -> Void
    let onPhotoLoaded: (Data) -> Void
    let onApplySuggestion: (ProductSuggestion) -> Void

    var body: some View {
        Section("何を登録しますか？") {
            TextField("商品名", text: $name)

            Button(action: onNaturalLanguageInput) {
                Label("文章から入力", systemImage: "text.quote")
            }

            Button(action: onScanReceipt) {
                Label("レシートから読み取り", systemImage: "doc.text.viewfinder")
            }

            Button(action: onScanBarcode) {
                Label("バーコードを読み取り", systemImage: "barcode.viewfinder")
            }

            if isLookingUpBarcode {
                HStack {
                    ProgressView()
                    Text("商品情報を検索中")
                        .foregroundStyle(.secondary)
                }
            } else if let barcodeLookupMessage {
                Text(barcodeLookupMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                onSuggest()
            } label: {
                if isSuggesting {
                    Label("提案を作成中", systemImage: "sparkles")
                } else {
                    Label("入力を提案", systemImage: "sparkles")
                }
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSuggesting)

            if let suggestion {
                SuggestionCard(suggestion: suggestion) {
                    onApplySuggestion(suggestion)
                }
            }

            Picker("カテゴリ", selection: $category) {
                ForEach(ProductCategory.allCases) { category in
                    Label(category.rawValue, systemImage: category.symbol)
                        .tag(category)
                }
            }
        }

        ProductPhotoPickerSection(photoData: $photoData, onPhotoLoaded: onPhotoLoaded)
    }
}

private struct SuggestionCard: View {
    let suggestion: ProductSuggestion
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(suggestion.source.label, systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primary)
                Spacer()
                Button("使う", action: onApply)
                    .buttonStyle(.borderless)
                    .font(.subheadline.weight(.semibold))
            }

            Text("\(suggestion.category.rawValue)・\(suggestion.estimate.rawValue)・\(suggestion.importance.rawValue)")
                .font(.headline)

            Text(suggestion.reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private struct StepTwoView: View {
    @Binding var productState: ProductState
    @Binding var unopenedCount: Int
    @Binding var startTiming: StartTiming
    @Binding var selectedStartDate: Date

    var body: some View {
        Section("今どんな状態？") {
            Picker("今使っていますか？", selection: $productState) {
                ForEach(ProductState.allCases) { state in
                    Text(state.rawValue).tag(state)
                }
            }
            .pickerStyle(.inline)
        }

        if productState == .inUse {
            Section("いつ頃から使っていますか？") {
                Picker("開始時期", selection: $startTiming) {
                    ForEach(StartTiming.allCases) { timing in
                        Text(timing.rawValue).tag(timing)
                    }
                }
                .pickerStyle(.inline)

                if startTiming == .chooseDate {
                    DatePicker("開封日", selection: $selectedStartDate, in: ...Date(), displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                }
            }
        } else {
            Section("ストック数") {
                Stepper("未開封 \(unopenedCount)個", value: $unopenedCount, in: 1...99)
            }
        }
    }
}

private struct StepThreeView: View {
    @Binding var estimate: DurationEstimate
    @Binding var customEstimateDays: Int
    @Binding var importance: Importance
    @Binding var memo: String
    @Binding var storageLocation: String
    @Binding var tags: String
    @Binding var photoData: Data?
    @Binding var minimumStockCount: Int
    @Binding var purchaseUnit: String
    @Binding var usageScope: UsageScope
    @Binding var preferredStore: String
    @Binding var barcode: String
    let category: ProductCategory
    let householdProfile: HouseholdProfile

    private var baseDays: Int {
        estimate.resolvedDays(customDays: customEstimateDays)
    }

    var body: some View {
        Section("どのくらい持ちそう？") {
            Picker("なくなりそうな時期", selection: $estimate) {
                ForEach(DurationEstimate.allCases) { estimate in
                    Text(estimate.rawValue).tag(estimate)
                }
            }
            .pickerStyle(.inline)

            if estimate == .custom {
                Stepper("約\(customEstimateDays)日", value: $customEstimateDays, in: 1...365)
            }

            LabeledContent("世帯補正", value: HouseholdUsageAdjustmentService.description(
                baseDays: baseDays,
                category: category,
                profile: householdProfile
            ))
        }

        Section("切らすと困りますか？") {
            Picker("重要度", selection: $importance) {
                ForEach(Importance.allCases) { importance in
                    Text(importance.rawValue).tag(importance)
                }
            }
            .pickerStyle(.inline)
        }

        Section("ストック基準") {
            Stepper("最低ストック \(minimumStockCount)\(normalizedPurchaseUnit)", value: $minimumStockCount, in: 0...20)
            TextField("購入単位", text: $purchaseUnit)
            Picker("利用対象", selection: $usageScope) {
                ForEach(UsageScope.allCases) { scope in
                    Label(scope.rawValue, systemImage: scope.symbol)
                        .tag(scope)
                }
            }
            Text("0個なら通常の残り日数だけで買い物候補にします。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        ProductPhotoPickerSection(photoData: $photoData)

        Section("メモ") {
            TextField("サイズ、置き場所、買う時の注意など", text: $memo, axis: .vertical)
                .lineLimit(2...5)
        }

        Section("整理") {
            TextField("優先店舗", text: $preferredStore)
            TextField("バーコード", text: $barcode)
                .keyboardType(.numberPad)
            TextField("置き場所", text: $storageLocation)
            TextField("タグ", text: $tags)
            Button {
                let suggestedTags = TagSuggestionService.tagsText(for: "", category: category)
                if tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tags = suggestedTags
                } else {
                    tags = TagSuggestionService.mergedTagsText(existing: tags, suggested: suggestedTags)
                }
            } label: {
                Label("タグ候補を反映", systemImage: "tag.fill")
            }
        }
    }

    private var normalizedPurchaseUnit: String {
        let trimmed = purchaseUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "個" : trimmed
    }
}

private struct CompletionView: View {
    let name: String
    let predictedDays: Int?
    let onHome: () -> Void
    let onAddAnother: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("登録しました")
                .font(.title.weight(.bold))
            Text(name)
                .font(.title3.weight(.semibold))
            Text(completionMessage)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("ホームへ", action: onHome)
                .buttonStyle(PremiumActionButtonStyle())
            Button("もう1つ登録", action: onAddAnother)
                .buttonStyle(PremiumSecondaryButtonStyle())
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.pageBackground)
    }

    private var completionMessage: String {
        if let predictedDays {
            return "あと約\(predictedDays)日と予測しています。\n使っていくうちに予測が育っていきます。"
        }

        return "未開封ストックとして登録しました。\n使い始めたら予測を開始できます。"
    }
}

private struct PurchaseSheet: View {
    let productName: String
    let purchaseUnit: String
    let purchase: PurchaseHistoryEntry?
    let averagePrice: Int?
    let onSave: (Int, Int?, String, Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var quantity = 1
    @State private var price = ""
    @State private var store = ""
    @State private var purchasedAt = Date()

    init(product: StockProduct, initialQuantity: Int = 1, defaults: PurchaseDefaults = .empty, onSave: @escaping (Int, Int?, String, Date) -> Void) {
        self.productName = product.name
        self.purchaseUnit = product.normalizedPurchaseUnit
        self.purchase = nil
        self.averagePrice = defaults.averagePrice
        self.onSave = onSave
        _quantity = State(initialValue: min(max(initialQuantity, 1), 99))
        _price = State(initialValue: defaults.price.map(String.init) ?? "")
        _store = State(initialValue: defaults.store)
    }

    init(productName: String, purchaseUnit: String = "個", purchase: PurchaseHistoryEntry, onSave: @escaping (Int, Int?, String, Date) -> Void) {
        self.productName = productName
        self.purchaseUnit = purchaseUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "個" : purchaseUnit
        self.purchase = purchase
        self.averagePrice = nil
        self.onSave = onSave
        _quantity = State(initialValue: purchase.quantity)
        _price = State(initialValue: purchase.price.map(String.init) ?? "")
        _store = State(initialValue: purchase.store)
        _purchasedAt = State(initialValue: purchase.purchasedAt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("商品", value: productName)
                }
                Section {
                    Stepper("数量 \(quantity)\(purchaseUnit)", value: $quantity, in: 1...99)
                    TextField("合計金額 任意", text: $price)
                        .keyboardType(.numberPad)
                    if purchase == nil, let priceComparison {
                        Label(priceComparison.message, systemImage: priceComparisonSymbol(for: priceComparison.direction))
                            .font(.footnote)
                            .foregroundStyle(priceComparisonColor(for: priceComparison.direction))
                    }
                    TextField("店舗 任意", text: $store)
                    DatePicker("購入日", selection: $purchasedAt, in: ...Date(), displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                    if purchase == nil && (!price.isEmpty || !store.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        Text("前回の購入履歴をもとに初期入力しています。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(purchase == nil ? "買いました" : "購入履歴を編集")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(quantity, Int(price), store, purchasedAt)
                        dismiss()
                    }
                }
            }
        }
    }

    private var priceComparison: PriceComparison? {
        PriceComparisonService.comparison(currentPrice: Int(price), averagePrice: averagePrice)
    }

    private func priceComparisonSymbol(for direction: PriceComparison.Direction) -> String {
        switch direction {
        case .higher:
            return "exclamationmark.triangle.fill"
        case .lower:
            return "tag.fill"
        case .usual:
            return "checkmark.circle.fill"
        }
    }

    private func priceComparisonColor(for direction: PriceComparison.Direction) -> Color {
        switch direction {
        case .higher:
            return .orange
        case .lower:
            return .green
        case .usual:
            return .secondary
        }
    }
}

private struct PurchaseURLSettingsSheet: View {
    let product: StockProduct
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var urlString: String

    init(product: StockProduct, onSave: @escaping (String) -> Void) {
        self.product = product
        self.onSave = onSave
        _urlString = State(initialValue: product.purchaseURLString)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/item", text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(product.name)
                } footer: {
                    Text("URLを空にすると、購入ページを開く時に既定の購入先で検索します。")
                }
            }
            .navigationTitle("購入先")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(urlString)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SettingsView: View {
    let isProUser: Bool
    let registeredCount: Int
    let freeLimit: Int
    let products: [StockProduct]
    let purchases: [PurchaseHistoryEntry]
    @Binding var notificationsEnabled: Bool
    @Binding var notificationLeadDays: Int
    @Binding var expirationNotificationLeadDays: Int
    @Binding var preferredShoppingWeekday: Int
    @Binding var defaultPurchaseProviderRawValue: String
    @Binding var usesAIForPurchaseSearch: Bool
    @Binding var householdAdults: Int
    @Binding var householdChildren: Int
    @Binding var householdPets: Int
    @Binding var monthlyPurchaseBudget: Int
    @Binding var qualityCheckOnLaunch: Bool
    let onRequestNotifications: () async -> Void
    let onRescheduleNotifications: () -> Void
    let onSendTestNotification: () async -> Void
    let onShowPaywall: () -> Void
    let onRestorePurchase: () -> Void
    let onShowTemplates: () -> Void
    let onShowOnboarding: () -> Void
    let onRepairData: () -> Void
    let onApplyCategorySuggestions: () -> Void
    let onImportProducts: ([StockProduct], Bool) -> ProductImportSummary

    @Environment(\.openURL) private var openURL
    @State private var notificationStatusText = "確認中"
    @State private var pendingReminderCountText = "確認中"
    @State private var iCloudStatusText = "確認中"
    @State private var selectedDocument: AppDocument?
    @State private var isShowingContact = false
    @State private var isShowingDataImporter = false
    @State private var isShowingImportResult = false
    @State private var importResultMessage = ""
    @State private var pendingImportProducts: [StockProduct] = []
    @State private var isShowingImportPreview = false
    @State private var showsAdvancedSettings = false

    private var notificationPreviews: [NotificationSchedulePreview] {
        NotificationSchedulePreviewService.previews(
            for: products,
            notificationsEnabled: notificationsEnabled,
            leadDays: notificationLeadDays,
            expirationLeadDays: expirationNotificationLeadDays,
            preferredShoppingWeekday: preferredShoppingWeekday
        )
    }

    private var nextNotificationText: String {
        NotificationSchedulePreviewService.nextReminderText(
            for: products,
            notificationsEnabled: notificationsEnabled,
            leadDays: notificationLeadDays,
            expirationLeadDays: expirationNotificationLeadDays,
            preferredShoppingWeekday: preferredShoppingWeekday
        )
    }

    private var spendingSummary: PurchaseSpendingSummary {
        PurchaseSpendingSummaryService.summary(from: purchases, products: products)
    }

    private var budgetProgressText: String {
        guard monthlyPurchaseBudget > 0 else { return "未設定" }
        let percentage = Int((Double(spendingSummary.currentMonthTotal) / Double(monthlyPurchaseBudget) * 100).rounded())
        return "\(percentage)%"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("通知") {
                    Toggle("通知設定", isOn: $notificationsEnabled)
                        .onChange(of: notificationsEnabled) { _, _ in
                            Task {
                                if notificationsEnabled {
                                    await onRequestNotifications()
                                }
                                await refreshNotificationStatus()
                                onRescheduleNotifications()
                                await refreshPendingReminderCount()
                            }
                        }

                    Picker("通知タイミング", selection: $notificationLeadDays) {
                        Text("1日前").tag(1)
                        Text("3日前").tag(3)
                        Text("7日前").tag(7)
                    }
                    .disabled(!notificationsEnabled)
                    .onChange(of: notificationLeadDays) { _, _ in
                        onRescheduleNotifications()
                        Task {
                            await refreshPendingReminderCount()
                        }
                    }

                    Picker("期限通知", selection: $expirationNotificationLeadDays) {
                        Text("3日前").tag(3)
                        Text("7日前").tag(7)
                        Text("14日前").tag(14)
                        Text("30日前").tag(30)
                    }
                    .disabled(!notificationsEnabled)
                    .onChange(of: expirationNotificationLeadDays) { _, _ in
                        onRescheduleNotifications()
                        Task {
                            await refreshPendingReminderCount()
                        }
                    }

                    Picker("買い物曜日", selection: $preferredShoppingWeekday) {
                        Text("指定なし").tag(0)
                        Text("日曜").tag(1)
                        Text("月曜").tag(2)
                        Text("火曜").tag(3)
                        Text("水曜").tag(4)
                        Text("木曜").tag(5)
                        Text("金曜").tag(6)
                        Text("土曜").tag(7)
                    }
                    .disabled(!notificationsEnabled)
                    .onChange(of: preferredShoppingWeekday) { _, _ in
                        onRescheduleNotifications()
                        Task {
                            await refreshPendingReminderCount()
                        }
                    }

                    LabeledContent("通知権限", value: notificationStatusText)
                    LabeledContent("予約済み通知", value: pendingReminderCountText)
                    LabeledContent("通知対象", value: "\(notificationPreviews.count)件")
                    LabeledContent("次の通知目安", value: nextNotificationText)

                    Button {
                        Task {
                            await onSendTestNotification()
                            await refreshNotificationStatus()
                            await refreshPendingReminderCount()
                        }
                    } label: {
                        Label("テスト通知を送る", systemImage: "bell.badge")
                    }

                    Button {
                        onRescheduleNotifications()
                        Task {
                            await refreshPendingReminderCount()
                        }
                    } label: {
                        Label("通知予約を再確認", systemImage: "arrow.clockwise")
                    }
                }

                Section("購入") {
                    Picker("既定の購入先", selection: $defaultPurchaseProviderRawValue) {
                        ForEach(PurchaseProvider.allCases) { provider in
                            Text(provider.label).tag(provider.rawValue)
                        }
                    }

                    Toggle("AI検索ワード提案", isOn: $usesAIForPurchaseSearch)

                    Text("バーコード検索は開発者登録済みのYahoo!ショッピングAPIとOpen Food Factsを利用します。利用者側でAPI登録は不要です。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Stepper("月間予算 \(JapaneseCurrencyFormatter.yen(monthlyPurchaseBudget))", value: $monthlyPurchaseBudget, in: 0...200_000, step: 1_000)
                    LabeledContent("今月の購入額", value: JapaneseCurrencyFormatter.yen(spendingSummary.currentMonthTotal))
                    Text("購入額は各商品の「買いました」から合計金額を入力すると反映されます。金額未入力の購入履歴は集計に含まれません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("予算進捗", value: budgetProgressText)
                    LabeledContent("今月の購入件数", value: "\(spendingSummary.currentMonthCount)件")
                    LabeledContent("先月比", value: spendingSummary.trendText)
                    if let topStore = spendingSummary.topStore {
                        LabeledContent("よく使う店", value: topStore)
                    }
                    if !spendingSummary.categoryTotals.isEmpty {
                        ForEach(spendingSummary.categoryTotals.prefix(3)) { categoryTotal in
                            LabeledContent(categoryTotal.category.rawValue, value: JapaneseCurrencyFormatter.yen(categoryTotal.total))
                        }
                    }
                }

                Section("世帯と予測") {
                    Stepper("大人 \(householdAdults)人", value: $householdAdults, in: 1...10)
                    Stepper("子ども \(householdChildren)人", value: $householdChildren, in: 0...10)
                    Stepper("ペット \(householdPets)匹", value: $householdPets, in: 0...10)
                    LabeledContent("使用頻度予測", value: HouseholdProfile(
                        adults: householdAdults,
                        children: householdChildren,
                        pets: householdPets
                    ).displayText)
                    Text("新規登録や未開封から開封した時の初期予測に反映します。使用履歴が増えた商品は実績を優先して学習します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("同期") {
                    LabeledContent("iCloud同期", value: iCloudStatusText)
                    Text("同じApple IDでiCloudにサインインしている端末間で、登録商品や履歴を同期します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        Task {
                            await refreshICloudStatus()
                        }
                    } label: {
                        Label("同期状態を確認", systemImage: "icloud")
                    }
                }

                Section("詳細設定") {
                    Toggle("データ・診断・メンテナンスを表示", isOn: $showsAdvancedSettings)
                    Text("普段使いでは必要な時だけ開けばよい項目です。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if showsAdvancedSettings {
                    Section("Widget") {
                        LabeledContent("表示サマリー", value: WidgetSnapshotService.snapshotText(for: products).replacingOccurrences(of: "\n", with: " / "))
                        ShareLink(
                            item: WidgetSnapshotService.snapshotText(for: products),
                            subject: Text("あとどれ？ Widgetサマリー")
                        ) {
                            Label("サマリーを共有", systemImage: "square.and.arrow.up")
                        }
                    }

                    Section("テンプレート") {
                        Button("テンプレートから追加", action: onShowTemplates)
                    }

                    Section("データ") {
                        LabeledContent("登録商品", value: "\(products.count)件")

                        if products.isEmpty {
                            Label("書き出せる商品がありません", systemImage: "tray")
                                .foregroundStyle(.secondary)
                        } else {
                            ShareLink(
                                item: AppDataExportService.exportText(for: products),
                                subject: Text("あとどれ？ 商品データ"),
                                message: Text("登録商品のバックアップデータです。")
                            ) {
                                Label("商品データを書き出す", systemImage: "square.and.arrow.up")
                            }

                            ShareLink(
                                item: AppDataCSVExportService.exportText(for: products),
                                subject: Text("あとどれ？ 商品一覧CSV"),
                                message: Text("表計算アプリで確認しやすい商品一覧です。")
                            ) {
                                Label("CSVを書き出す", systemImage: "tablecells")
                            }
                        }

                        if !purchases.isEmpty {
                            ShareLink(
                                item: AppDataCSVExportService.purchaseHistoryText(for: purchases),
                                subject: Text("あとどれ？ 購入履歴CSV"),
                                message: Text("購入履歴の確認用CSVです。")
                            ) {
                                Label("購入履歴CSVを書き出す", systemImage: "cart")
                            }
                        }

                        Button {
                            isShowingDataImporter = true
                        } label: {
                            Label("商品データを読み込む", systemImage: "square.and.arrow.down")
                        }
                    }

                    Section("診断") {
                        Toggle("起動時に品質チェック", isOn: $qualityCheckOnLaunch)

                        ForEach(AppDiagnosticsService.diagnostics(for: products, purchases: purchases, monthlyBudget: monthlyPurchaseBudget)) { diagnostic in
                            LabeledContent {
                                Text(diagnostic.value)
                                    .foregroundStyle(diagnostic.isAttentionNeeded ? .orange : .secondary)
                            } label: {
                                Label(diagnostic.title, systemImage: diagnostic.isAttentionNeeded ? "exclamationmark.triangle.fill" : "checkmark.circle")
                            }
                        }
                    }

                    Section("メンテナンス") {
                        Button {
                            onRepairData()
                        } label: {
                            Label("データを自動修復", systemImage: "wrench.and.screwdriver")
                        }

                        Button {
                            onApplyCategorySuggestions()
                        } label: {
                            Label("カテゴリ候補を反映", systemImage: "wand.and.sparkles")
                        }
                    }
                }

                Section("あとどれ？ Pro") {
                    LabeledContent("現在のプラン", value: isProUser ? "Pro" : "Free")
                    if !isProUser {
                        LabeledContent("登録数", value: "\(min(registeredCount, freeLimit)) / \(freeLimit)")
                    }
                    Button("Proを見る", action: onShowPaywall)
                    Button("購入を復元", action: onRestorePurchase)
                }

                Section("アプリ") {
                    Button("使い方", action: onShowOnboarding)
                    Button("プライバシーポリシー") {
                        selectedDocument = .privacy
                    }
                    Button("利用規約") {
                        selectedDocument = .terms
                    }
                    Button("お問い合わせ") {
                        isShowingContact = true
                    }
                }

                Section("その他") {
                    LabeledContent("バージョン", value: "1.0")
                }
            }
            .navigationTitle("設定")
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .task {
                await refreshNotificationStatus()
                await refreshPendingReminderCount()
                await refreshICloudStatus()
            }
            .sheet(item: $selectedDocument) { document in
                AppDocumentView(document: document)
            }
            .sheet(isPresented: $isShowingContact) {
                ContactSupportView()
            }
            .sheet(isPresented: $isShowingImportPreview) {
                ImportPreviewSheet(
                    products: pendingImportProducts,
                    existingNames: Set(products.map { $0.name.normalizedProductName }),
                    availableSlots: isProUser ? nil : max(freeLimit - registeredCount, 0)
                ) { mergeDuplicates in
                    let summary = onImportProducts(pendingImportProducts, mergeDuplicates)
                    pendingImportProducts = []
                    importResultMessage = summary.message
                    isShowingImportPreview = false
                    isShowingImportResult = true
                } onCancel: {
                    pendingImportProducts = []
                    isShowingImportPreview = false
                }
            }
            .fileImporter(
                isPresented: $isShowingDataImporter,
                allowedContentTypes: [.json, .plainText]
            ) { result in
                importData(from: result)
            }
            .alert("データ読み込み", isPresented: $isShowingImportResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importResultMessage)
            }
        }
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let text: String
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            text = "許可済み"
        case .denied:
            text = "オフ"
        case .notDetermined:
            text = "未確認"
        case .ephemeral:
            text = "一時許可"
        @unknown default:
            text = "不明"
        }

        await MainActor.run {
            notificationStatusText = text
        }
    }

    private func refreshPendingReminderCount() async {
        let count = await NotificationService.pendingReminderCount()
        await MainActor.run {
            pendingReminderCountText = "\(count)件"
        }
    }

    private func refreshICloudStatus() async {
        let text: String
        do {
            let status = try await CKContainer(identifier: AppCloudKit.containerIdentifier).accountStatus()
            switch status {
            case .available:
                text = "利用可能"
            case .noAccount:
                text = "iCloud未ログイン"
            case .restricted:
                text = "制限中"
            case .couldNotDetermine:
                text = "確認できません"
            case .temporarilyUnavailable:
                text = "一時的に利用不可"
            @unknown default:
                text = "不明"
            }
        } catch {
            text = "確認できません"
        }

        await MainActor.run {
            iCloudStatusText = text
        }
    }

    private func importData(from result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let canAccess = url.startAccessingSecurityScopedResource()
            defer {
                if canAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) else {
                    importResultMessage = "ファイルの文字コードを読み取れませんでした。"
                    isShowingImportResult = true
                    return
                }

                let importedProducts = try AppDataExportService.importProducts(from: text)
                guard !importedProducts.isEmpty else {
                    importResultMessage = "読み込める商品がありませんでした。"
                    isShowingImportResult = true
                    return
                }

                pendingImportProducts = importedProducts
                isShowingImportPreview = true
            } catch {
                importResultMessage = "商品データの読み込みに失敗しました。"
                isShowingImportResult = true
            }
        case .failure:
            importResultMessage = "ファイルを選択できませんでした。"
            isShowingImportResult = true
        }
    }

}

private enum AppDocument: String, Identifiable {
    case privacy
    case terms

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: "プライバシーポリシー"
        case .terms: "利用規約"
        }
    }

    var sections: [(title: String, body: String)] {
        switch self {
        case .privacy:
            [
                ("取得する情報", "商品名、カテゴリ、使用状況、購入履歴、通知設定、写真、メモなど、アプリの機能に必要な情報を保存します。iCloud同期が有効な場合、同じApple IDの端末間で同期されます。"),
                ("AI機能", "Apple Intelligence が利用できる場合、商品登録や検索ワード提案に入力内容を使います。利用できない場合は端末内のルールで提案します。"),
                ("通知", "通知を許可した場合、買い時の目安に合わせてローカル通知を送ります。通知は設定からいつでも変更できます。"),
                ("購入情報", "Pro機能の購入状態はApp Storeのアプリ内課金機能を通じて確認します。開発者がクレジットカード情報を取得することはありません。"),
                ("第三者提供", "本バージョンでは、保存した商品データを外部サービスへ販売または提供しません。購入ページを開く場合は、選択したサイトの規約が適用されます。")
            ]
        case .terms:
            [
                ("利用について", "本アプリは日用品や消耗品の補充タイミングを管理するための補助ツールです。予測日は目安であり、正確な在庫を保証するものではありません。"),
                ("購入リンク", "購入ページや検索結果は外部サイトを開きます。価格、在庫、配送、購入条件は各サイトで確認してください。"),
                ("Pro機能", "Pro機能はApp Storeのアプリ内課金を通じて提供されます。購入状態の確認や復元はApp Storeの仕組みに従って行います。"),
                ("免責", "本アプリの利用により生じた購入漏れ、重複購入、外部サイトでの取引について、開発者は責任を負いません。")
            ]
        }
    }
}

private struct ImportPreviewSheet: View {
    let products: [StockProduct]
    let existingNames: Set<String>
    let availableSlots: Int?
    let onImport: (Bool) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mergeDuplicates = false

    private var plan: ProductImportPlan {
        ProductImportPlanner.plan(
            importedProducts: products,
            existingNames: existingNames,
            availableSlots: availableSlots,
            mergeDuplicates: mergeDuplicates
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section("読み込み内容") {
                    Toggle("重複は既存商品に統合", isOn: $mergeDuplicates)
                    LabeledContent("追加される商品", value: "\(plan.productsToImport.count)件")
                    LabeledContent("スキップ", value: "\(plan.skippedCount)件")
                    if plan.mergedDuplicateCount > 0 {
                        LabeledContent("統合予定", value: "\(plan.mergedDuplicateCount)件")
                    }
                    if plan.limitSkippedCount > 0 {
                        LabeledContent("上限によるスキップ", value: "\(plan.limitSkippedCount)件")
                    }
                }

                if plan.productsToImport.isEmpty {
                    ContentUnavailableView("追加できる商品がありません", systemImage: "square.and.arrow.down", description: Text("登録済みまたは上限により、読み込める商品がありません。"))
                        .listRowBackground(Color.clear)
                } else {
                    Section("追加予定") {
                        ForEach(plan.productsToImport.prefix(20)) { product in
                            HStack {
                                Label(product.name, systemImage: product.category.symbol)
                                Spacer()
                                Text(product.category.rawValue)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if plan.productsToImport.count > 20 {
                            Text("ほか \(plan.productsToImport.count - 20)件")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("読み込みプレビュー")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("読み込む") {
                        onImport(mergeDuplicates)
                        dismiss()
                    }
                    .disabled(plan.productsToImport.isEmpty)
                }
            }
        }
    }
}

private struct AppDocumentView: View {
    let document: AppDocument

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(document.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.headline)
                            Text(section.body)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                        }
                        .premiumSurface()
                    }
                }
                .padding()
            }
            .background(AppTheme.pageBackground)
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

private struct ContactSupportView: View {
    private let emailAddress = "fp.app.contact@gmail.com"
    private let subject = "あとどれ？ お問い合わせ"

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var copiedMessage: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(AppTheme.primary)
                        .frame(width: 58, height: 58)
                        .background(AppTheme.softBlue, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text("お問い合わせ")
                        .font(.largeTitle.weight(.bold))
                    Text("不具合、改善要望、課金に関する確認はこちらから送れます。")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("メールアドレス")
                        .font(.headline)
                    Text(emailAddress)
                        .font(.body.weight(.semibold))
                        .textSelection(.enabled)
                }
                .premiumSurface()

                VStack(spacing: 12) {
                    Button {
                        openMail()
                    } label: {
                        Label("メールを作成", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(PremiumActionButtonStyle())

                    Button {
                        copyEmailAddress()
                    } label: {
                        Label("メールアドレスをコピー", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(PremiumSecondaryButtonStyle())
                }

                if let copiedMessage {
                    Text(copiedMessage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Spacer()
            }
            .padding()
            .background(AppTheme.pageBackground)
            .navigationTitle("お問い合わせ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func openMail() {
        let body = """


        ---
        アプリ: あとどれ？ 1.0
        """
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = emailAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]

        guard let url = components.url else { return }
        openURL(url)
    }

    private func copyEmailAddress() {
#if canImport(UIKit)
        UIPasteboard.general.string = emailAddress
#endif
        withAnimation(.snappy) {
            copiedMessage = "メールアドレスをコピーしました"
        }
    }
}

private struct CategoryIcon: View {
    let category: ProductCategory
    let tint: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: category.symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }
}

private struct ProductPhotoView: View {
    let product: StockProduct
    var size: CGFloat = 40

    var body: some View {
#if canImport(UIKit)
        if let photoData = product.photoData, let image = UIImage(data: photoData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("\(product.name)の写真")
        } else {
            CategoryIcon(category: product.category, tint: product.urgency.tint, size: size)
        }
#else
        CategoryIcon(category: product.category, tint: product.urgency.tint, size: size)
#endif
    }
}

private struct ProductPhotoPickerSection: View {
    @Binding var photoData: Data?
    var onPhotoLoaded: (Data) -> Void = { _ in }
#if canImport(PhotosUI)
    @State private var selectedPhotoItem: PhotosPickerItem?
#endif

    var body: some View {
        Section("写真") {
            HStack(spacing: 12) {
#if canImport(UIKit)
                if let photoData, let image = UIImage(data: photoData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, height: 72)
                        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
#endif

                VStack(alignment: .leading, spacing: 8) {
#if canImport(PhotosUI)
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label(photoData == nil ? "写真を選ぶ" : "写真を変更", systemImage: "photo.on.rectangle")
                    }
#endif
                    if photoData != nil {
                        Button(role: .destructive) {
                            photoData = nil
                        } label: {
                            Label("写真を削除", systemImage: "trash")
                        }
                    }
                }
            }
#if canImport(PhotosUI)
            .onChange(of: selectedPhotoItem) { _, item in
                guard let item else { return }
                Task {
                    await loadPhoto(item)
                }
            }
#endif
        }
    }

#if canImport(PhotosUI)
    private func loadPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
#if canImport(UIKit)
        if let image = UIImage(data: data),
           let jpegData = ProductPhotoDataProcessor.processedData(from: image) {
            await MainActor.run {
                photoData = jpegData
                onPhotoLoaded(jpegData)
            }
        } else {
            await MainActor.run {
                photoData = data
                onPhotoLoaded(data)
            }
        }
#else
        await MainActor.run {
            photoData = data
            onPhotoLoaded(data)
        }
#endif
    }
#endif
}

#if canImport(UIKit)
private enum ProductPhotoDataProcessor {
    static func processedData(from image: UIImage, maxDimension: CGFloat = 900, compressionQuality: CGFloat = 0.72) -> Data? {
        let targetSize = scaledSize(for: image.size, maxDimension: maxDimension)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resizedImage.jpegData(compressionQuality: compressionQuality)
    }

    private static func scaledSize(for size: CGSize, maxDimension: CGFloat) -> CGSize {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension, longestSide > 0 else { return size }
        let scale = maxDimension / longestSide
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
#endif

#if canImport(UIKit) && canImport(Vision)
private enum PhotoProductSuggestionService {
    static func candidate(from data: Data) async -> ReceiptCandidate? {
        guard let image = UIImage(data: data) else { return nil }
        let candidates = await ReceiptCandidateRefinementService.refinedCandidates(from: ReceiptOCRService.candidates(from: image))
        return candidates.first
    }
}
#endif

private struct DetailDateRow: View {
    let title: String
    let date: Date?

    var body: some View {
        DetailInfoRow(title: title, value: date.map(JapaneseDateFormatter.shortDate) ?? "未定")
    }
}

private struct DetailInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

private struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
    }
}

private struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.black.opacity(0.82), in: Capsule())
    }
}

private struct PremiumActionButtonStyle: ButtonStyle {
    var tint: Color = AppTheme.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background(tint.opacity(configuration.isPressed ? 0.82 : 1.0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

private struct PremiumSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(AppTheme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background(AppTheme.elevatedSurface.opacity(configuration.isPressed ? 0.7 : 1.0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.quaternary)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

private extension View {
    func premiumSurface(background: Color = AppTheme.surface, stroke: Color = Color.black.opacity(0.06)) -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(stroke)
            }
            .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

extension String {
    nonisolated var normalizedProductName: String {
        folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Date {
    static func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}

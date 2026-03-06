//
//  SupportStore.swift
//  ScrollSnap
//
//  Manages StoreKit 2 consumable tip purchases and exposes rating intent.
//
//  App Store Connect setup required:
//    Create three Consumable In-App Purchase products with the IDs listed in
//    `tipProductIDs` below, then attach them to your app before submitting.
//    For local sandbox testing add a StoreKit Configuration file to your scheme
//    (Product → Scheme → Edit Scheme → Run → Options → StoreKit Configuration).

import Combine
import StoreKit
import SwiftUI

@MainActor
final class SupportStore: ObservableObject {

    // MARK: - Product IDs
    // Must match exactly what you create in App Store Connect.
    static let tipProductIDs: [String] = [
        "com.scrollsnap.tip.small",   // $0.99  – entry floor
        "com.scrollsnap.tip.medium",  // $2.99  – "Most Popular"
        "com.scrollsnap.tip.large"    // $4.99  – anchor / aspirational
    ]

    // MARK: - Published state

    @Published var products: [Product] = []
    @Published var isPurchasing: Bool = false
    @Published var thankYouShown: Bool = false

    /// Persisted across launches. True once the user completes any tip purchase.
    @AppStorage("hasDonated") var hasDonated: Bool = false
    /// Persisted across launches. True once the user taps the App Store review CTA.
    @AppStorage("hasReviewedSupport") var hasReviewedSupport: Bool = false
    /// Total number of tip purchases completed across all launches.
    @AppStorage("coffeeCount") var coffeeCount: Int = 0

    // MARK: - Private

    private var listenerTask: Task<Void, Never>?

    // MARK: - Init / deinit

    init() {
        listenerTask = Task { await listenForTransactions() }
        Task { await loadProducts() }
    }

    deinit {
        listenerTask?.cancel()
    }

    // MARK: - Load products

    var hasSupporterBadge: Bool {
        hasDonated || hasReviewedSupport
    }

    var isReviewSupporterOnly: Bool {
        hasReviewedSupport && !hasDonated
    }

    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: Self.tipProductIDs)
            // Sort ascending by price so UI always shows small → medium → large.
            products = fetched.sorted { $0.price < $1.price }
        } catch {
            // May fail in development or when products aren't configured yet; ignore.
        }
    }

    // MARK: - Purchase

    /// Initiates a consumable tip purchase.
    /// - Returns: `true` if the purchase completed successfully, `false` otherwise.
    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        guard !isPurchasing else { return false }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                showThankYou()
                return true
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    private func showThankYou() {
        hasDonated = true
        coffeeCount += 1
        thankYouShown = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            thankYouShown = false
        }
    }

    func markReviewedSupport() {
        hasReviewedSupport = true
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified: throw StoreKitError.unknown
        case .verified(let payload): return payload
        }
    }

    /// Listens for background transaction updates (e.g. ask-to-buy approvals).
    private func listenForTransactions() async {
        for await result in Transaction.updates {
            if let transaction = try? checkVerified(result) {
                await transaction.finish()
            }
        }
    }
}

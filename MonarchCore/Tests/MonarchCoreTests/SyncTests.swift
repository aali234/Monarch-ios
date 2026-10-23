import Foundation
import Testing
@testable import MonarchCore

private func remote(_ id: String, pendingID: String? = nil, amount: Decimal = 25, pending: Bool = false) -> PlaidEntry {
    .init(transactionId: id, pendingTransactionId: pendingID, accountId: "remote-account", date: "2026-10-21", amount: amount, name: "Original", merchantName: "Coffee Co", originalDescription: nil, pending: pending, personalFinanceCategory: .init(primary: "FOOD_AND_DRINK", detailed: "FOOD_AND_DRINK_COFFEE"))
}

@Test func pendingToPostedPreservesLocalEditsAndSurvivesPendingRemoval() throws {
    var existing = EntryValue(id: "local", accountID: "bank", date: LedgerDate.parse("2026-10-20")!, amount: -20, merchant: "My coffee shop", categoryID: "work", notes: "Keep me", tags: ["work"], isPending: true, isReviewed: true, sourceID: "pending", lockedFields: ["merchant", "category"])
    existing.isPending = true
    var batch = SyncBatch(nextCursor: "after")
    batch.added = [remote("posted", pendingID: "pending")]
    batch.removed = [.init(transactionId: "pending")]
    let result = try SyncMerger.merge(existing: [existing], batch: batch, accountIDs: ["remote-account": "bank"])
    #expect(result.count == 1)
    #expect(result[0].id == "local")
    #expect(result[0].sourceID == "posted")
    #expect(result[0].amount == -25)
    #expect(result[0].merchant == "My coffee shop")
    #expect(result[0].categoryID == "work")
    #expect(result[0].notes == "Keep me" && result[0].isReviewed && !result[0].isPending)
}

@Test func replayAndModifiedRemovedAreIdempotent() throws {
    var batch = SyncBatch(nextCursor: "one"); batch.added = [remote("tx")]
    let first = try SyncMerger.merge(existing: [], batch: batch, accountIDs: ["remote-account": "bank"])
    let replayed = try SyncMerger.merge(existing: first, batch: batch, accountIDs: ["remote-account": "bank"])
    #expect(replayed == first)
    batch.added = []; batch.modified = [remote("tx", amount: 30)]
    let changed = try SyncMerger.merge(existing: first, batch: batch, accountIDs: ["remote-account": "bank"])
    #expect(changed[0].amount == -30)
    batch.modified = []; batch.removed = [.init(transactionId: "tx")]
    #expect(try SyncMerger.merge(existing: changed, batch: batch, accountIDs: ["remote-account": "bank"]).isEmpty)
}

private actor ScriptedTransport: SyncTransport {
    var steps: [Result<SyncPage, ProxyError>]
    var cursors: [String?] = []
    init(_ steps: [Result<SyncPage, ProxyError>]) { self.steps = steps }
    func sync(accessToken: String, cursor: String?) async throws -> SyncPage {
        cursors.append(cursor)
        return try steps.removeFirst().get()
    }
}

@Test func paginationMutationDiscardsPartialBatchAndRestartsOriginalCursor() async throws {
    let first = SyncPage(added: [remote("discard")], nextCursor: "page2", hasMore: true)
    let final = SyncPage(added: [remote("keep")], nextCursor: "final", hasMore: false)
    let transport = ScriptedTransport([.success(first), .failure(.init(errorCode: "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION")), .success(final)])
    let batch = try await SyncPager.fetch(transport: transport, accessToken: "fake", cursor: "saved")
    #expect(batch.added.map(\.transactionId) == ["keep"])
    #expect(batch.nextCursor == "final")
    #expect(await transport.cursors == ["saved", "page2", "saved"])
}

@Test func ordinaryPaginationCollectsAllPages() async throws {
    let transport = ScriptedTransport([
        .success(.init(added: [remote("one")], nextCursor: "two", hasMore: true)),
        .success(.init(added: [remote("two")], nextCursor: "done", hasMore: false))
    ])
    let batch = try await SyncPager.fetch(transport: transport, accessToken: "fake", cursor: nil)
    #expect(batch.added.count == 2 && batch.nextCursor == "done")
}

@Test func unknownAccountAndUnsafeProxyURLAreRejected() {
    var batch = SyncBatch(nextCursor: "after"); batch.added = [remote("tx")]
    #expect(throws: ProxyError.self) { try SyncMerger.merge(existing: [], batch: batch, accountIDs: [:]) }
    #expect(throws: ProxyError.self) { try ProxyClient.validatedURL("http://example.com") }
    #expect(throws: ProxyError.self) { try ProxyClient.validatedURL("https://user:password@example.com") }
    #expect(throws: Never.self) { try ProxyClient.validatedURL("http://127.0.0.1:8000") }
}

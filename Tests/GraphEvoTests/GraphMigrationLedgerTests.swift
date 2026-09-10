//
//  GraphMigrationLedgerTests.swift
//  GraphTests
//

import XCTest
@testable import GraphEvo

final class TestMigrationKVSStore: GraphMigrationKVSStore {
    let changeNotification = Notification.Name("GraphMigrationKVSStore.changed")
    var notificationObject: AnyObject? { self }
    var acceptsWrites = true
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    func set(_ value: Any?, forKey key: String) { if acceptsWrites { values[key] = value } }
    func synchronize() -> Bool { acceptsWrites }
}

final class GraphMigrationLedgerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var configuration: GraphStoreConfiguration!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        var configuration = GraphStoreConfiguration()
        configuration.name = "MigrationLedgerTests-\(UUID().uuidString)"
        configuration.location = temporaryDirectory
        self.configuration = configuration
    }

    override func tearDownWithError() throws {
        GraphMigrationLedger.setFaultForTesting(nil)
        GraphMigrationLedger.resetKVSStoreForTesting()
        if let temporaryDirectory,
           FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        configuration = nil
    }

    func testStartedThenDonePersistsTerminalState() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let completedAt = startedAt.addingTimeInterval(30)

        _ = try GraphMigrationLedger.markStarted(
            migrationID: "test-migration",
            version: 1,
            configuration: configuration,
            now: startedAt
        )
        let started = GraphMigrationLedger.localRecord(
            migrationID: "test-migration",
            version: 1,
            configuration: configuration
        )
        XCTAssertEqual(started?.state, .started)
        XCTAssertEqual(started?.startedAt, startedAt)

        _ = try GraphMigrationLedger.markDone(
            migrationID: "test-migration",
            version: 1,
            synchronization: .local,
            configuration: configuration,
            now: completedAt
        )
        let done = GraphMigrationLedger.localRecord(
            migrationID: "test-migration",
            version: 1,
            configuration: configuration
        )
        XCTAssertEqual(done?.state, .done)
        XCTAssertEqual(done?.startedAt, startedAt)
        XCTAssertEqual(done?.updatedAt, completedAt)
    }

    func testStartedThenFailedStoresHandledError() throws {
        struct ExpectedError: LocalizedError {
            var errorDescription: String? { "Expected migration failure" }
        }

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let failedAt = startedAt.addingTimeInterval(10)
        _ = try GraphMigrationLedger.markStarted(
            migrationID: "test-migration",
            version: 1,
            configuration: configuration,
            now: startedAt
        )
        _ = try GraphMigrationLedger.markFailed(
            migrationID: "test-migration",
            version: 1,
            error: ExpectedError(),
            configuration: configuration,
            now: failedAt
        )

        let failed = GraphMigrationLedger.localRecord(
            migrationID: "test-migration",
            version: 1,
            configuration: configuration
        )
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertEqual(failed?.startedAt, startedAt)
        XCTAssertEqual(failed?.updatedAt, failedAt)
        XCTAssertEqual(failed?.errorDescription, "Expected migration failure")
    }

    func testResetRecordsNotExecutedWithoutRemovingHistory() throws {
        _ = try GraphMigrationLedger.markStarted(
            migrationID: "test-migration",
            version: 1,
            configuration: configuration
        )

        try GraphMigrationLedger.reset(
            migrationID: "test-migration",
            version: 1,
            synchronization: .local,
            configuration: configuration
        )

        XCTAssertEqual(
            GraphMigrationLedger.localRecord(migrationID: "test-migration", version: 1, configuration: configuration)?.state,
            .notExecuted
        )
    }

    func testSkippedAttemptCanClearStartedWithoutTouchingCloudState() throws {
        _ = try GraphMigrationLedger.markStarted(
            migrationID: "test-migration",
            version: 1,
            configuration: configuration
        )

        try GraphMigrationLedger.clearLocal(
            migrationID: "test-migration",
            version: 1,
            configuration: configuration
        )

        XCTAssertNil(
            GraphMigrationLedger.localRecord(
                migrationID: "test-migration",
                version: 1,
                configuration: configuration
            )
        )
    }

    func testForceIsConsumedOnceAndRetainedInProjection() throws {
        try GraphMigrationLedger.requestForce(migrationID: "forced", version: 1, configuration: configuration, reason: "test")
        let first = try GraphMigrationLedger.consumeForce(migrationID: "forced", version: 1, configuration: configuration)
        XCTAssertNotNil(first)
        XCTAssertNil(try GraphMigrationLedger.consumeForce(migrationID: "forced", version: 1, configuration: configuration))
        XCTAssertEqual(GraphMigrationLedger.snapshot(migrationID: "forced", version: 1, configuration: configuration)?.pendingForceCount, 0)
    }

    func testStoresWithSameMigrationIDHaveIndependentLedgers() throws {
        var other = configuration!
        other.location = temporaryDirectory.appendingPathComponent("other", isDirectory: true)
        _ = try GraphMigrationLedger.markDone(migrationID: "same", version: 1, synchronization: .local, configuration: configuration)
        _ = try GraphMigrationLedger.markStarted(migrationID: "same", version: 1, configuration: other)
        XCTAssertEqual(GraphMigrationLedger.localRecord(migrationID: "same", version: 1, configuration: configuration)?.state, .done)
        XCTAssertEqual(GraphMigrationLedger.localRecord(migrationID: "same", version: 1, configuration: other)?.state, .started)
    }

    func testDevelopmentAndProductionLedgersRemainSeparate() throws {
        var production = configuration!
        production.location = temporaryDirectory.appendingPathComponent("EnvironmentStore", isDirectory: true)
        production.cloudKitContainerIdentifier = "iCloud.example.GraphEvo"
        production.setResolvedEnvironment(.production)
        var development = production
        development.setResolvedEnvironment(.development)

        _ = try GraphMigrationLedger.markDone(migrationID: "environment", version: 1, synchronization: .local, configuration: production)

        XCTAssertEqual(GraphMigrationLedger.localRecord(migrationID: "environment", version: 1, configuration: production)?.state, .done)
        XCTAssertNil(GraphMigrationLedger.localRecord(migrationID: "environment", version: 1, configuration: development))
        XCTAssertNotEqual(
            GraphMigrationLedger.fileURLForTesting(migrationID: "environment", version: 1, configuration: production),
            GraphMigrationLedger.fileURLForTesting(migrationID: "environment", version: 1, configuration: development)
        )
    }

    func testCorruptedLedgerIsNotReplaced() throws {
        let url = GraphMigrationLedger.fileURLForTesting(migrationID: "corrupt", version: 1, configuration: configuration)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: url)
        XCTAssertThrowsError(try GraphMigrationLedger.markStarted(migrationID: "corrupt", version: 1, configuration: configuration))
        XCTAssertEqual(try Data(contentsOf: url), Data([0, 1, 2, 3]))
    }

    func testHistoryRetentionCompactsOlderEvents() throws {
        for index in 0..<500 {
            _ = try GraphMigrationLedger.markStarted(
                migrationID: "retention",
                version: 1,
                configuration: configuration,
                operationID: "attempt-(index)-started"
            )
            _ = try GraphMigrationLedger.markFailed(migrationID: "retention", version: 1, error: NSError(domain: "test", code: index, userInfo: [NSLocalizedDescriptionKey: String(repeating: "x", count: 8_000)]), configuration: configuration)
        }
        let snapshot = GraphMigrationLedger.snapshot(migrationID: "retention", version: 1, configuration: configuration)
        XCTAssertNotNil(snapshot)
        XCTAssertGreaterThan(snapshot?.compactedEventCount ?? 0, 0)
        XCTAssertGreaterThanOrEqual(snapshot?.historyCount ?? 0, 2)

        let data = try Data(contentsOf: GraphMigrationLedger.fileURLForTesting(migrationID: "retention", version: 1, configuration: configuration))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let summary = try XCTUnwrap(json["compactionSummary"] as? [String: Any])
        XCTAssertGreaterThan(summary["removedEventCount"] as? Int ?? 0, 0)
        XCTAssertFalse((summary["removedByState"] as? [String: Int] ?? [:]).isEmpty)
    }

    func testRepeatedNotRequiredEvaluationsUpdateProjectionWithoutHistoryNoise() throws {
        _ = try GraphMigrationLedger.markNotRequired(
            migrationID: "stable-evaluation",
            version: 1,
            configuration: configuration,
            phase: "preInit",
            operationID: "first",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        _ = try GraphMigrationLedger.markNotRequired(
            migrationID: "stable-evaluation",
            version: 1,
            configuration: configuration,
            phase: "ready",
            operationID: "second",
            now: Date(timeIntervalSince1970: 1_700_000_010)
        )

        let history = try GraphMigrationLedger.history(
            migrationID: "stable-evaluation",
            version: 1,
            configuration: configuration
        )
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.phase, "preInit")
        XCTAssertEqual(
            GraphMigrationLedger.snapshot(migrationID: "stable-evaluation", version: 1, configuration: configuration)?.latestEntry?.phase,
            "ready"
        )
    }

    func testNotRequiredDecisionChangeIsRecorded() throws {
        _ = try GraphMigrationLedger.markNotRequired(
            migrationID: "decision-change",
            version: 1,
            configuration: configuration,
            reason: .noCandidate,
            decisionSource: .localEvaluation,
            operationID: "first"
        )
        _ = try GraphMigrationLedger.markNotRequired(
            migrationID: "decision-change",
            version: 1,
            configuration: configuration,
            reason: .remoteDone,
            decisionSource: .remoteKVS,
            operationID: "second"
        )

        let history = try GraphMigrationLedger.history(
            migrationID: "decision-change",
            version: 1,
            configuration: configuration
        )
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.last?.decisionReason, .remoteDone)
    }

    func testRetentionLimitAppliesToTheWholeStoreScope() throws {
        for index in 0..<90 {
            for migrationID in ["aggregate-a", "aggregate-b"] {
                _ = try GraphMigrationLedger.markStarted(
                    migrationID: migrationID,
                    version: 1,
                    configuration: configuration,
                    operationID: "attempt-(index)-(migrationID)-started"
                )
                _ = try GraphMigrationLedger.markFailed(
                    migrationID: migrationID,
                    version: 1,
                    error: NSError(
                        domain: "aggregate-retention",
                        code: index,
                        userInfo: [NSLocalizedDescriptionKey: String(repeating: migrationID, count: 1_500)]
                    ),
                    configuration: configuration
                )
            }
        }

        let ledgerDirectory = GraphMigrationLedger.fileURLForTesting(migrationID: "aggregate-a", version: 1, configuration: configuration).deletingLastPathComponent()
        let ledgerFiles = try FileManager.default.contentsOfDirectory(at: ledgerDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" || $0.pathExtension == "jsonl" }
        let totalBytes = try ledgerFiles.reduce(into: 0) { total, url in
            total += try Data(contentsOf: url).count
        }
        XCTAssertLessThanOrEqual(totalBytes, 2 * 1024 * 1024)
        let compacted = ["aggregate-a", "aggregate-b"].compactMap {
            GraphMigrationLedger.snapshot(migrationID: $0, version: 1, configuration: configuration)?.compactedEventCount
        }.reduce(0, +)
        XCTAssertGreaterThan(compacted, 0)
    }

    func testLegacyRecordIsConvertedToCurrentSchemaAtomically() throws {
        let migrationID = "legacy"
        let url = GraphMigrationLedger.fileURLForTesting(migrationID: migrationID, version: 1, configuration: configuration)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = GraphMigrationRecord(
            migrationID: migrationID,
            version: 1,
            state: .done,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(legacy).write(to: url)

        XCTAssertEqual(GraphMigrationLedger.localRecord(migrationID: migrationID, version: 1, configuration: configuration)?.state, .done)
        let converted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(converted["schemaVersion"] as? Int, 1)
        let history = try GraphMigrationLedger.history(migrationID: migrationID, version: 1, configuration: configuration)
        XCTAssertEqual(history.first?.source, "legacyLedger")
    }

    func testUnknownVersionedSchemaIsRejectedWithoutOverwrite() throws {
        let migrationID = "unsupported-schema"
        _ = try GraphMigrationLedger.markStarted(migrationID: migrationID, version: 1, configuration: configuration)
        let url = GraphMigrationLedger.fileURLForTesting(migrationID: migrationID, version: 1, configuration: configuration)
        var projection = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        projection["schemaVersion"] = 2
        let unsupportedData = try JSONSerialization.data(withJSONObject: projection)
        try unsupportedData.write(to: url, options: .atomic)

        XCTAssertThrowsError(try GraphMigrationLedger.validate(migrationID: migrationID, version: 1, configuration: configuration)) {
            XCTAssertEqual($0 as? GraphMigrationLedgerError, .unsupportedSchema(2))
        }
        XCTAssertEqual(try Data(contentsOf: url), unsupportedData)
    }

    func testResetAndForceKeepStructuredRequestMetadata() throws {
        try GraphMigrationLedger.requestForce(
            migrationID: "requests",
            version: 1,
            configuration: configuration,
            requestedBy: .supportCenter,
            reason: "support retry"
        )
        let forceEntry = try XCTUnwrap(GraphMigrationLedger.history(migrationID: "requests", version: 1, configuration: configuration).last)
        XCTAssertEqual(forceEntry.requestedBy, .supportCenter)
        XCTAssertEqual(forceEntry.requestReason, "support retry")

        try GraphMigrationLedger.reset(
            migrationID: "requests",
            version: 1,
            configuration: configuration,
            targets: [.local],
            requestedBy: .user,
            reason: "manual recovery"
        )
        let resetEntry = try XCTUnwrap(GraphMigrationLedger.history(migrationID: "requests", version: 1, configuration: configuration).last)
        XCTAssertEqual(resetEntry.state, .notExecuted)
        XCTAssertEqual(resetEntry.resetTargets, [.local])
        XCTAssertEqual(resetEntry.requestReason, "manual recovery")
    }

    func testRemoteOnlyResetPreservesLocalProjection() throws {
        GraphMigrationLedger.setKVSStoreForTesting(TestMigrationKVSStore())
        _ = try GraphMigrationLedger.markDone(migrationID: "remote-reset", version: 1, synchronization: .local, configuration: configuration)

        try GraphMigrationLedger.reset(
            migrationID: "remote-reset",
            version: 1,
            configuration: configuration,
            targets: [.remote],
            requestedBy: .supportCenter,
            reason: "invalidate remote projection"
        )

        XCTAssertEqual(GraphMigrationLedger.localRecord(migrationID: "remote-reset", version: 1, configuration: configuration)?.state, .done)
        let resetEntry = try XCTUnwrap(GraphMigrationLedger.history(migrationID: "remote-reset", version: 1, configuration: configuration).last)
        XCTAssertEqual(resetEntry.state, .notExecuted)
        XCTAssertEqual(resetEntry.resetTargets, [.remote])
    }

    func testSnapshotExposesRecoveryAndPseudonymousScopeMetadata() throws {
        _ = try GraphMigrationLedger.markStarted(
            migrationID: "snapshot",
            version: 1,
            configuration: configuration,
            phase: "postMigration",
            operationID: "operation",
            generation: 7,
            backupReference: "/backup/reference"
        )

        let snapshot = try GraphMigrationLedger.stateSnapshot(migrationID: "snapshot", version: 1, configuration: configuration)
        XCTAssertTrue(snapshot.interrupted)
        XCTAssertEqual(snapshot.storeScope, GraphStoreScope(configuration: configuration).logicalKey)
        XCTAssertEqual(snapshot.generation, 7)
        XCTAssertEqual(snapshot.operationID, "operation")
        XCTAssertEqual(snapshot.phase, "postMigration")
        XCTAssertEqual(snapshot.backupReference, "/backup/reference")
        XCTAssertNil(snapshot.errorDescription)

        let entry = try XCTUnwrap(GraphMigrationLedger.history(migrationID: "snapshot", version: 1, configuration: configuration).last)
        XCTAssertEqual(entry.storeScope, GraphStoreScope(configuration: configuration).logicalKey)
        XCTAssertEqual(entry.deviceID, GraphMigrationLedger.installationIdentifier)
        XCTAssertNotEqual(entry.deviceID, ProcessInfo.processInfo.hostName)
        XCTAssertNil(entry.publishedAt)
    }

    func testSameGenerationRemoteConflictUsesDeterministicOrdering() throws {
        let migrationID = "remote-conflict"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func remote(deviceID: String, operationID: String) -> GraphMigrationLedgerEntry {
            GraphMigrationLedgerEntry(
                schemaVersion: 1,
                operationID: operationID,
                generation: 12,
                migrationID: migrationID,
                version: 1,
                state: .done,
                phase: "ready",
                requestedBy: .migrationManager,
                deviceID: deviceID,
                appVersion: "1",
                graphModelVersion: nil,
                backupReference: nil,
                previousOperationID: nil,
                decisionReason: nil,
                source: "localLedger",
                date: date,
                errorDescription: nil,
                storeScope: GraphStoreScope(configuration: configuration).logicalKey,
                observedAt: nil,
                publishedAt: date
            )
        }
        let lower = remote(deviceID: "installation-A", operationID: "operation-Z")
        let higher = remote(deviceID: "installation-B", operationID: "operation-A")

        try GraphMigrationLedger.reconcileRemoteEntryForTesting(higher, configuration: configuration)
        try GraphMigrationLedger.reconcileRemoteEntryForTesting(lower, configuration: configuration)
        try GraphMigrationLedger.reconcileRemoteEntryForTesting(lower, configuration: configuration)

        let observations = try GraphMigrationLedger.history(migrationID: migrationID, version: 1, configuration: configuration).filter { $0.source == "remoteKVS" }
        XCTAssertEqual(observations.map(\.deviceID), ["installation-B", "installation-A"])
        XCTAssertTrue(observations.allSatisfy { $0.observedAt != nil && $0.publishedAt == date })
        XCTAssertTrue(GraphMigrationLedger.orderedAfterForTesting(higher, lower))
        XCTAssertFalse(GraphMigrationLedger.orderedAfterForTesting(lower, higher))
        XCTAssertEqual(try GraphMigrationLedger.stateSnapshot(migrationID: migrationID, version: 1, configuration: configuration).operationID, higher.operationID)
    }

    func testOrdinaryProjectionReadDoesNotDecodeHistory() throws {
        let migrationID = "projection-only"
        _ = try GraphMigrationLedger.markStarted(migrationID: migrationID, version: 1, configuration: configuration)
        let historyURL = GraphMigrationLedger.historyURLForTesting(migrationID: migrationID, version: 1, configuration: configuration)
        try Data("truncated".utf8).write(to: historyURL)

        XCTAssertEqual(GraphMigrationLedger.localRecord(migrationID: migrationID, version: 1, configuration: configuration)?.state, .started)
        XCTAssertThrowsError(try GraphMigrationLedger.history(migrationID: migrationID, version: 1, configuration: configuration))
    }

    func testJournalRecoversEveryLocalCommitCrashPointIdempotently() throws {
        enum SimulatedCrash: Error { case now }
        for (index, point) in [GraphMigrationLedgerFaultPoint.afterJournal, .afterHistory, .afterProjection].enumerated() {
            let migrationID = "crash-\(index)"
            var fired = false
            GraphMigrationLedger.setFaultForTesting { current in
                guard current == point, !fired else { return }
                fired = true
                throw SimulatedCrash.now
            }
            XCTAssertThrowsError(try GraphMigrationLedger.markStarted(migrationID: migrationID, version: 1, configuration: configuration))
            GraphMigrationLedger.setFaultForTesting(nil)

            XCTAssertEqual(GraphMigrationLedger.localRecord(migrationID: migrationID, version: 1, configuration: configuration)?.state, .started)
            XCTAssertEqual(try GraphMigrationLedger.history(migrationID: migrationID, version: 1, configuration: configuration).filter { $0.state == .started }.count, 1)
        }
    }

    func testJournalRecoversFinalLedgerStateAfterStoreSave() throws {
        enum SimulatedCrash: Error { case now }
        let migrationID = "save-before-ledger"
        _ = try GraphMigrationLedger.markStarted(migrationID: migrationID, version: 1, configuration: configuration, operationID: "attempt", generation: 5)
        var fired = false
        GraphMigrationLedger.setFaultForTesting { point in
            guard point == .afterJournal, !fired else { return }
            fired = true
            throw SimulatedCrash.now
        }
        XCTAssertThrowsError(try GraphMigrationLedger.markDone(migrationID: migrationID, version: 1, synchronization: .local, configuration: configuration, operationID: "attempt", generation: 5))
        GraphMigrationLedger.setFaultForTesting(nil)

        XCTAssertEqual(GraphMigrationLedger.localRecord(migrationID: migrationID, version: 1, configuration: configuration)?.state, .done)
        XCTAssertEqual(try GraphMigrationLedger.history(migrationID: migrationID, version: 1, configuration: configuration).map(\.state), [.started, .done])
    }

    func testFailedKVSPublicationRemainsPendingAndRetriesSameOperation() throws {
        let store = TestMigrationKVSStore()
        store.acceptsWrites = false
        GraphMigrationLedger.setKVSStoreForTesting(store)
        let migrationID = "pending-kvs"

        XCTAssertThrowsError(try GraphMigrationLedger.reset(migrationID: migrationID, version: 1, configuration: configuration, targets: [.remote], requestedBy: .supportCenter, reason: "retry"))
        let pending = try XCTUnwrap(GraphMigrationLedger.snapshot(migrationID: migrationID, version: 1, configuration: configuration)?.pendingPublication)
        XCTAssertNil(GraphMigrationLedger.snapshot(migrationID: migrationID, version: 1, configuration: configuration)?.lastPublished)

        store.acceptsWrites = true
        try GraphMigrationLedger.retryPendingPublicationForTesting(migrationID: migrationID, version: 1, configuration: configuration)
        let completed = try XCTUnwrap(GraphMigrationLedger.snapshot(migrationID: migrationID, version: 1, configuration: configuration))
        XCTAssertNil(completed.pendingPublication)
        XCTAssertEqual(completed.lastPublished?.operationID, pending.operationID)
        XCTAssertNotNil(completed.lastPublished?.publishedAt)
    }

    func testKVSPublicationPreservesEntriesFromOtherScopes() throws {
        let store = TestMigrationKVSStore()
        let otherKey = "other-scope|migration|1"
        store.values["GraphEvo.migration.ledger.v2"] = [otherKey: Data([1, 2, 3])]
        GraphMigrationLedger.setKVSStoreForTesting(store)

        try GraphMigrationLedger.reset(
            migrationID: "preserve-scope",
            version: 1,
            configuration: configuration,
            targets: [.remote],
            requestedBy: .system,
            reason: "concurrent publication"
        )

        let values = try XCTUnwrap(store.values["GraphEvo.migration.ledger.v2"] as? [String: Any])
        XCTAssertEqual(values[otherKey] as? Data, Data([1, 2, 3]))
    }

    func testCrashAfterKVSWriteRetriesWithoutChangingOperationIdentity() throws {
        enum SimulatedCrash: Error { case now }
        let store = TestMigrationKVSStore()
        GraphMigrationLedger.setKVSStoreForTesting(store)
        var fired = false
        GraphMigrationLedger.setFaultForTesting { point in
            guard point == .afterKVSWrite, !fired else { return }
            fired = true
            throw SimulatedCrash.now
        }
        let migrationID = "kvs-write-crash"

        try GraphMigrationLedger.reset(migrationID: migrationID, version: 1, configuration: configuration, targets: [.remote], requestedBy: .system, reason: "test")
        let operationID = try XCTUnwrap(GraphMigrationLedger.snapshot(migrationID: migrationID, version: 1, configuration: configuration)?.lastPublished?.operationID)
        GraphMigrationLedger.setFaultForTesting(nil)
        try GraphMigrationLedger.retryPendingPublicationForTesting(migrationID: migrationID, version: 1, configuration: configuration)
        XCTAssertEqual(GraphMigrationLedger.snapshot(migrationID: migrationID, version: 1, configuration: configuration)?.lastPublished?.operationID, operationID)
    }

    func testFailedStateWritePropagatesLedgerErrorWithoutCreatingDoneState() throws {
        enum SimulatedCrash: Error { case now }
        let migrationID = "failed-state-write"
        GraphMigrationLedger.setFaultForTesting { point in
            if point == .afterJournal { throw SimulatedCrash.now }
        }

        XCTAssertThrowsError(try GraphMigrationLedger.markFailed(
            migrationID: migrationID,
            version: 1,
            error: NSError(domain: "migration", code: 1),
            configuration: configuration
        ))
        GraphMigrationLedger.setFaultForTesting(nil)
        XCTAssertNotEqual(GraphMigrationLedger.localRecord(
            migrationID: migrationID,
            version: 1,
            configuration: configuration
        )?.state, .done)
    }

    func testLegacyKVSIsPromotedOnlyForProduction() throws {
        let migrationID = "legacy-kvs"
        let store = TestMigrationKVSStore()
        GraphMigrationLedger.setKVSStoreForTesting(store)
        var production = configuration!
        production.cloudKitContainerIdentifier = "iCloud.example.GraphEvo"
        production.setResolvedEnvironment(.production)
        let legacyKey = GraphMigrationLedger.legacyCloudKeyForTesting(migrationID: migrationID, version: 1, configuration: production)
        store.values[legacyKey] = ["status": GraphMigrationState.done.rawValue, "completedAt": Date()]

        try GraphMigrationLedger.reconcileRemoteObservation(migrationID: migrationID, version: 1, synchronization: .localAndICloudKeyValueStore, configuration: production)
        guard case .observed(let productionRemote) = try GraphMigrationLedger.stateSnapshot(migrationID: migrationID, version: 1, configuration: production).remoteState else { return XCTFail("Expected Production legacy observation") }
        XCTAssertEqual(productionRemote.state, .done)
        XCTAssertTrue(store.values.keys.contains("GraphEvo.migration.ledger.v2"))

        let developmentStore = TestMigrationKVSStore()
        developmentStore.values[legacyKey] = store.values[legacyKey]
        GraphMigrationLedger.setKVSStoreForTesting(developmentStore)
        var development = production
        development.setResolvedEnvironment(.development)
        try GraphMigrationLedger.reconcileRemoteObservation(migrationID: migrationID, version: 1, synchronization: .localAndICloudKeyValueStore, configuration: development)
        guard case .unknown = try GraphMigrationLedger.stateSnapshot(migrationID: migrationID, version: 1, configuration: development).remoteState else { return XCTFail("Development adopted a legacy Production entry") }
    }
}

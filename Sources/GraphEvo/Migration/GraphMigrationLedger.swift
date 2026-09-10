import Foundation

public enum GraphMigrationState: String, Codable, Sendable { case started, done, notRequired, notExecuted, failed }
public enum GraphMigrationCompletionSynchronization: Equatable, Sendable { case local, localAndICloudKeyValueStore }

public struct GraphMigrationRecord: Codable, Equatable, Sendable {
    public let migrationID: String
    public let version: Int
    public let state: GraphMigrationState
    public let startedAt: Date
    public let updatedAt: Date
    public let errorDescription: String?

    public init(migrationID: String, version: Int, state: GraphMigrationState, startedAt: Date, updatedAt: Date, errorDescription: String? = nil) {
        self.migrationID = migrationID
        self.version = version
        self.state = state
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.errorDescription = errorDescription
    }
}

public enum GraphMigrationRequestedBy: String, Codable, Sendable { case system, migrationManager, supportCenter, user, recovery }
public enum GraphMigrationDecisionReason: String, Codable, Sendable { case remoteDone, noCandidate, alreadyCompatible, manualSkip }
public enum GraphMigrationDecisionSource: String, Codable, Sendable { case localEvaluation, remoteKVS, recovery, manual }
public enum GraphMigrationResetTarget: String, Codable, Sendable { case local, remote, localAndRemote }

struct GraphMigrationForceRequest: Codable, Equatable {
    let operationID: String
    let generation: UInt64
    let migrationID: String
    let version: Int
    let scope: String
    let requestedBy: GraphMigrationRequestedBy
    let reason: String
    let date: Date
}

public struct GraphMigrationLedgerEntry: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let operationID: String
    public let generation: UInt64
    public let migrationID: String
    public let version: Int
    public let state: GraphMigrationState
    public let phase: String
    public let requestedBy: GraphMigrationRequestedBy
    public let deviceID: String
    public let appVersion: String
    public let graphModelVersion: Int?
    public let backupReference: String?
    public let previousOperationID: String?
    public let decisionReason: GraphMigrationDecisionReason?
    public let decisionSource: GraphMigrationDecisionSource?
    public let source: String
    public let date: Date
    public let errorDescription: String?
    public let storeScope: String
    public let observedAt: Date?
    public let publishedAt: Date?
    public let resetTargets: [GraphMigrationResetTarget]?
    public let requestReason: String?

    public init(schemaVersion: Int, operationID: String, generation: UInt64, migrationID: String, version: Int, state: GraphMigrationState, phase: String, requestedBy: GraphMigrationRequestedBy, deviceID: String, appVersion: String, graphModelVersion: Int?, backupReference: String?, previousOperationID: String?, decisionReason: GraphMigrationDecisionReason?, decisionSource: GraphMigrationDecisionSource? = nil, source: String, date: Date, errorDescription: String?, storeScope: String, observedAt: Date?, publishedAt: Date?, resetTargets: [GraphMigrationResetTarget]? = nil, requestReason: String? = nil) {
        self.schemaVersion = schemaVersion; self.operationID = operationID; self.generation = generation
        self.migrationID = migrationID; self.version = version; self.state = state; self.phase = phase
        self.requestedBy = requestedBy; self.deviceID = deviceID; self.appVersion = appVersion
        self.graphModelVersion = graphModelVersion; self.backupReference = backupReference; self.previousOperationID = previousOperationID
        self.decisionReason = decisionReason; self.decisionSource = decisionSource; self.source = source; self.date = date
        self.errorDescription = errorDescription; self.storeScope = storeScope; self.observedAt = observedAt; self.publishedAt = publishedAt
        self.resetTargets = resetTargets; self.requestReason = requestReason
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, operationID, generation, migrationID, version, state, phase, requestedBy, deviceID, appVersion
        case graphModelVersion, backupReference, previousOperationID, decisionReason, decisionSource, source, date, errorDescription
        case storeScope, observedAt, publishedAt, resetTargets, requestReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        operationID = try c.decode(String.self, forKey: .operationID)
        generation = try c.decode(UInt64.self, forKey: .generation)
        migrationID = try c.decode(String.self, forKey: .migrationID)
        version = try c.decode(Int.self, forKey: .version)
        state = try c.decode(GraphMigrationState.self, forKey: .state)
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? "unknown"
        requestedBy = try c.decodeIfPresent(GraphMigrationRequestedBy.self, forKey: .requestedBy) ?? .migrationManager
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? "unknown"
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "unknown"
        graphModelVersion = try c.decodeIfPresent(Int.self, forKey: .graphModelVersion)
        backupReference = try c.decodeIfPresent(String.self, forKey: .backupReference)
        previousOperationID = try c.decodeIfPresent(String.self, forKey: .previousOperationID)
        decisionReason = try c.decodeIfPresent(GraphMigrationDecisionReason.self, forKey: .decisionReason)
        decisionSource = try c.decodeIfPresent(GraphMigrationDecisionSource.self, forKey: .decisionSource)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "localLedger"
        date = try c.decode(Date.self, forKey: .date)
        errorDescription = try c.decodeIfPresent(String.self, forKey: .errorDescription)
        storeScope = try c.decodeIfPresent(String.self, forKey: .storeScope) ?? "legacy"
        observedAt = try c.decodeIfPresent(Date.self, forKey: .observedAt)
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        resetTargets = try c.decodeIfPresent([GraphMigrationResetTarget].self, forKey: .resetTargets)
        requestReason = try c.decodeIfPresent(String.self, forKey: .requestReason)
    }
}

private struct GraphMigrationCompactionSummary: Codable {
    var removedEventCount = 0
    var removedByState: [String: Int] = [:]
    var firstRemovedGeneration: UInt64?
    var lastRemovedGeneration: UInt64?

    mutating func include(_ entry: GraphMigrationLedgerEntry) {
        removedEventCount += 1
        removedByState[entry.state.rawValue, default: 0] += 1
        firstRemovedGeneration = firstRemovedGeneration ?? entry.generation
        lastRemovedGeneration = entry.generation
    }
}

private struct LedgerProjection: Codable {
    var schemaVersion: Int
    var current: GraphMigrationRecord
    var latestEntry: GraphMigrationLedgerEntry?
    var remoteObserved: GraphMigrationLedgerEntry?
    var lastPublished: GraphMigrationLedgerEntry?
    var pendingPublication: GraphMigrationLedgerEntry?
    var publicationError: String?
    var forcePending: [GraphMigrationForceRequest]
    var latestGeneration: UInt64
    var historyCount: Int
    var compactionSummary: GraphMigrationCompactionSummary
}

private struct LedgerSchemaHeader: Decodable { let schemaVersion: Int }

private struct LedgerTransaction: Codable { let projection: LedgerProjection; let entry: GraphMigrationLedgerEntry? }
private final class LedgerRetentionResult: @unchecked Sendable { var error: Error? }

struct GraphMigrationLedgerSnapshot {
    let current: GraphMigrationRecord
    let historyCount: Int
    let compactedEventCount: Int
    let pendingForceCount: Int
    let latestEntry: GraphMigrationLedgerEntry?
    let lastPublished: GraphMigrationLedgerEntry?
    let pendingPublication: GraphMigrationLedgerEntry?
    let publicationError: String?
}

enum GraphMigrationLedgerError: LocalizedError, Equatable {
    case corrupted(URL), unsupportedSchema(Int), invalidRemoteProjection, publicationNotAccepted

    var errorDescription: String? {
        switch self {
        case .corrupted(let url): return "The migration ledger at \(url.path) is corrupted or truncated."
        case .unsupportedSchema(let version): return "The migration ledger schema version \(version) is not supported."
        case .invalidRemoteProjection: return "The remote migration projection does not match the requested store scope or migration."
        case .publicationNotAccepted: return "The migration KVS projection was not accepted by the local ubiquitous store."
        }
    }
}

#if DEBUG
enum GraphMigrationLedgerFaultPoint { case afterJournal, afterHistory, afterProjection, afterKVSWrite }
#endif

enum GraphMigrationLedger {
    private static let queue = DispatchQueue(label: "GraphEvo.migration-ledger")
    private static let retentionQueue = DispatchQueue(label: "GraphEvo.migration-ledger.retention", qos: .utility)
    private static let fm = FileManager.default
    private static let schemaVersion = 1
    private static let maxBytes = 2 * 1024 * 1024
    private static let kvsKey = "GraphEvo.migration.ledger.v2"
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }()
    private static var kvs: GraphMigrationKVSStore = GraphMigrationUbiquitousKVSStore.shared
#if DEBUG
    private static var faultForTesting: ((GraphMigrationLedgerFaultPoint) throws -> Void)?
#endif

    static var installationIdentifier: String {
        let key = "GraphEvo.migration.installationIdentifier"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    static var kvsObservation: (name: Notification.Name, object: AnyObject?) { queue.sync { (kvs.changeNotification, kvs.notificationObject) } }
    @discardableResult static func synchronizeKVS() -> Bool { queue.sync { kvs.synchronize() } }
    static func validate(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws { try queue.sync { _ = try readProjection(migrationID: migrationID, version: version, configuration: configuration) } }

    static func localRecord(migrationID: String, version: Int, configuration: GraphStoreConfiguration) -> GraphMigrationRecord? {
        queue.sync {
            do { return try readProjection(migrationID: migrationID, version: version, configuration: configuration)?.current }
            catch { GraphMigrationLogger.log(migrationID: migrationID, level: .error, event: "migration_ledger_read_failed", message: error.localizedDescription, configuration: configuration); return nil }
        }
    }

    static func reconciledRecord(migrationID: String, version: Int, synchronization: GraphMigrationCompletionSynchronization, configuration: GraphStoreConfiguration) -> GraphMigrationRecord? {
        do { return try reconciledRecordThrowing(migrationID: migrationID, version: version, synchronization: synchronization, configuration: configuration) }
        catch { GraphMigrationLogger.log(migrationID: migrationID, level: .error, event: "migration_ledger_reconciliation_failed", message: error.localizedDescription, configuration: configuration); return nil }
    }

    static func reconciledRecordThrowing(migrationID: String, version: Int, synchronization: GraphMigrationCompletionSynchronization, configuration: GraphStoreConfiguration) throws -> GraphMigrationRecord? {
        try queue.sync {
            guard let current = try readProjection(migrationID: migrationID, version: version, configuration: configuration)?.current else { return nil }
            if synchronization == .localAndICloudKeyValueStore {
                try publishPendingLocked(migrationID: migrationID, version: version, configuration: configuration)
                try reconcileRemoteLocked(migrationID: migrationID, version: version, configuration: configuration)
            }
            return current
        }
    }

    static func reconcileRemoteObservation(migrationID: String, version: Int, synchronization: GraphMigrationCompletionSynchronization, configuration: GraphStoreConfiguration) throws {
        guard synchronization == .localAndICloudKeyValueStore else { return }
        try queue.sync {
            try publishPendingLocked(migrationID: migrationID, version: version, configuration: configuration)
            try reconcileRemoteLocked(migrationID: migrationID, version: version, configuration: configuration)
        }
    }

    static func markStarted(migrationID: String, version: Int, configuration: GraphStoreConfiguration, phase: String = "unknown", operationID: String = UUID().uuidString, generation: UInt64? = nil, backupReference: String? = nil, previousOperationID: String? = nil, requestedBy: GraphMigrationRequestedBy = .migrationManager, now: Date = Date()) throws -> GraphMigrationRecord {
        try transition(migrationID: migrationID, version: version, state: .started, configuration: configuration, phase: phase, operationID: operationID, generation: generation, backupReference: backupReference, previousOperationID: previousOperationID, requestedBy: requestedBy, now: now)
    }

    static func markDone(migrationID: String, version: Int, synchronization: GraphMigrationCompletionSynchronization, configuration: GraphStoreConfiguration, phase: String = "unknown", operationID: String = UUID().uuidString, generation: UInt64? = nil, backupReference: String? = nil, previousOperationID: String? = nil, requestedBy: GraphMigrationRequestedBy = .migrationManager, now: Date = Date()) throws -> GraphMigrationRecord {
        let record = try transition(migrationID: migrationID, version: version, state: .done, configuration: configuration, phase: phase, operationID: operationID, generation: generation, backupReference: backupReference, previousOperationID: previousOperationID, requestedBy: requestedBy, publish: synchronization == .localAndICloudKeyValueStore, now: now)
        if synchronization == .localAndICloudKeyValueStore {
            try queue.sync { try publishPendingLocked(migrationID: migrationID, version: version, configuration: configuration) }
        }
        return record
    }

    static func markNotRequired(migrationID: String, version: Int, configuration: GraphStoreConfiguration, reason: GraphMigrationDecisionReason = .noCandidate, decisionSource: GraphMigrationDecisionSource = .localEvaluation, phase: String = "unknown", operationID: String = UUID().uuidString, generation: UInt64? = nil, backupReference: String? = nil, requestedBy: GraphMigrationRequestedBy = .migrationManager, now: Date = Date()) throws -> GraphMigrationRecord {
        try transition(migrationID: migrationID, version: version, state: .notRequired, configuration: configuration, phase: phase, operationID: operationID, generation: generation, backupReference: backupReference, reason: reason, decisionSource: decisionSource, requestedBy: requestedBy, now: now)
    }

    static func markFailed(migrationID: String, version: Int, error: Error, configuration: GraphStoreConfiguration, phase: String = "unknown", operationID: String = UUID().uuidString, generation: UInt64? = nil, backupReference: String? = nil, requestedBy: GraphMigrationRequestedBy = .migrationManager, now: Date = Date()) throws -> GraphMigrationRecord {
        try transition(migrationID: migrationID, version: version, state: .failed, configuration: configuration, phase: phase, operationID: operationID, generation: generation, backupReference: backupReference, requestedBy: requestedBy, now: now, errorDescription: error.localizedDescription)
    }

    static func reset(migrationID: String, version: Int, synchronization: GraphMigrationCompletionSynchronization, configuration: GraphStoreConfiguration, target: GraphMigrationResetTarget = .localAndRemote) throws {
        let targets: Set<GraphMigrationResetTarget>
        if target == .localAndRemote, synchronization == .local { targets = [.local] }
        else { targets = target == .localAndRemote ? [.local, .remote] : [target] }
        try reset(migrationID: migrationID, version: version, configuration: configuration, targets: targets, requestedBy: .user, reason: "manual reset")
    }

    static func reset(migrationID: String, version: Int, configuration: GraphStoreConfiguration, targets: Set<GraphMigrationResetTarget>, requestedBy: GraphMigrationRequestedBy, reason: String) throws {
        let normalized = targets.contains(.localAndRemote) ? Set<GraphMigrationResetTarget>([.local, .remote]) : targets
        try queue.sync {
            let now = Date()
            var p = try readProjection(migrationID: migrationID, version: version, configuration: configuration) ?? emptyProjection(migrationID: migrationID, version: version)
            let record = GraphMigrationRecord(migrationID: migrationID, version: version, state: .notExecuted, startedAt: now, updatedAt: now)
            let generation = p.latestGeneration + 1
            let event = entry(for: record, configuration: configuration, operationID: UUID().uuidString, generation: generation, previousOperationID: p.latestEntry?.operationID, source: "reset", requestedBy: requestedBy, reason: .manualSkip, decisionSource: .manual, resetTargets: normalized.sorted { $0.rawValue < $1.rawValue }, requestReason: reason)
            if normalized.contains(.local) { p.current = record }
            p.latestEntry = event; p.latestGeneration = generation; p.historyCount += 1
            if normalized.contains(.remote) { p.pendingPublication = event }
            try commit(p, entry: event, migrationID: migrationID, version: version, configuration: configuration)
            if normalized.contains(.remote) { try publishPendingLocked(migrationID: migrationID, version: version, configuration: configuration) }
        }
    }

    static func requestForce(migrationID: String, version: Int, configuration: GraphStoreConfiguration, requestedBy: GraphMigrationRequestedBy = .user, reason: String) throws {
        try queue.sync {
            var p = try readProjection(migrationID: migrationID, version: version, configuration: configuration) ?? emptyProjection(migrationID: migrationID, version: version)
            let generation = p.latestGeneration + 1
            let request = GraphMigrationForceRequest(operationID: UUID().uuidString, generation: generation, migrationID: migrationID, version: version, scope: GraphStoreScope(configuration: configuration).logicalKey, requestedBy: requestedBy, reason: reason, date: Date())
            p.forcePending.append(request)
            let event = entry(for: p.current, configuration: configuration, operationID: request.operationID, generation: generation, previousOperationID: p.latestEntry?.operationID, source: "forceRequest", requestedBy: requestedBy, decisionSource: .manual, requestReason: reason)
            p.latestEntry = event; p.latestGeneration = generation; p.historyCount += 1
            try commit(p, entry: event, migrationID: migrationID, version: version, configuration: configuration)
        }
    }

    static func consumeForce(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws -> GraphMigrationForceRequest? {
        try queue.sync {
            guard var p = try readProjection(migrationID: migrationID, version: version, configuration: configuration), !p.forcePending.isEmpty else { return nil }
            let request = p.forcePending.removeFirst()
            try commit(p, entry: nil, migrationID: migrationID, version: version, configuration: configuration)
            return request
        }
    }

    static func clearLocal(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws {
        try queue.sync { for url in allURLs(migrationID, version, configuration) where fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) } }
    }

    static func snapshot(migrationID: String, version: Int, configuration: GraphStoreConfiguration) -> GraphMigrationLedgerSnapshot? {
        queue.sync {
            do {
                guard let p = try readProjection(migrationID: migrationID, version: version, configuration: configuration) else { return nil }
                return GraphMigrationLedgerSnapshot(current: p.current, historyCount: p.historyCount, compactedEventCount: p.compactionSummary.removedEventCount, pendingForceCount: p.forcePending.count, latestEntry: p.latestEntry, lastPublished: p.lastPublished, pendingPublication: p.pendingPublication, publicationError: p.publicationError)
            } catch { GraphMigrationLogger.log(migrationID: migrationID, level: .error, event: "migration_ledger_snapshot_failed", message: error.localizedDescription, configuration: configuration); return nil }
        }
    }

    static func stateSnapshot(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws -> GraphMigrationStateSnapshot {
        try queue.sync {
            let p = try readProjection(migrationID: migrationID, version: version, configuration: configuration)
            let remote: GraphMigrationRemoteState = p?.remoteObserved.map { .observed(record(from: $0)) } ?? .unknown
            let latest = [p?.latestEntry, p?.remoteObserved].compactMap { $0 }.max(by: { isOrderedAfter($1, $0) })
            return GraphMigrationStateSnapshot(storeScope: GraphStoreScope(configuration: configuration).logicalKey, localRecord: p?.current, remoteState: remote, generation: latest?.generation, operationID: latest?.operationID, phase: latest?.phase, backupReference: latest?.backupReference, errorDescription: p?.current.errorDescription, attemptCount: p?.historyCount ?? 0, interrupted: p?.current.state == .started)
        }
    }

    static func history(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws -> [GraphMigrationLedgerEntry] {
        try queue.sync { _ = try readProjection(migrationID: migrationID, version: version, configuration: configuration); return try readHistory(at: historyURL(migrationID, version, configuration)) }
    }

    static func fileURLForTesting(migrationID: String, version: Int, configuration: GraphStoreConfiguration) -> URL { recordURL(migrationID, version, configuration) }
    static func historyURLForTesting(migrationID: String, version: Int, configuration: GraphStoreConfiguration) -> URL { historyURL(migrationID, version, configuration) }

#if DEBUG
    static func setKVSStoreForTesting(_ store: GraphMigrationKVSStore) { queue.sync { kvs = store } }
    static func resetKVSStoreForTesting() { queue.sync { kvs = GraphMigrationUbiquitousKVSStore.shared } }
    static func setFaultForTesting(_ fault: ((GraphMigrationLedgerFaultPoint) throws -> Void)?) { queue.sync { faultForTesting = fault } }
    static func orderedAfterForTesting(_ candidate: GraphMigrationLedgerEntry, _ reference: GraphMigrationLedgerEntry) -> Bool { isOrderedAfter(candidate, reference) }
    static func reconcileRemoteEntryForTesting(_ item: GraphMigrationLedgerEntry, configuration: GraphStoreConfiguration) throws { try queue.sync { try storeRemoteObservation(observedRemote(item), migrationID: item.migrationID, version: item.version, configuration: configuration) } }
    static func retryPendingPublicationForTesting(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws { try queue.sync { try publishPendingLocked(migrationID: migrationID, version: version, configuration: configuration) } }
    static func legacyCloudKeyForTesting(migrationID: String, version: Int, configuration: GraphStoreConfiguration) -> String { legacyCloudKey(migrationID, version, configuration) }
#endif
}

private extension GraphMigrationLedger {
    static func transition(migrationID: String, version: Int, state: GraphMigrationState, configuration: GraphStoreConfiguration, phase: String = "unknown", operationID: String = UUID().uuidString, generation: UInt64? = nil, backupReference: String? = nil, previousOperationID: String? = nil, reason: GraphMigrationDecisionReason? = nil, decisionSource: GraphMigrationDecisionSource? = nil, source: String = "localLedger", requestedBy: GraphMigrationRequestedBy = .migrationManager, publish: Bool = false, now: Date = Date(), errorDescription: String? = nil) throws -> GraphMigrationRecord {
        try queue.sync {
            let old = try readProjection(migrationID: migrationID, version: version, configuration: configuration)
            let record = GraphMigrationRecord(migrationID: migrationID, version: version, state: state, startedAt: old?.current.startedAt ?? now, updatedAt: now, errorDescription: errorDescription)
            var p = old ?? emptyProjection(migrationID: migrationID, version: version, current: record)
            let next = generation ?? p.latestGeneration + 1
            let event = entry(for: record, configuration: configuration, phase: phase, operationID: operationID, generation: next, backupReference: backupReference, previousOperationID: previousOperationID ?? p.latestEntry?.operationID, source: source, requestedBy: requestedBy, reason: reason, decisionSource: decisionSource)
            let appendToHistory = shouldAppendHistory(previous: p.latestEntry, current: event)
            p.current = record
            p.latestEntry = event
            p.latestGeneration = max(p.latestGeneration, next)
            if appendToHistory { p.historyCount += 1 }
            if publish { p.pendingPublication = event; p.publicationError = nil }
            try commit(p, entry: appendToHistory ? event : nil, migrationID: migrationID, version: version, configuration: configuration)
            return record
        }
    }

    static func readProjection(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws -> LedgerProjection? {
        try recoverTransactionIfNeeded(migrationID, version, configuration)
        let url = recordURL(migrationID, version, configuration)
        let legacy = legacyRecordURL(migrationID, version, configuration)
        let candidate = fm.fileExists(atPath: url.path) ? url : (configuration.environment == .production && fm.fileExists(atPath: legacy.path) ? legacy : nil)
        guard let candidate else { return nil }
        let data: Data
        do { data = try Data(contentsOf: candidate) } catch { throw GraphMigrationLedgerError.corrupted(candidate) }
        if let p = try? decoder.decode(LedgerProjection.self, from: data) {
            guard p.schemaVersion == schemaVersion else { throw GraphMigrationLedgerError.unsupportedSchema(p.schemaVersion) }
            return p
        }
        if let header = try? decoder.decode(LedgerSchemaHeader.self, from: data) {
            throw GraphMigrationLedgerError.unsupportedSchema(header.schemaVersion)
        }
        return try convertLegacy(data, candidate, migrationID, version, configuration)
    }

    static func convertLegacy(_ data: Data, _ sourceURL: URL, _ migrationID: String, _ version: Int, _ configuration: GraphStoreConfiguration) throws -> LedgerProjection {
        guard let current = try? decoder.decode(GraphMigrationRecord.self, from: data) else { throw GraphMigrationLedgerError.corrupted(sourceURL) }
        let entries = [entry(for: current, configuration: configuration, source: "legacyLedger")]
        let latest = entries[0]
        let p = LedgerProjection(schemaVersion: schemaVersion, current: current, latestEntry: latest, remoteObserved: nil, lastPublished: nil, pendingPublication: nil, publicationError: nil, forcePending: [], latestGeneration: latest.generation, historyCount: entries.count, compactionSummary: .init())
        try writeHistory(entries, to: historyURL(migrationID, version, configuration))
        try writeAtomically(p, to: recordURL(migrationID, version, configuration))
        return p
    }

    static func emptyProjection(migrationID: String, version: Int, current: GraphMigrationRecord? = nil) -> LedgerProjection {
        let now = Date()
        return LedgerProjection(schemaVersion: schemaVersion, current: current ?? GraphMigrationRecord(migrationID: migrationID, version: version, state: .notExecuted, startedAt: now, updatedAt: now), latestEntry: nil, remoteObserved: nil, lastPublished: nil, pendingPublication: nil, publicationError: nil, forcePending: [], latestGeneration: 0, historyCount: 0, compactionSummary: .init())
    }

    static func commit(_ p: LedgerProjection, entry: GraphMigrationLedgerEntry?, migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws {
        let transaction = transactionURL(migrationID, version, configuration)
        try writeAtomically(LedgerTransaction(projection: p, entry: entry), to: transaction)
#if DEBUG
        try faultForTesting?(.afterJournal)
#endif
        if let entry { try appendHistoryIfNeeded(entry, to: historyURL(migrationID, version, configuration)) }
#if DEBUG
        try faultForTesting?(.afterHistory)
#endif
        try writeAtomically(p, to: recordURL(migrationID, version, configuration))
#if DEBUG
        try faultForTesting?(.afterProjection)
#endif
        try fm.removeItem(at: transaction)
        try performRetention(in: recordURL(migrationID, version, configuration).deletingLastPathComponent())
    }

    static func recoverTransactionIfNeeded(_ migrationID: String, _ version: Int, _ configuration: GraphStoreConfiguration) throws {
        let url = transactionURL(migrationID, version, configuration)
        guard fm.fileExists(atPath: url.path) else { return }
        let transaction: LedgerTransaction
        do { transaction = try decoder.decode(LedgerTransaction.self, from: Data(contentsOf: url)) } catch { throw GraphMigrationLedgerError.corrupted(url) }
        if let entry = transaction.entry { try appendHistoryIfNeeded(entry, to: historyURL(migrationID, version, configuration)) }
        try writeAtomically(transaction.projection, to: recordURL(migrationID, version, configuration))
        try fm.removeItem(at: url)
    }

    static func appendHistoryIfNeeded(_ entry: GraphMigrationLedgerEntry, to url: URL) throws {
        let entries = try readHistory(at: url)
        guard !entries.contains(entry) else { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { guard fm.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) } }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var data = try encoder.encode(entry); data.append(0x0A)
        try handle.write(contentsOf: data); try handle.synchronize()
    }

    static func readHistory(at url: URL) throws -> [GraphMigrationLedgerEntry] {
        guard fm.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw GraphMigrationLedgerError.corrupted(url) }
        guard data.isEmpty || data.last == 0x0A else { throw GraphMigrationLedgerError.corrupted(url) }
        do { return try data.split(separator: 0x0A).map { try decoder.decode(GraphMigrationLedgerEntry.self, from: Data($0)) } } catch { throw GraphMigrationLedgerError.corrupted(url) }
    }

    static func writeHistory(_ entries: [GraphMigrationLedgerEntry], to url: URL) throws {
        var data = Data()
        for entry in entries { data.append(try encoder.encode(entry)); data.append(0x0A) }
        try writeDataAtomically(data, to: url)
    }

    static func writeAtomically<T: Encodable>(_ value: T, to url: URL) throws { try writeDataAtomically(encoder.encode(value), to: url) }
    static func writeDataAtomically(_ data: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            guard fm.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temporary) } else { try fm.moveItem(at: temporary, to: url) }
        } catch { try? fm.removeItem(at: temporary); throw error }
    }

    static func reconcileRemoteLocked(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws {
        if let remote = try remoteEntry(migrationID, version, configuration) { try storeRemoteObservation(remote, migrationID: migrationID, version: version, configuration: configuration) }
    }

    static func storeRemoteObservation(_ remote: GraphMigrationLedgerEntry, migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws {
        var p = try readProjection(migrationID: migrationID, version: version, configuration: configuration) ?? emptyProjection(migrationID: migrationID, version: version)
        let entries = try readHistory(at: historyURL(migrationID, version, configuration))
        if entries.contains(where: { isRemoteObservation($0) && $0.operationID == remote.operationID && $0.deviceID == remote.deviceID }) { return }
        if let observed = p.remoteObserved, remote.generation < observed.generation { return }
        if p.remoteObserved.map({ isOrderedAfter(remote, $0) }) ?? true { p.remoteObserved = remote }
        p.latestGeneration = max(p.latestGeneration, remote.generation); p.historyCount += 1
        try commit(p, entry: remote, migrationID: migrationID, version: version, configuration: configuration)
    }

    static func publishPendingLocked(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws {
        guard var p = try readProjection(migrationID: migrationID, version: version, configuration: configuration), let pending = p.pendingPublication else { return }
        let published = copy(pending, source: pending.source, observedAt: pending.observedAt, publishedAt: Date())
        let data = try encoder.encode(published)
        let key = logicalKey(migrationID, version, configuration)
        var lastError: Error?
        for _ in 0..<3 {
            do {
                var values = (kvs.object(forKey: kvsKey) as? [String: Any]) ?? [:]
                values[key] = data
                kvs.set(values, forKey: kvsKey)
#if DEBUG
                try faultForTesting?(.afterKVSWrite)
#endif
                guard kvs.synchronize(), let stored = (kvs.object(forKey: kvsKey) as? [String: Any])?[key] as? Data, stored == data else {
                    throw GraphMigrationLedgerError.publicationNotAccepted
                }
                p.lastPublished = published; p.pendingPublication = nil; p.publicationError = nil
                try commit(p, entry: nil, migrationID: migrationID, version: version, configuration: configuration)
                return
            } catch {
                lastError = error
            }
        }
        let error = lastError ?? GraphMigrationLedgerError.publicationNotAccepted
        p.publicationError = error.localizedDescription
        try commit(p, entry: nil, migrationID: migrationID, version: version, configuration: configuration)
        throw error
    }

    static func remoteEntry(_ migrationID: String, _ version: Int, _ configuration: GraphStoreConfiguration) throws -> GraphMigrationLedgerEntry? {
        let key = logicalKey(migrationID, version, configuration)
        if let values = kvs.object(forKey: kvsKey) as? [String: Any], let data = values[key] as? Data {
            let item = try decoder.decode(GraphMigrationLedgerEntry.self, from: data)
            guard item.schemaVersion == schemaVersion else { throw GraphMigrationLedgerError.unsupportedSchema(item.schemaVersion) }
            guard item.migrationID == migrationID, item.version == version, item.storeScope == GraphStoreScope(configuration: configuration).logicalKey else { throw GraphMigrationLedgerError.invalidRemoteProjection }
            return observedRemote(item)
        }
        guard configuration.environment == .production, let legacy = kvs.dictionary(forKey: legacyCloudKey(migrationID, version, configuration)), legacy["status"] as? String == GraphMigrationState.done.rawValue else { return nil }
        let date = legacy["completedAt"] as? Date ?? Date()
        let item = entry(for: GraphMigrationRecord(migrationID: migrationID, version: version, state: .done, startedAt: date, updatedAt: date), configuration: configuration, source: "legacyKVS", reason: .remoteDone, decisionSource: .remoteKVS)
        var p = try readProjection(migrationID: migrationID, version: version, configuration: configuration) ?? emptyProjection(migrationID: migrationID, version: version)
        p.pendingPublication = item
        try commit(p, entry: nil, migrationID: migrationID, version: version, configuration: configuration)
        try publishPendingLocked(migrationID: migrationID, version: version, configuration: configuration)
        return observedRemote(item, source: "legacyKVS")
    }

    static func observedRemote(_ item: GraphMigrationLedgerEntry, source: String = "remoteKVS") -> GraphMigrationLedgerEntry { copy(item, source: source, observedAt: Date(), publishedAt: item.publishedAt ?? item.date) }
    static func copy(_ item: GraphMigrationLedgerEntry, source: String, observedAt: Date?, publishedAt: Date?) -> GraphMigrationLedgerEntry { GraphMigrationLedgerEntry(schemaVersion: item.schemaVersion, operationID: item.operationID, generation: item.generation, migrationID: item.migrationID, version: item.version, state: item.state, phase: item.phase, requestedBy: item.requestedBy, deviceID: item.deviceID, appVersion: item.appVersion, graphModelVersion: item.graphModelVersion, backupReference: item.backupReference, previousOperationID: item.previousOperationID, decisionReason: item.decisionReason, decisionSource: item.decisionSource, source: source, date: item.date, errorDescription: item.errorDescription, storeScope: item.storeScope, observedAt: observedAt, publishedAt: publishedAt, resetTargets: item.resetTargets, requestReason: item.requestReason) }
    static func record(from item: GraphMigrationLedgerEntry) -> GraphMigrationRecord { GraphMigrationRecord(migrationID: item.migrationID, version: item.version, state: item.state, startedAt: item.date, updatedAt: item.date, errorDescription: item.errorDescription) }

    static func performRetention(in directory: URL) throws {
        guard Thread.isMainThread else { try enforceStoreRetention(in: directory); return }
        let semaphore = DispatchSemaphore(value: 0); let result = LedgerRetentionResult()
        retentionQueue.async { do { try enforceStoreRetention(in: directory) } catch { result.error = error }; semaphore.signal() }
        semaphore.wait(); if let error = result.error { throw error }
    }

    static func enforceStoreRetention(in directory: URL) throws {
        guard fm.fileExists(atPath: directory.path) else { return }
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]).filter { $0.pathExtension == "json" || $0.pathExtension == "jsonl" }
        var total = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        guard total > maxBytes else { return }
        var histories: [URL: [GraphMigrationLedgerEntry]] = [:]
        for url in files where url.lastPathComponent.hasSuffix(".history.jsonl") { histories[url] = try readHistory(at: url) }
        while total > maxBytes {
            guard let candidate = histories.filter({ $0.value.count > 2 }).min(by: { ($0.value.first?.date ?? .distantFuture) < ($1.value.first?.date ?? .distantFuture) }) else { break }
            var entries = candidate.value; let removed = entries.removeFirst(); let oldSize = (try? Data(contentsOf: candidate.key).count) ?? 0
            try writeHistory(entries, to: candidate.key); let newSize = (try? Data(contentsOf: candidate.key).count) ?? oldSize
            total -= max(0, oldSize - newSize); histories[candidate.key] = entries
            let projectionURL = candidate.key.deletingPathExtension().deletingPathExtension().appendingPathExtension("json")
            if var p = try? decoder.decode(LedgerProjection.self, from: Data(contentsOf: projectionURL)) { p.compactionSummary.include(removed); try writeAtomically(p, to: projectionURL) }
        }
    }

    static func entry(for record: GraphMigrationRecord, configuration: GraphStoreConfiguration, phase: String = "unknown", operationID: String = UUID().uuidString, generation: UInt64 = 0, backupReference: String? = nil, previousOperationID: String? = nil, source: String = "localLedger", requestedBy: GraphMigrationRequestedBy = .migrationManager, reason: GraphMigrationDecisionReason? = nil, decisionSource: GraphMigrationDecisionSource? = nil, resetTargets: [GraphMigrationResetTarget]? = nil, requestReason: String? = nil) -> GraphMigrationLedgerEntry {
        GraphMigrationLedgerEntry(schemaVersion: schemaVersion, operationID: operationID, generation: generation == 0 ? UInt64(Date().timeIntervalSince1970 * 1000) : generation, migrationID: record.migrationID, version: record.version, state: record.state, phase: phase, requestedBy: requestedBy, deviceID: installationIdentifier, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown", graphModelVersion: configuration.requiredGraphModelVersion, backupReference: backupReference, previousOperationID: previousOperationID, decisionReason: reason, decisionSource: decisionSource, source: source, date: record.updatedAt, errorDescription: record.errorDescription, storeScope: GraphStoreScope(configuration: configuration).logicalKey, observedAt: source == "remoteKVS" ? Date() : nil, publishedAt: nil, resetTargets: resetTargets, requestReason: requestReason)
    }

    /// Returns whether an entry represents a meaningful ledger transition.
    /// The projection still advances for every evaluation; repeated
    /// notRequired evaluations are deliberately kept out of append-only
    /// history unless their decision meaning changes.
    static func shouldAppendHistory(previous: GraphMigrationLedgerEntry?, current: GraphMigrationLedgerEntry) -> Bool {
        guard let previous else { return true }
        if current.state == .started { return true }
        guard previous.state == current.state else { return true }
        guard current.state == .notRequired else { return false }
        return previous.decisionReason != current.decisionReason
            || previous.decisionSource != current.decisionSource
            || previous.source != current.source
            || previous.errorDescription != current.errorDescription
    }

    static func isOrderedAfter(_ candidate: GraphMigrationLedgerEntry, _ reference: GraphMigrationLedgerEntry) -> Bool { candidate.generation != reference.generation ? candidate.generation > reference.generation : (candidate.deviceID != reference.deviceID ? candidate.deviceID > reference.deviceID : candidate.operationID > reference.operationID) }
    static func isRemoteObservation(_ entry: GraphMigrationLedgerEntry) -> Bool { entry.source == "remoteKVS" || entry.source == "legacyKVS" }
    static func logicalKey(_ migrationID: String, _ version: Int, _ configuration: GraphStoreConfiguration) -> String { "\(GraphStoreScope(configuration: configuration).logicalKey)|\(migrationID)|\(version)" }
    static func legacyCloudKey(_ migrationID: String, _ version: Int, _ configuration: GraphStoreConfiguration) -> String { "GraphMigration.done.\(hash([configuration.cloudKitContainerIdentifier ?? "local", configuration.name, migrationID, String(version)].joined(separator: "|")))" }
    static func recordURL(_ migrationID: String, _ version: Int, _ configuration: GraphStoreConfiguration) -> URL { ledgerDirectory(configuration).appendingPathComponent("\(safeComponent(migrationID))-v\(version).json") }
    static func historyURL(_ migrationID: String, _ version: Int, _ configuration: GraphStoreConfiguration) -> URL { ledgerDirectory(configuration).appendingPathComponent("\(safeComponent(migrationID))-v\(version).history.jsonl") }
    static func transactionURL(_ migrationID: String, _ version: Int, _ configuration: GraphStoreConfiguration) -> URL { ledgerDirectory(configuration).appendingPathComponent("\(safeComponent(migrationID))-v\(version).txn.json") }
    static func allURLs(_ migrationID: String, _ version: Int, _ configuration: GraphStoreConfiguration) -> [URL] { [recordURL(migrationID, version, configuration), historyURL(migrationID, version, configuration), transactionURL(migrationID, version, configuration)] }
    static func legacyRecordURL(_ migrationID: String, _ version: Int, _ configuration: GraphStoreConfiguration) -> URL { GraphMigrationManager.defaultBackupRoot(for: configuration).appendingPathComponent("ledger", isDirectory: true).appendingPathComponent("\(safeComponent(migrationID))-v\(version).json") }
    static func ledgerDirectory(_ configuration: GraphStoreConfiguration) -> URL { GraphMigrationManager.defaultBackupRoot(for: configuration).appendingPathComponent("ledger", isDirectory: true).appendingPathComponent(hash(GraphStoreScope(configuration: configuration).logicalKey), isDirectory: true) }
    static func hash(_ value: String) -> String { var result: UInt64 = 14_695_981_039_346_656_037; for byte in value.utf8 { result ^= UInt64(byte); result &*= 1_099_511_628_211 }; return String(format: "%016llx", result) }
    static func safeComponent(_ value: String) -> String { let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")); return String(value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : Character("_") }).prefix(80).description }
}

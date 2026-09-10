//
//  Graph+PersistentHistory.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 08/09/25.
//

import Foundation
import CoreData
import ObjectiveC.runtime

// MARK: - Token store on disk (Application Support or optional App Group)

private final class HistoryTokenStore {
    fileprivate enum LoadResult {
        case missing
        case loaded(NSPersistentHistoryToken)
        case invalid(Error)
    }

    private let url: URL
    private let storeKey: String
    private let backupKeyPrefix: String
    private let reportError: (Error) -> Void

    // MARK: - Local shadow backup (UserDefaults) for the *same installation*
    private let backupDefaults: UserDefaults

    fileprivate init(
        storeURL: URL,
        storeUUID: String?,
        configuration: GraphStoreConfiguration,
        reportError: @escaping (Error) -> Void
    ) {
        let storeKey = Self.stableStoreKey(storeURL: storeURL, storeUUID: storeUUID)
        self.storeKey = storeKey
        self.reportError = reportError
        let baseURL: URL
        let defaults: UserDefaults

        if let group = configuration.appGroupIdentifier,
           let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            baseURL = containerURL
                .appendingPathComponent("CosmicMind/Graph/PersistentHistory", isDirectory: true)
            defaults = UserDefaults(suiteName: group) ?? .standard
        } else {
            baseURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent(".GraphEvo/PersistentHistory", isDirectory: true)
            defaults = .standard
        }

        self.url = baseURL.appendingPathComponent("history-\(storeKey).token", isDirectory: false)
        self.backupKeyPrefix = "GraphEvo.historyToken.backup.\(storeKey)"
        self.backupDefaults = defaults
        try? FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    fileprivate var tokenURL: URL { url }

    fileprivate func matches(storeURL: URL, storeUUID: String?) -> Bool {
        storeKey == Self.stableStoreKey(storeURL: storeURL, storeUUID: storeUUID)
    }

    fileprivate static func stableStoreKey(storeURL: URL, storeUUID: String?) -> String {
        let source = storeUUID ?? storeURL.standardizedFileURL.path
        // FNV-1a provides a short deterministic filename without exposing the
        // full path and without introducing a cryptography dependency.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private func backupKey() -> String {
        backupKeyPrefix
    }

    /// Loads the token from the UserDefaults backup (same installation).
    func loadBackup() -> NSPersistentHistoryToken? {
        switch loadBackupResult() {
        case .loaded(let token): return token
        case .missing, .invalid: return nil
        }
    }

    fileprivate func loadBackupResult() -> LoadResult {
        guard let data = backupDefaults.data(forKey: backupKey()) else { return .missing }
        do {
            guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data) else {
                return .invalid(NSError(domain: "GraphEvo.PersistentHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: "Persistent History backup contained no token."]))
            }
            return .loaded(token)
        } catch {
            return .invalid(error)
        }
    }

    /// Also saves the token to the UserDefaults backup.
    func saveBackup(_ token: NSPersistentHistoryToken) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            backupDefaults.set(data, forKey: backupKey())
        }
    }

    /// Clears the UserDefaults backup.
    func clearBackup() {
        backupDefaults.removeObject(forKey: backupKey())
    }

    func load() -> NSPersistentHistoryToken? {
        switch loadResult() {
        case .loaded(let token): return token
        case .missing, .invalid: return nil
        }
    }

    fileprivate func loadResult() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data) else {
                return .invalid(NSError(domain: "GraphEvo.PersistentHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: "Persistent History file contained no token."]))
            }
            return .loaded(token)
        } catch {
            return .invalid(error)
        }
    }

    func save(_ token: NSPersistentHistoryToken) {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            try data.write(to: url, options: [.atomic])
            // Keep a local backup as well (fallback namespace).
            self.saveBackup(token)
        } catch {
            reportError(error)
        }
    }

    func clear() {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            reportError(error)
        }
        // Clear the fallback backup as well.
        self.clearBackup()
    }

    func bootstrapTokenToCurrentHead(using context: NSManagedObjectContext) {
        context.performAndWait {
            // Request history from the "beginning" without filtering: transactions only.
            let req = NSPersistentHistoryChangeRequest.fetchHistory(after: nil as NSPersistentHistoryToken?)
            req.resultType = .transactionsOnly
            // ⚠️ Do not set req.fetchRequest (no SQL sort/limit on "timestamp").

            do {
                guard let result = try context.execute(req) as? NSPersistentHistoryResult else {return}

                // May be NSNull when there are no transactions.
                guard let txs = result.result as? [NSPersistentHistoryTransaction], !txs.isEmpty else {return}

                // Sort in memory by timestamp (or simply take the latest date).
                if let newest = txs.max(by: { lhs, rhs in lhs.timestamp < rhs.timestamp }) {
                    self.save(newest.token)
                }
            } catch {
            self.reportError(error)
            }
        }
    }
    
#if DEBUG
    // DEBUG: overwrite the token file with invalid data to simulate corruption.
    func debugCorruptOnDisk() {
        let junk = Data("not-a-token".utf8)
        try? junk.write(to: url, options: [.atomic])
        // Do not update _ph_lastToken here: this simulates a token corrupted on disk.
    }

    // DEBUG: verify that the token file exists on disk.
    func debugTokenFileExists() -> Bool {
        return FileManager.default.fileExists(atPath: url.path)
    }
#endif
}

// MARK: - Associated storage for Graph (no stored properties in extensions)

private enum _GraphPHKeys {
    // Use stable addressable keys for objc associated objects
    static var lastTokenKey: UInt8 = 0
    static var tokenStoreKey: UInt8 = 0
    static var bootstrapFlagKey: UInt8 = 0
    static var coldStartFlagKey: UInt8 = 0
    static var coordinatorKey: UInt8 = 0
}

private extension Graph {
    var _ph_lastToken: NSPersistentHistoryToken? {
        get { objc_getAssociatedObject(self, &_GraphPHKeys.lastTokenKey) as? NSPersistentHistoryToken }
        set { objc_setAssociatedObject(self, &_GraphPHKeys.lastTokenKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var _ph_tokenStore: HistoryTokenStore {
        let storeURL = runtimeStoreURL ?? configuration.resolvedStoreURL
        let storeUUID = _ph_currentStoreUUID()
        if let existing = objc_getAssociatedObject(self, &_GraphPHKeys.tokenStoreKey) as? HistoryTokenStore {
            if existing.matches(storeURL: storeURL, storeUUID: storeUUID) {
                return existing
            }
            // The Graph instance was rebound to a different store identity.
            // Never carry the in-memory token across that boundary.
            _ph_lastToken = nil
        }
        let store = HistoryTokenStore(
            storeURL: storeURL,
            storeUUID: storeUUID,
            configuration: configuration,
            reportError: { [weak self] error in self?.emit(.warning(.persistentHistoryTokenStore(underlying: error))) }
        )
        objc_setAssociatedObject(self, &_GraphPHKeys.tokenStoreKey, store, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return store
    }

    var _ph_remoteChangeCoordinator: RemoteChangeCoordinator {
        if let coordinator = objc_getAssociatedObject(self, &_GraphPHKeys.coordinatorKey) as? RemoteChangeCoordinator {
            return coordinator
        }
        let coordinator = RemoteChangeCoordinator(graph: self)
        objc_setAssociatedObject(self, &_GraphPHKeys.coordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return coordinator
    }

    /// If true, when no token is found (fresh install / cold start), we bootstrap the token to the current head
    /// instead of replaying the entire history. Default: false (so that history replay rebuilds local state and delegati fire).
    var _ph_bootstrapToHeadOnColdStart: Bool {
        get { (objc_getAssociatedObject(self, &_GraphPHKeys.bootstrapFlagKey) as? NSNumber)?.boolValue ?? false }
        set { objc_setAssociatedObject(self, &_GraphPHKeys.bootstrapFlagKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Session flag: true on the first run (a "cold" app after install/launch), false afterwards.
    var _ph_isColdStartSession: Bool {
        get { (objc_getAssociatedObject(self, &_GraphPHKeys.coldStartFlagKey) as? NSNumber)?.boolValue ?? true }
        set { objc_setAssociatedObject(self, &_GraphPHKeys.coldStartFlagKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Prova ad ottenere lo store UUID corrente dal PSC
    func _ph_currentStoreUUID() -> String? {
        guard let psc = persistentContainer?.persistentStoreCoordinator else { return nil }
        for store in psc.persistentStores {
            let meta = psc.metadata(for: store)
            if let uuid = meta[NSStoreUUIDKey] as? String {
                return uuid
            }
        }
        return nil
    }

    /// Marks startup and determines whether this is a cold-start session (this installation only).
    func _ph_markLaunchAndDetectColdStart() {
        let defaults = UserDefaults.standard
        let key = "GraphEvo.hasLaunchedOnce"
        let hasLaunched = defaults.bool(forKey: key)
        _ph_isColdStartSession = !hasLaunched
        if !hasLaunched {
            defaults.set(true, forKey: key)
        }
    }

    // MARK: - Persistent History configuration (tunable)
    /// Skip local writes authored by this device to avoid double callbacks on the originator device.
    private var _ph_filterLocalWrites: Bool { true }
    /// The author used by local contexts when _ph_filterLocalWrites is enabled.
    private var _ph_appAuthor: String { GraphDeviceAuthor.current() }
}

// MARK: - Entry point: remote change → process history → post custom notification

@objc
internal extension Graph {
    /// Chiamato dall'observer registrato in Context.swift
    func handlePersistentStoreRemoteChange(_ notification: Notification) {
        // Lazy load dal disco alla primissima occorrenza
        _ph_loadPersistedTokenIfNeeded()

            // If the token is still nil, choose the strategy for this session.
        if _ph_lastToken == nil {
            // Warm session → restore from backup or bootstrap to head.
            _ph_restoreFromBackupOrBootstrapIfWarmSession()
            // For a cold start, the helper does nothing and allows the full replay.
        }

        // The coordinator owns ordering, coalescing and delivery.
        _ph_remoteChangeCoordinator.enqueue()
    }
}

// MARK: - Launch-time bootstrap (called after container is ready)

@objc
public extension Graph {
    @objc
    func ph_prepareOnLaunchAfterContainerReady() {
        _ph_markLaunchAndDetectColdStart()
        // Load token from disk (if any)
        _ph_loadPersistedTokenIfNeeded()
        // Warm session and missing token → try the local UserDefaults backup.
        if _ph_lastToken == nil, _ph_isColdStartSession == false {
            _ph_restoreFromBackupOrBootstrapIfWarmSession()
        }

        // If there is no token we purposefully avoid bootstrapping here.
        // The first remote notification will replay history from the beginning once,
        // emit delegate callbacks, and advance the token.
        if _ph_lastToken == nil {
        }
    }
}

internal extension Graph {
    func processPersistentHistoryForRemoteChange() {
        _ph_remoteChangeCoordinator.enqueue()
    }

    /// Processes one history snapshot. The completion is called after the
    /// merged notification has been delivered to existing Watch observers.
    func processPersistentHistoryBatch(completion: @escaping (Bool) -> Void) {
        // A remote purge invalidates the local object graph and history token.
        // The application is responsible for reopening the store afterwards;
        // do not publish the purge's remote notification as normal data.
        guard !isCloudPurgeInProgress else { completion(false); return }
        guard let container = persistentContainer else { completion(false); return }
        let psc = container.persistentStoreCoordinator
        guard !psc.persistentStores.isEmpty else { completion(false); return }

        let bg = container.newBackgroundContext()
        bg.transactionAuthor = GraphDeviceAuthor.current()
        bg.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        bg.perform { [weak self] in
            guard let self = self else { completion(false); return }

            // Request: all transactions after the latest known token.
            let token: NSPersistentHistoryToken? = self._ph_lastToken
            self.watchEventCoordinator?.prepareCloudDelivery(startingAfter: token)
            let request: NSPersistentHistoryChangeRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: token)

            // Note: no SQL filter on `storeID`.
            // Some configurations do not expose `storeID` on the TRANSACTION entity and crash.
            // If multi-store filtering is needed, do it *after* the in-memory fetch.

            do {
                guard let result = try bg.execute(request) as? NSPersistentHistoryResult,
                      let transactions = result.result as? [NSPersistentHistoryTransaction],
                      !transactions.isEmpty else {
                    completion(false)
                    return
                }

                let orderedTransactions = transactions.enumerated().sorted { lhs, rhs in
                    if lhs.element.transactionNumber != rhs.element.transactionNumber {
                        return lhs.element.transactionNumber < rhs.element.transactionNumber
                    }
                    if lhs.element.timestamp != rhs.element.timestamp {
                        return lhs.element.timestamp < rhs.element.timestamp
                    }
                    return lhs.offset < rhs.offset
                }.map(\.element)


                // Collect ObjectIDs by change type.
                var insertedIDs: [NSManagedObjectID] = []
                var updatedIDs:  [NSManagedObjectID] = []
                var deletedIDs:  [NSManagedObjectID] = []
                var orderedRecords: [GraphWatchRemoteRecord] = []

                for (transactionIndex, tx) in orderedTransactions.enumerated() {
                    // 🔒 Author-filter hardening: avoid a duplicate callback on the originating device.
                    if _ph_filterLocalWrites {
                        if let author = tx.author {
                            if author == _ph_appAuthor {
                                continue
                            }
                        } else {
                            // author == nil → likely saved by a context without a transactionAuthor.
                            // This can cause a duplicate callback on A after token bootstrap.
                            self.emit(.warning(.persistentHistoryMissingTransactionAuthor))
                        }
                    }

                    let changes = (tx.changes ?? []).enumerated().sorted { lhs, rhs in
                        let leftType = lhs.element.changeType.rawValue
                        let rightType = rhs.element.changeType.rawValue
                        if leftType != rightType { return leftType < rightType }
                        let leftURI = lhs.element.changedObjectID.uriRepresentation().absoluteString
                        let rightURI = rhs.element.changedObjectID.uriRepresentation().absoluteString
                        if leftURI != rightURI { return leftURI < rightURI }
                        return lhs.offset < rhs.offset
                    }.map(\.element)

                    changes.enumerated().forEach { changeIndex, change in
                        switch change.changeType {
                        case .insert:
                            insertedIDs.append(change.changedObjectID)
                            orderedRecords.append(GraphWatchRemoteRecord(objectID: change.changedObjectID, operation: .insert, transactionIndex: transactionIndex, changeIndex: changeIndex))
                        case .update:
                            updatedIDs.append(change.changedObjectID)
                            orderedRecords.append(GraphWatchRemoteRecord(objectID: change.changedObjectID, operation: .update, transactionIndex: transactionIndex, changeIndex: changeIndex))
                        case .delete:
                            deletedIDs.append(change.changedObjectID)
                            orderedRecords.append(GraphWatchRemoteRecord(objectID: change.changedObjectID, operation: .delete, transactionIndex: transactionIndex, changeIndex: changeIndex))
                        @unknown default: break
                        }
                    }
                }

                // Nothing to process; return.
                if insertedIDs.isEmpty, updatedIDs.isEmpty, deletedIDs.isEmpty {
                    self.persistPersistentHistoryToken(orderedTransactions.last?.token)
                    completion(true)
                    return
                }

                // Build userInfo in the format expected by Watch:
                // an NSSet of NSManagedObjectID values, which Watch converts through its context.
                let userInfo: [AnyHashable: Any] = [
                    NSInsertedObjectsKey: NSSet(array: insertedIDs),
                    NSUpdatedObjectsKey:  NSSet(array: updatedIDs),
                    NSDeletedObjectsKey:  NSSet(array: deletedIDs),
                    GraphEvoOrderedRemoteChangesKey: orderedRecords
                ]

                // Core Data's merge API expects object-ID keys, while the
                // legacy Watch API expects the historical object keys. Keep
                // those payloads separate so neither contract is changed.
                let mergeUserInfo: [AnyHashable: Any] = [
                    NSInsertedObjectIDsKey: NSSet(array: insertedIDs),
                    NSUpdatedObjectIDsKey:  NSSet(array: updatedIDs),
                    NSDeletedObjectIDsKey:  NSSet(array: deletedIDs)
                ]

                guard !self.isCloudPurgeInProgress else {
                    completion(false)
                    return
                }

                // Notify GraphMigrationManager.handleRemoteEntityChanges before posting the notification.
                GraphMigrationManager.handleRemoteEntityChanges(
                    configuration: self.configuration,
                    graph: self,
                    inserted: insertedIDs,
                    updated: updatedIDs
                )
                // Merge synchronously on the context's queue before posting to
                // Watch observers. This is the consistency barrier missing from
                // the previous implementation.
                let targetMOC = self.managedObjectContext ?? container.viewContext
                GraphWatchLocalCapture.whileSuppressed(targetMOC) {
                    targetMOC.performAndWait {
                        let mergedNotification = Notification(
                            name: .GraphEvoSimulatedRemoteChange,
                            object: targetMOC,
                            userInfo: mergeUserInfo
                        )
                        targetMOC.mergeChanges(fromContextDidSave: mergedNotification)
                    }
                }

                // Persist the token only after the observed context has been
                // merged successfully. This prevents losing a batch when the
                // merge path fails before delivery.
                self.persistPersistentHistoryToken(orderedTransactions.last?.token)

                // Post on main (watchers are generally connected to UI-owned
                // contexts and existing clients expect main-thread delivery).
                DispatchQueue.main.async {
                    guard !self.isCloudPurgeInProgress else {
                        completion(false)
                        return
                    }
                    var deliveredUserInfo = userInfo
                    deliveredUserInfo[GraphEvoRemoteChangeAlreadyMergedKey] = true
                    NotificationCenter.default.post(
                        name: .GraphEvoSimulatedRemoteChange,
                        object: targetMOC,
                        userInfo: deliveredUserInfo
                    )
                    completion(true)
                }
            } catch {
                let nsError = error as NSError
                // 134501: token references a store that no longer exists.
                if self._ph_isPersistentHistoryError(134501, in: nsError) {
                    self._ph_recoverPersistentHistoryToken(
                        reason: .storeUnavailable,
                        underlying: error,
                        using: nil
                    )
                    completion(false)
                    return
                }
                // 134301: the token is older than the retained history window.
                if self._ph_isPersistentHistoryError(134301, in: nsError) {
                    self._ph_recoverPersistentHistoryToken(
                        reason: .expiredToken,
                        underlying: error,
                        using: nil
                    )
                    completion(false)
                    return
                }
                debugPrint("[PH][DEBUG] Error processing remote change: \(error)")
                self.emit(.error(.persistentHistory(underlying: error)))
                completion(false)
                }
        }
    }
}

private extension Graph {
    func _ph_loadPersistedTokenIfNeeded() {
        let tokenStore = _ph_tokenStore
        guard _ph_lastToken == nil else { return }
        switch tokenStore.loadResult() {
        case .missing:
            return
        case .loaded(let token):
            _ph_lastToken = token
        case .invalid(let error):
            _ph_recoverPersistentHistoryToken(
                reason: .corruptedToken,
                underlying: error,
                using: nil
            )
        }
    }

    /// Invalidates every local representation of the token before selecting
    /// a new recovery point. Bootstrapping the current history head is safe
    /// after a rebuilt store and prevents the coordinator from retrying the
    /// invalid token on every remote-change notification.
    func _ph_recoverPersistentHistoryToken(
        reason: GraphPersistentHistoryRecoveryReason,
        underlying: Error?,
        using context: NSManagedObjectContext?
    ) {
        _ph_lastToken = nil
        _ph_tokenStore.clear()
        emit(.warning(.persistentHistoryRecovery(reason: reason, underlying: underlying)))

        let recoveryContext: NSManagedObjectContext
        if let context {
            recoveryContext = context
        } else if let container = persistentContainer {
            recoveryContext = container.newBackgroundContext()
        } else {
            return
        }

        _ph_tokenStore.bootstrapTokenToCurrentHead(using: recoveryContext)
        _ph_lastToken = _ph_tokenStore.load()
        _ph_isColdStartSession = false
    }

    func _ph_isPersistentHistoryError(_ code: Int, in error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == code { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return _ph_isPersistentHistoryError(code, in: underlying)
        }
        return false
    }

    /// If the token is missing *in a warm session*, try to restore it from backup.
    /// Without a backup, bootstrap to the head to avoid replay and duplicate callbacks.
    func _ph_restoreFromBackupOrBootstrapIfWarmSession() {
        // A token already in memory needs no work.
        guard _ph_lastToken == nil else { return }

        // For a true cold-start session, allow the full replay.
        guard _ph_isColdStartSession == false else {
            return
        }

        // 1) Try the UserDefaults backup first (same installation / warm session).
        switch _ph_tokenStore.loadBackupResult() {
        case .loaded(let backup):
            _ph_lastToken = backup
            _ph_isColdStartSession = false
            return
        case .invalid(let error):
            _ph_recoverPersistentHistoryToken(
                reason: .corruptedToken,
                underlying: error,
                using: nil
            )
            return
        case .missing:
            break
        }

        // 2) No backup available → bootstrap to the head to avoid a full replay.
        if let container = persistentContainer {
            let bg = container.newBackgroundContext()
            bg.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            bg.transactionAuthor = GraphDeviceAuthor.current()

            _ph_tokenStore.bootstrapTokenToCurrentHead(using: bg)

            if let head = _ph_tokenStore.load() {
                _ph_lastToken = head
                _ph_isColdStartSession = false
            }
        }
    }

    func persistPersistentHistoryToken(_ token: NSPersistentHistoryToken?) {
        guard let token else { return }
        _ph_lastToken = token
        _ph_tokenStore.save(token)
        _ph_tokenStore.saveBackup(token)
        _ph_isColdStartSession = false
    }

}

internal extension Graph {
    func ph_processingTokenForWatchDelivery() -> NSPersistentHistoryToken? {
        _ph_lastToken ?? _ph_tokenStore.load()
    }
}

#if DEBUG
@objc
public extension Graph {
    /// Clears the token in memory and on disk.
    func ph_debug_clearToken() {
        _ph_lastToken = nil
        _ph_tokenStore.clear()
    }

    /// Returns true when a token exists in memory or on disk.
    func ph_debug_lastTokenExists() -> Bool {
        if _ph_lastToken != nil {
            return true
        }
        return _ph_tokenStore.load() != nil
    }

    /// Intentionally corrupts the token on disk (to test recovery).
    func ph_debug_corruptTokenOnDisk() {
        _ph_tokenStore.debugCorruptOnDisk()
    }

    /// Returns the per-store token URL for diagnostics and tests.
    func ph_debug_tokenStorageURL() -> URL {
        _ph_tokenStore.tokenURL
    }

    /// Prints the configured author and current context name.
    func ph_debug_printAuthorAndContext() {
        let author = _ph_appAuthor
        let ctxName = (managedObjectContext?.name) ?? "nil"
        print("[PH][DEBUG] author=\(author) viewContext.name=\(ctxName)")
    }

    /// Prints a compact token state (memory/disk).
    func ph_debug_printTokenStatus() {
        let mem = (_ph_lastToken != nil) ? "mem=YES" : "mem=NO"
        let disk = (_ph_tokenStore.load() != nil) ? "disk=YES" : "disk=NO"
        print("[PH][DEBUG] token: \(mem), \(disk)")
    }

    /// DEBUG: enables or disables token bootstrap to the head on cold start.
    @objc func ph_debug_setBootstrapOnColdStart(_ enabled: Bool) {
        _ph_bootstrapToHeadOnColdStart = enabled
    }

    /// DEBUG/test seam for exercising token-error classification without
    /// manufacturing a private Core Data token or contacting CloudKit.
    @objc func ph_debug_recoverFromPersistentHistoryError(_ error: NSError) -> Bool {
        if _ph_isPersistentHistoryError(134301, in: error) {
            _ph_recoverPersistentHistoryToken(reason: .expiredToken, underlying: error, using: nil)
            return true
        }
        if _ph_isPersistentHistoryError(134501, in: error) {
            _ph_recoverPersistentHistoryToken(reason: .storeUnavailable, underlying: error, using: nil)
            return true
        }
        return false
    }
}
#endif

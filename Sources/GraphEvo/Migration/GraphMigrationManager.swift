//
//  GraphMigrationManager.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 11/09/25.
//

import Foundation
import CoreData

/// Manages the migrations of the Graph store.
/// This becomes the official system for all future migrations.
public final class GraphMigrationManager {

    public enum GraphLifecyclePhase {
        case preInit
        case postInit
        case postMigration
        case ready
    }

    /// Default base folder where migrations can store their backups
    /// (e.g. SQLite stores, baseline.zip, etc.).
    ///
    /// By convention this is:
    ///   <storeDir>/../migrationBackups/
    /// where `storeDir` is the directory that contains the resolved store URL.
    public static func defaultBackupRoot(for configuration: GraphStoreConfiguration) -> URL {
        let storeDir = configuration.resolvedStoreURL.deletingLastPathComponent()
        return storeDir
            .deletingLastPathComponent()
            .appendingPathComponent("migrationBackups", isDirectory: true)
    }

    /// Stores lifecycle phase callbacks. The callback receives the store configuration and an optional Graph context.
    /// Some phases may not provide a Graph instance.
    private static var callbacks: [GraphLifecyclePhase: [(GraphStoreConfiguration?, Graph?) -> Void]] = [:]

    /// Stores all registered migrations in order.
    private static var migrations: [GraphMigration] = []
    /// Serializes the process-wide migration state. The public API predates
    /// Swift concurrency, so a lock keeps registration and lifecycle calls
    /// safe without forcing an async source-breaking API change.
    private static let stateLock = NSRecursiveLock()
    /// A phase remains in flight until its migration completion is received.
    /// Later phases are queued instead of overwriting the active index/context.
    private static var coordinators: [GraphStoreScope: StoreMigrationCoordinator] = [:]
    private static var observedStores: [GraphStoreScope: (configuration: GraphStoreConfiguration, count: Int)] = [:]
    private static var kvsObserver: NSObjectProtocol?

#if DEBUG
    internal static var coordinatorCountForTesting: Int { stateLock.lock(); defer { stateLock.unlock() }; return coordinators.count }
    internal static var observedStoreCountForTesting: Int { stateLock.lock(); defer { stateLock.unlock() }; return observedStores.count }
    /// Resets process-wide migration state for isolated test cases.
    ///
    /// Applications should register migrations once during startup and must not
    /// call this method. It is compiled only in debug builds so test isolation
    /// cannot become part of the production API surface.
    internal static func resetForTesting() {
        stateLock.lock()
        defer { stateLock.unlock() }
        callbacks.removeAll()
        migrations.removeAll()
        coordinators.removeAll()
        observedStores.removeAll()
        if let kvsObserver { NotificationCenter.default.removeObserver(kvsObserver) }
        kvsObserver = nil
        GraphMigrationLedger.resetKVSStoreForTesting()
        GraphMigrationLedger.setFaultForTesting(nil)
    }
#endif

    public static func record(
        for migration: GraphMigration,
        configuration: GraphStoreConfiguration
    ) -> GraphMigrationRecord? {
        do { return try recordThrowing(for: migration, configuration: configuration) }
        catch {
            GraphMigrationLogger.log(migrationID: migration.id, level: .error, event: "migration_record_read_failed", message: error.localizedDescription, configuration: configuration)
            return nil
        }
    }

    /// Returns the current record and propagates ledger or configuration errors.
    public static func recordThrowing(
        for migration: GraphMigration,
        configuration: GraphStoreConfiguration
    ) throws -> GraphMigrationRecord? {
        let resolvedConfiguration: GraphStoreConfiguration
        resolvedConfiguration = try normalizedConfigurationThrowing(configuration)
        return try GraphMigrationLedger.reconciledRecordThrowing(
            migrationID: migration.id,
            version: migration.version,
            synchronization: migration.completionSynchronization,
            configuration: resolvedConfiguration
        )
    }

    /// Adopts a completion recorded by a pre-ledger application marker.
    ///
    /// This is intentionally separate from `notRequired`: the migration did
    /// run in the past, so the legacy migration identity must remain visible
    /// to later migrations (for example a CloudKit replay). The operation is
    /// idempotent and does not rewrite an existing completed record.
    public static func adoptLegacyCompletion(
        _ migration: GraphMigration,
        configuration: GraphStoreConfiguration,
        reason: String = "legacy compatibility bootstrap"
    ) throws {
        let configuration = try normalizedConfigurationThrowing(configuration)
        if try recordThrowing(for: migration, configuration: configuration)?.state == .done {
            return
        }
        _ = try GraphMigrationLedger.markDone(
            migrationID: migration.id,
            version: migration.version,
            synchronization: migration.completionSynchronization,
            configuration: configuration,
            phase: "compatibilityBootstrap",
            operationID: "legacy-adoption-\(migration.id)",
            requestedBy: .recovery,
            now: Date()
        )
        GraphMigrationLogger.log(
            migrationID: migration.id,
            level: .info,
            event: "legacy_completion_adopted",
            message: reason,
            configuration: configuration
        )
    }

    public static func resetRecord(
        for migration: GraphMigration,
        configuration: GraphStoreConfiguration
    ) throws {
        let configuration = try normalizedConfigurationThrowing(configuration)
        try GraphMigrationLedger.reset(
            migrationID: migration.id,
            version: migration.version,
            synchronization: migration.completionSynchronization,
            configuration: configuration
        )
    }

    public static func resetRecord(
        for migration: GraphMigration,
        configuration: GraphStoreConfiguration,
        targets: [GraphMigrationResetTarget],
        requestedBy: GraphMigrationRequestedBy,
        reason: String
    ) throws {
        let configuration = try normalizedConfigurationThrowing(configuration)
        try GraphMigrationLedger.reset(
            migrationID: migration.id,
            version: migration.version,
            configuration: configuration,
            targets: Set(targets),
            requestedBy: requestedBy,
            reason: reason
        )
    }

    /// Resets the local and/or shared completion projection without deleting
    /// the append-only ledger history.
    public static func resetRecord(
        for migration: GraphMigration,
        configuration: GraphStoreConfiguration,
        target: GraphMigrationResetTarget
    ) throws {
        let configuration = try normalizedConfigurationThrowing(configuration)
        try GraphMigrationLedger.reset(
            migrationID: migration.id,
            version: migration.version,
            synchronization: migration.completionSynchronization,
            configuration: configuration,
            target: target
        )
    }

    /// Queues a one-shot local force request. The request is consumed when the
    /// next attempt for this store starts and is never published to KVS.
    public static func forceMigration(
        _ migration: GraphMigration,
        configuration: GraphStoreConfiguration,
        reason: String = "manual force"
    ) throws {
        try forceMigration(migration, configuration: configuration, requestedBy: .user, reason: reason)
    }

    public static func forceMigration(
        _ migration: GraphMigration,
        configuration: GraphStoreConfiguration,
        requestedBy: GraphMigrationRequestedBy,
        reason: String
    ) throws {
        let configuration = try normalizedConfigurationThrowing(configuration)
        try GraphMigrationLedger.requestForce(
            migrationID: migration.id,
            version: migration.version,
            configuration: configuration,
            requestedBy: requestedBy,
            reason: reason
        )
    }

    /// Registers a callback to be executed during a given lifecycle phase.
    /// The callback receives the store configuration and an optional Graph context. Some phases may not provide a Graph instance.
    public static func registerCallback(for phase: GraphLifecyclePhase, _ callback: @escaping (GraphStoreConfiguration?, Graph?) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if callbacks[phase] != nil {
            callbacks[phase]?.append(callback)
        } else {
            callbacks[phase] = [callback]
        }
    }

    /// Registers a migration to be executed at lifecycle phases.
    public static func registerMigration(_ migration: GraphMigration) {
        stateLock.lock()
        defer { stateLock.unlock() }
        // Ensure we do not register the same migration twice (by id).
        guard !migrations.contains(where: { $0.id == migration.id }) else { return }
        migrations.append(migration)
    }

    /// Registers multiple migrations to be executed at lifecycle phases.
    public static func registerMigrations(_ migrations: [GraphMigration]) {
        migrations.forEach { registerMigration($0) }
    }

    static func registeredMigrationsSnapshot() -> [GraphMigration] {
        stateLock.lock(); defer { stateLock.unlock() }
        return migrations
    }

    static func callbacksSnapshot(for phase: GraphLifecyclePhase) -> [(GraphStoreConfiguration?, Graph?) -> Void] {
        stateLock.lock(); defer { stateLock.unlock() }
        return callbacks[phase] ?? []
    }

    static func discardCoordinator(_ coordinator: StoreMigrationCoordinator) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if coordinators[coordinator.scope] === coordinator {
            coordinators.removeValue(forKey: coordinator.scope)
        }
    }

    static func registerKVSObservation(configuration: GraphStoreConfiguration) {
        let resolvedConfiguration: GraphStoreConfiguration
        do { resolvedConfiguration = try normalizedConfigurationThrowing(configuration) }
        catch {
            GraphMigrationLogger.log(migrationID: "GraphMigrationManager", level: .error, event: "migration_kvs_observer_configuration_failed", message: error.localizedDescription, configuration: configuration)
            return
        }
        let scope = GraphStoreScope(configuration: resolvedConfiguration)
        stateLock.lock()
        let current = observedStores[scope]
        observedStores[scope] = (resolvedConfiguration, (current?.count ?? 0) + 1)
        if kvsObserver == nil {
            let observation = GraphMigrationLedger.kvsObservation
            kvsObserver = NotificationCenter.default.addObserver(forName: observation.name, object: observation.object, queue: nil) { _ in
                reconcileObservedStores()
            }
        }
        stateLock.unlock()
        GraphMigrationLedger.synchronizeKVS()
        reconcileObservedStores()
    }

    static func unregisterKVSObservation(configuration: GraphStoreConfiguration) {
        let scope = GraphStoreScope(configuration: normalizedConfiguration(configuration))
        stateLock.lock(); defer { stateLock.unlock() }
        guard let current = observedStores[scope] else { return }
        if current.count > 1 { observedStores[scope] = (current.configuration, current.count - 1) }
        else { observedStores.removeValue(forKey: scope) }
        if observedStores.isEmpty, let kvsObserver { NotificationCenter.default.removeObserver(kvsObserver); self.kvsObserver = nil }
    }

    private static func reconcileObservedStores() {
        stateLock.lock(); let stores = observedStores.values.map(\.configuration); let migrations = self.migrations; stateLock.unlock()
        for configuration in stores {
            for migration in migrations where migration.completionSynchronization == .localAndICloudKeyValueStore {
                do {
                    try GraphMigrationLedger.reconcileRemoteObservation(
                        migrationID: migration.id,
                        version: migration.version,
                        synchronization: migration.completionSynchronization,
                        configuration: configuration
                    )
                } catch {
                    GraphMigrationLogger.log(
                        migrationID: migration.id,
                        level: .error,
                        event: "migration_kvs_observation_failed",
                        message: error.localizedDescription,
                        configuration: configuration
                    )
                }
            }
        }
    }

    public static func history(
        for migration: GraphMigration,
        configuration: GraphStoreConfiguration
    ) throws -> [GraphMigrationLedgerEntry] {
        let configuration = try normalizedConfigurationThrowing(configuration)
        return try GraphMigrationLedger.history(
            migrationID: migration.id,
            version: migration.version,
            configuration: configuration
        )
    }

    public static func stateSnapshot(
        for migration: GraphMigration,
        configuration: GraphStoreConfiguration
    ) throws -> GraphMigrationStateSnapshot {
        let configuration = try normalizedConfigurationThrowing(configuration)
        return try GraphMigrationLedger.stateSnapshot(
            migrationID: migration.id,
            version: migration.version,
            configuration: configuration
        )
    }

    static func normalizedConfiguration(_ configuration: GraphStoreConfiguration) -> GraphStoreConfiguration {
        (try? normalizedConfigurationThrowing(configuration)) ?? configuration
    }

    static func normalizedConfigurationThrowing(_ configuration: GraphStoreConfiguration) throws -> GraphStoreConfiguration {
        var result = configuration
        result.cloudKitContainerIdentifier = Graph.resolvedCloudKitContainerIdentifier(
            configuration: configuration,
            runtimeOverride: Graph.cloudKitContainerIdentifier
        )
        let environment = try GraphStoreEnvironmentResolver.resolve(configuration: result).get()
        result.setResolvedEnvironment(environment)
        return result
    }

    /// Executes all callbacks and registered migrations for the specified lifecycle phase, running migrations in sequence.
    /// - Parameters:
    ///   - phase: The lifecycle phase being handled.
    ///   - configuration: The Core Data store configuration this phase refers to.
    ///   - graph: Optional Graph instance (may be nil in early phases).
    public static func handlePhase(_ phase: GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?) {
        handlePhase(phase, configuration: configuration, graph: graph, completion: nil)
    }

    /// Handles a lifecycle phase and invokes `completion` after every
    /// migration in that phase has reached a terminal result. Existing callers
    /// can keep using the synchronous-looking overload above; the completion
    /// overload makes asynchronous lifecycle composition explicit.
    public static func handlePhase(
        _ phase: GraphLifecyclePhase,
        configuration: GraphStoreConfiguration?,
        graph: Graph?,
        completion: (() -> Void)?
    ) {
        guard let inputConfiguration = configuration else {
            return
        }
        let configuration = normalizedConfiguration(inputConfiguration)
        let scope = GraphStoreScope(configuration: configuration)
        stateLock.lock()
        let coordinator = coordinators[scope] ?? {
            let value = StoreMigrationCoordinator(scope: scope)
            coordinators[scope] = value
            return value
        }()
        stateLock.unlock()
        coordinator.handle(phase, configuration: configuration, graph: graph, completion: completion)
    }

}

// MARK: - Notifications
public extension Notification.Name {
    /// Notification posted when a migration phase changes.
    static let migrationPhaseDidChange = Notification.Name("GraphMigrationManager.migrationPhaseDidChange")
    /// Notification posted when a migration fails.
    static let graphMigrationDidFail = Notification.Name("GraphMigrationManager.graphMigrationDidFail")

}

extension GraphMigrationManager {
    /// Posts a notification for migration phase changes.
    static func postPhaseNotification(phase: GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?) {
        let userInfo: [String: Any] = [
            "phase": phase,
            "storeURL": configuration?.storeURL as Any,
            "graphID": graph?.name ?? ""
        ]
        NotificationCenter.default.post(
            name: .migrationPhaseDidChange,
            object: nil,
            userInfo: userInfo
        )
    }

    static func postFailureNotification(
        migrationID: String,
        phase: GraphLifecyclePhase,
        configuration: GraphStoreConfiguration?,
        graph: Graph?,
        error: Error
    ) {
        let userInfo: [String: Any] = [
            "migrationID": migrationID,
            "phase": phase,
            "storeURL": configuration?.resolvedStoreURL as Any,
            "graphID": graph?.name ?? "",
            "error": error,
            "errorDescription": error.localizedDescription
        ]
        NotificationCenter.default.post(
            name: .graphMigrationDidFail,
            object: nil,
            userInfo: userInfo
        )
    }
    

}
extension GraphMigrationManager {
    /// Handles remote entity changes from Persistent History by notifying all registered migrations.
    public static func handleRemoteEntityChanges(configuration: GraphStoreConfiguration?, graph: Graph?, inserted: [NSManagedObjectID], updated: [NSManagedObjectID], context: GraphMigrationContext? = nil) {
        guard let inputConfiguration = configuration else { return }
        let configuration = normalizedConfiguration(inputConfiguration)
        let scope = GraphStoreScope(configuration: configuration)
        stateLock.lock()
        let coordinator = coordinators[scope] ?? {
            let value = StoreMigrationCoordinator(scope: scope)
            coordinators[scope] = value
            return value
        }()
        stateLock.unlock()
        coordinator.handleRemoteChanges(configuration: configuration, graph: graph, context: context, inserted: inserted, updated: updated)
    }
}

//
//  GraphMigrationTypes.swift
//  GraphEvo
//
//  Public migration context, result and protocol contracts.
//

import Foundation
import CoreData

public struct GraphMigrationContext {
    private var values: [String: Any]

    public init(_ values: [String: Any] = [:]) {
        self.values = values
    }

    public subscript<T>(key: String) -> T? {
        values[key] as? T
    }

    public mutating func set<T>(_ key: String, value: T) {
        values[key] = value
    }
}

public enum GraphMigrationRemoteState: Sendable {
    case unknown
    case observed(GraphMigrationRecord)
}

public struct GraphMigrationStateSnapshot: Sendable {
    public let storeScope: String
    public let localRecord: GraphMigrationRecord?
    public let remoteState: GraphMigrationRemoteState
    public let generation: UInt64?
    public let operationID: String?
    public let phase: String?
    public let backupReference: String?
    public let errorDescription: String?
    public let attemptCount: Int
    public let interrupted: Bool
}

public extension GraphMigrationContext {
    var previousMigrationRecord: GraphMigrationRecord? {
        self["GraphMigration.previousRecord"]
    }

    var migrationStateSnapshot: GraphMigrationStateSnapshot? {
        self["GraphMigration.stateSnapshot"]
    }
}

public enum GraphMigrationResult {
    case done
    case error(Error)
    case fallback
    case skipped
}

public protocol GraphMigration {
    var id: String { get }
    var version: Int { get }
    var completionSynchronization: GraphMigrationCompletionSynchronization { get }
    /// Default root folder for backups used by this migration.
    func backupRoot(for configuration: GraphStoreConfiguration?) -> URL?
    func handlePhase(
        _ phase: GraphMigrationManager.GraphLifecyclePhase,
        configuration: GraphStoreConfiguration?,
        graph: Graph?,
        context: GraphMigrationContext?,
        completion: @escaping (GraphMigrationResult) -> Void
    )
    func needsRun(
        at phase: GraphMigrationManager.GraphLifecyclePhase,
        configuration: GraphStoreConfiguration?,
        graph: Graph?,
        context: inout GraphMigrationContext?
    ) -> Bool
    func recognizesLegacyCompletion(
        at phase: GraphMigrationManager.GraphLifecyclePhase,
        configuration: GraphStoreConfiguration?,
        graph: Graph?
    ) -> Bool
    func handleRemoteChanges(
        configuration: GraphStoreConfiguration?,
        graph: Graph?,
        context: GraphMigrationContext?,
        inserted: [NSManagedObjectID],
        updated: [NSManagedObjectID]
    )
    func resetMigrationState(for configuration: GraphStoreConfiguration)
}

public extension GraphMigration {
    var version: Int { 1 }
    var completionSynchronization: GraphMigrationCompletionSynchronization { .local }

    func backupRoot(for configuration: GraphStoreConfiguration?) -> URL? {
        guard let config = configuration else { return nil }
        return GraphMigrationManager.defaultBackupRoot(for: config)
    }

    func handleRemoteChanges(
        configuration: GraphStoreConfiguration?,
        graph: Graph?,
        context: GraphMigrationContext?,
        inserted: [NSManagedObjectID],
        updated: [NSManagedObjectID]
    ) {}

    func recognizesLegacyCompletion(
        at phase: GraphMigrationManager.GraphLifecyclePhase,
        configuration: GraphStoreConfiguration?,
        graph: Graph?
    ) -> Bool { false }

    func resetMigrationState(for configuration: GraphStoreConfiguration) {
        try? GraphMigrationManager.resetRecord(for: self, configuration: configuration)
    }
}

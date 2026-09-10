//
//  GraphEvents.swift
//  GraphEvo
//
//  Public diagnostics contract for applications embedding GraphEvo.
//

import Foundation

/// The persistence mode currently used by a Graph instance.
public enum GraphPersistenceMode {
    case local
    case cloud
    case localFallback
}

/// State changes emitted by GraphEvo.
public enum GraphState {
    case readiness(GraphReadiness)
    case cloudStatus(GraphCloudStatus)
    case persistenceMode(GraphPersistenceMode)
    case cloudImport(GraphCloudImportState)
    case cloudUpload(GraphCloudUploadState)
}

/// Details of a CloudKit export (upload) operation.
public struct GraphCloudUploadEvent {
    public let identifier: UUID
    public let storeIdentifier: String
    public let startDate: Date?
    public let endDate: Date?
    public let succeeded: Bool
    public let error: Error?

    public init(
        identifier: UUID,
        storeIdentifier: String,
        startDate: Date?,
        endDate: Date?,
        succeeded: Bool,
        error: Error?
    ) {
        self.identifier = identifier
        self.storeIdentifier = storeIdentifier
        self.startDate = startDate
        self.endDate = endDate
        self.succeeded = succeeded
        self.error = error
    }
}

/// Lifecycle updates for a CloudKit export operation.
public enum GraphCloudUploadState {
    case started(GraphCloudUploadEvent)
    case finished(GraphCloudUploadEvent)
}

/// Reason why GraphEvo discarded a Persistent History token and rebuilt its
/// local recovery point.
public enum GraphPersistentHistoryRecoveryReason {
    case expiredToken
    case storeUnavailable
    case corruptedToken
}

/// Recoverable conditions that the application may want to surface or log.
public enum GraphWarning: LocalizedError {
    case cloudStoreFallback(underlying: Error)
    case metadataPersistence(underlying: Error)
    case persistentHistoryTokenStore(underlying: Error)
    case persistentHistoryMissingTransactionAuthor
    case persistentHistoryRecovery(
        reason: GraphPersistentHistoryRecoveryReason,
        underlying: Error?
    )
    case watchReportMaterializationFailed(
        source: GraphSource,
        failedEvents: Int,
        details: [GraphWatchMaterializationIssue]
    )

    public var errorDescription: String? {
        switch self {
        case .cloudStoreFallback(let error):
            return "CloudKit store unavailable; GraphEvo fell back to local persistence: \(error.localizedDescription)"
        case .metadataPersistence(let error):
            return "GraphEvo could not read or write store metadata: \(error.localizedDescription)"
        case .persistentHistoryTokenStore(let error):
            return "GraphEvo could not persist the Persistent History token: \(error.localizedDescription)"
        case .persistentHistoryMissingTransactionAuthor:
            return "GraphEvo received a Persistent History transaction without an author; local-change filtering may be incomplete."
        case .persistentHistoryRecovery(let reason, let underlying):
            let description: String
            switch reason {
            case .expiredToken:
                description = "Persistent History token expired; GraphEvo invalidated it and bootstrapped the current history head."
            case .storeUnavailable:
                description = "Persistent History token referenced a store that no longer exists; GraphEvo invalidated it and bootstrapped the current history head."
            case .corruptedToken:
                description = "Persistent History token was corrupted or could not be decoded; GraphEvo invalidated it and bootstrapped the current history head."
            }
            if let underlying {
                return "\(description) Underlying error: \(underlying.localizedDescription)"
            }
            return description
        case .watchReportMaterializationFailed(let source, let failedEvents, let details):
            let first = details.first?.error.localizedDescription ?? "Unknown materialization error"
            return "GraphEvo could not materialize \(failedEvents) \(source == .cloud ? "cloud" : "local") Watch report event(s); the batch will be retried. First error: \(first)"
        }
    }
}

/// Non-recoverable or operation-level failures emitted by GraphEvo.
///
/// A migration failure is intentionally reported here, separately from
/// `GraphReadiness`: the store may still be open and usable even when an
/// application-defined migration did not complete.
public enum GraphFailure: LocalizedError {
    case storeOpening(GraphStoreOpeningError)
    case migration(migrationID: String, phase: String, underlying: Error)
    case persistentHistory(underlying: Error)
    case watchEventMaterialization(source: GraphSource, underlying: Error)
    case query(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .storeOpening(let error):
            return error.localizedDescription
        case .migration(let migrationID, let phase, let error):
            return "Migration '\(migrationID)' failed during \(phase): \(error.localizedDescription)"
        case .persistentHistory(let error):
            return "Persistent History processing failed: \(error.localizedDescription)"
        case .watchEventMaterialization(let source, let error):
            return "A \(source == .cloud ? "cloud" : "local") Watch event could not be materialized: \(error.localizedDescription)"
        case .query(let error):
            return "Graph query failed: \(error.localizedDescription)"
        }
    }
}

/// A diagnostic event emitted by GraphEvo for the application to handle.
public enum GraphEvent {
    case stateChanged(GraphState)
    case warning(GraphWarning)
    case error(GraphFailure)
}

/// Receives GraphEvo state, warning and error events.
public protocol GraphEventDelegate: AnyObject {
    func graph(_ graph: Graph, didReceive event: GraphEvent)
}

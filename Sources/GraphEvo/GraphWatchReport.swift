//
//  GraphWatchReport.swift
//  GraphEvo
//
//  Aggregated Graph-level change reporting.
//

import CoreData
import Foundation

/// A typed change reconstructed from GraphEvo's existing Watch contract.
///
/// Values and Graph objects remain bound to the Graph managed object context.
/// This type is intentionally not `Sendable`.
public enum GraphWatchEvent {
    case insertedEntity(Entity)
    case deletedEntity(Entity)
    case addedEntityProperty(entity: Entity, name: String, value: Any)
    case updatedEntityProperty(entity: Entity, name: String, value: Any)
    case removedEntityProperty(entity: Entity, name: String, value: Any)
    case addedEntityTag(entity: Entity, name: String)
    case removedEntityTag(entity: Entity, name: String)
    case addedEntityToGroup(entity: Entity, name: String)
    case removedEntityFromGroup(entity: Entity, name: String)

    case insertedRelationship(Relationship)
    case updatedRelationship(Relationship)
    case deletedRelationship(Relationship)
    case addedRelationshipProperty(relationship: Relationship, name: String, value: Any)
    case updatedRelationshipProperty(relationship: Relationship, name: String, value: Any)
    case removedRelationshipProperty(relationship: Relationship, name: String, value: Any)
    case addedRelationshipTag(relationship: Relationship, name: String)
    case removedRelationshipTag(relationship: Relationship, name: String)
    case addedRelationshipToGroup(relationship: Relationship, name: String)
    case removedRelationshipFromGroup(relationship: Relationship, name: String)

    case insertedAction(Action)
    case deletedAction(Action)
    case addedActionProperty(action: Action, name: String, value: Any)
    case updatedActionProperty(action: Action, name: String, value: Any)
    case removedActionProperty(action: Action, name: String, value: Any)
    case addedActionTag(action: Action, name: String)
    case removedActionTag(action: Action, name: String)
    case addedActionToGroup(action: Action, name: String)
    case removedActionFromGroup(action: Action, name: String)
}

/// A non-empty group of Graph changes produced by one local save or one
/// Persistent History processing cycle.
public final class GraphWatchReport {
    public let graph: Graph
    public let source: GraphSource
    public let events: [GraphWatchEvent]

    internal init(graph: Graph, source: GraphSource, events: [GraphWatchEvent]) {
        self.graph = graph
        self.source = source
        self.events = events
    }
}

/// Completion used by GraphEvo after attempting batch report delivery.
///
/// A non-nil report represents a completed delivery. The error may also be
/// non-nil when Persistent History retention caused a best-effort delivery.
/// Materialization failures do not invoke this completion and are retried.
public typealias GraphWatchReportCompletion = (_ report: GraphWatchReport?, _ error: Error?) -> Void

/// Diagnostic information about one event that could not be materialized.
public struct GraphWatchMaterializationIssue {
    public let eventKind: String
    public let objectReference: String?
    public let error: Error

    public init(eventKind: String, objectReference: String?, error: Error) {
        self.eventKind = eventKind
        self.objectReference = objectReference
        self.error = error
    }
}

internal enum GraphWatchChangeOperation: Int {
    case insert = 0
    case update = 1
    case delete = 2
}

internal extension GraphWatchChangeOperation {
    var diagnosticName: String {
        switch self {
        case .insert: return "insert"
        case .update: return "update"
        case .delete: return "delete"
        }
    }
}

internal func redactedReference(_ object: NSManagedObject) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in object.objectID.uriRepresentation().absoluteString.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
}

internal struct GraphWatchRemoteRecord {
    let objectID: NSManagedObjectID
    let operation: GraphWatchChangeOperation
    let transactionIndex: Int
    let changeIndex: Int
}

internal let GraphEvoOrderedRemoteChangesKey = "GraphEvo.orderedRemoteChanges"

internal struct GraphWatchEventEnvelope {
    let event: GraphWatchEvent
    let owner: ManagedNode
    let objectURI: String
    let transactionIndex: Int
    let changeIndex: Int

    func isOrdered(before other: GraphWatchEventEnvelope) -> Bool {
        if transactionIndex != other.transactionIndex { return transactionIndex < other.transactionIndex }
        if event.rank != other.event.rank { return event.rank < other.event.rank }
        if objectURI != other.objectURI { return objectURI < other.objectURI }
        if event.detailName != other.event.detailName { return event.detailName < other.event.detailName }
        return changeIndex < other.changeIndex
    }
}

private enum GraphWatchMaterializationError: LocalizedError {
    case missingOwner(String)

    var errorDescription: String? {
        switch self {
        case .missingOwner(let type):
            return "GraphEvo could not materialize the owner of a \(type) Watch event."
        }
    }
}

internal enum GraphWatchEventMaterializer {
    static func materialize(
        object: NSManagedObject,
        operation: GraphWatchChangeOperation,
        source: GraphSource,
        transactionIndex: Int = 0,
        changeIndex: Int = 0
    ) throws -> GraphWatchEventEnvelope? {
        let uri = object.objectID.uriRepresentation().absoluteString

        func envelope(_ event: GraphWatchEvent, owner: ManagedNode) -> GraphWatchEventEnvelope {
            GraphWatchEventEnvelope(
                event: event,
                owner: owner,
                objectURI: uri,
                transactionIndex: transactionIndex,
                changeIndex: changeIndex
            )
        }

        func owner<T: ManagedNode>(of named: NamedManagedObject, as type: T.Type) throws -> T {
            let candidate: ManagedNode?
            if source == .cloud {
                candidate = named.node
            } else {
                candidate = (named.changedValuesForCurrentEvent()["node"] as? ManagedNode) ?? named.node
            }
            guard let value = candidate as? T else {
                throw GraphWatchMaterializationError.missingOwner(String(describing: Swift.type(of: named)))
            }
            return value
        }

        switch operation {
        case .insert:
            switch object {
            case let node as ManagedEntity: return envelope(.insertedEntity(Entity(managedNode: node)), owner: node)
            case let node as ManagedRelationship: return envelope(.insertedRelationship(Relationship(managedNode: node)), owner: node)
            case let node as ManagedAction: return envelope(.insertedAction(Action(managedNode: node)), owner: node)
            case let item as ManagedEntityProperty:
                let node = try owner(of: item, as: ManagedEntity.self)
                return envelope(.addedEntityProperty(entity: Entity(managedNode: node), name: item.name, value: item.object), owner: node)
            case let item as ManagedEntityTag:
                let node = try owner(of: item, as: ManagedEntity.self)
                return envelope(.addedEntityTag(entity: Entity(managedNode: node), name: item.name), owner: node)
            case let item as ManagedEntityGroup:
                let node = try owner(of: item, as: ManagedEntity.self)
                return envelope(.addedEntityToGroup(entity: Entity(managedNode: node), name: item.name), owner: node)
            case let item as ManagedRelationshipProperty:
                let node = try owner(of: item, as: ManagedRelationship.self)
                return envelope(.addedRelationshipProperty(relationship: Relationship(managedNode: node), name: item.name, value: item.object), owner: node)
            case let item as ManagedRelationshipTag:
                let node = try owner(of: item, as: ManagedRelationship.self)
                return envelope(.addedRelationshipTag(relationship: Relationship(managedNode: node), name: item.name), owner: node)
            case let item as ManagedRelationshipGroup:
                let node = try owner(of: item, as: ManagedRelationship.self)
                return envelope(.addedRelationshipToGroup(relationship: Relationship(managedNode: node), name: item.name), owner: node)
            case let item as ManagedActionProperty:
                let node = try owner(of: item, as: ManagedAction.self)
                return envelope(.addedActionProperty(action: Action(managedNode: node), name: item.name, value: item.object), owner: node)
            case let item as ManagedActionTag:
                let node = try owner(of: item, as: ManagedAction.self)
                return envelope(.addedActionTag(action: Action(managedNode: node), name: item.name), owner: node)
            case let item as ManagedActionGroup:
                let node = try owner(of: item, as: ManagedAction.self)
                return envelope(.addedActionToGroup(action: Action(managedNode: node), name: item.name), owner: node)
            default: return nil
            }

        case .update:
            switch object {
            case let node as ManagedRelationship:
                return envelope(.updatedRelationship(Relationship(managedNode: node)), owner: node)
            case let item as ManagedEntityProperty:
                let node = try owner(of: item, as: ManagedEntity.self)
                return envelope(.updatedEntityProperty(entity: Entity(managedNode: node), name: item.name, value: item.object), owner: node)
            case let item as ManagedRelationshipProperty:
                let node = try owner(of: item, as: ManagedRelationship.self)
                return envelope(.updatedRelationshipProperty(relationship: Relationship(managedNode: node), name: item.name, value: item.object), owner: node)
            case let item as ManagedActionProperty:
                let node = try owner(of: item, as: ManagedAction.self)
                return envelope(.updatedActionProperty(action: Action(managedNode: node), name: item.name, value: item.object), owner: node)
            default: return nil
            }

        case .delete:
            switch object {
            case let node as ManagedEntity: return envelope(.deletedEntity(Entity(managedNode: node)), owner: node)
            case let node as ManagedRelationship: return envelope(.deletedRelationship(Relationship(managedNode: node)), owner: node)
            case let node as ManagedAction: return envelope(.deletedAction(Action(managedNode: node)), owner: node)
            case let item as ManagedEntityProperty:
                let node = try owner(of: item, as: ManagedEntity.self)
                return envelope(.removedEntityProperty(entity: Entity(managedNode: node), name: item.name, value: item.object), owner: node)
            case let item as ManagedEntityTag:
                let node = try owner(of: item, as: ManagedEntity.self)
                return envelope(.removedEntityTag(entity: Entity(managedNode: node), name: item.name), owner: node)
            case let item as ManagedEntityGroup:
                let node = try owner(of: item, as: ManagedEntity.self)
                return envelope(.removedEntityFromGroup(entity: Entity(managedNode: node), name: item.name), owner: node)
            case let item as ManagedRelationshipProperty:
                let node = try owner(of: item, as: ManagedRelationship.self)
                return envelope(.removedRelationshipProperty(relationship: Relationship(managedNode: node), name: item.name, value: item.object), owner: node)
            case let item as ManagedRelationshipTag:
                let node = try owner(of: item, as: ManagedRelationship.self)
                return envelope(.removedRelationshipTag(relationship: Relationship(managedNode: node), name: item.name), owner: node)
            case let item as ManagedRelationshipGroup:
                let node = try owner(of: item, as: ManagedRelationship.self)
                return envelope(.removedRelationshipFromGroup(relationship: Relationship(managedNode: node), name: item.name), owner: node)
            case let item as ManagedActionProperty:
                let node = try owner(of: item, as: ManagedAction.self)
                return envelope(.removedActionProperty(action: Action(managedNode: node), name: item.name, value: item.object), owner: node)
            case let item as ManagedActionTag:
                let node = try owner(of: item, as: ManagedAction.self)
                return envelope(.removedActionTag(action: Action(managedNode: node), name: item.name), owner: node)
            case let item as ManagedActionGroup:
                let node = try owner(of: item, as: ManagedAction.self)
                return envelope(.removedActionFromGroup(action: Action(managedNode: node), name: item.name), owner: node)
            default: return nil
            }
        }
    }
}

private extension GraphWatchEvent {
    var rank: Int {
        switch self {
        case .insertedEntity: return 0
        case .addedEntityProperty: return 1
        case .addedEntityTag: return 2
        case .addedEntityToGroup: return 3
        case .updatedEntityProperty: return 4
        case .removedEntityProperty: return 5
        case .removedEntityTag: return 6
        case .removedEntityFromGroup: return 7
        case .deletedEntity: return 8
        case .insertedRelationship: return 9
        case .addedRelationshipProperty: return 10
        case .addedRelationshipTag: return 11
        case .addedRelationshipToGroup: return 12
        case .updatedRelationship: return 13
        case .updatedRelationshipProperty: return 14
        case .removedRelationshipProperty: return 15
        case .removedRelationshipTag: return 16
        case .removedRelationshipFromGroup: return 17
        case .deletedRelationship: return 18
        case .insertedAction: return 19
        case .addedActionProperty: return 20
        case .addedActionTag: return 21
        case .addedActionToGroup: return 22
        case .updatedActionProperty: return 23
        case .removedActionProperty: return 24
        case .removedActionTag: return 25
        case .removedActionFromGroup: return 26
        case .deletedAction: return 27
        }
    }

    var detailName: String {
        switch self {
        case .addedEntityProperty(_, let name, _), .updatedEntityProperty(_, let name, _), .removedEntityProperty(_, let name, _),
             .addedEntityTag(_, let name), .removedEntityTag(_, let name), .addedEntityToGroup(_, let name), .removedEntityFromGroup(_, let name),
             .addedRelationshipProperty(_, let name, _), .updatedRelationshipProperty(_, let name, _), .removedRelationshipProperty(_, let name, _),
             .addedRelationshipTag(_, let name), .removedRelationshipTag(_, let name), .addedRelationshipToGroup(_, let name), .removedRelationshipFromGroup(_, let name),
             .addedActionProperty(_, let name, _), .updatedActionProperty(_, let name, _), .removedActionProperty(_, let name, _),
             .addedActionTag(_, let name), .removedActionTag(_, let name), .addedActionToGroup(_, let name), .removedActionFromGroup(_, let name):
            return name
        default: return ""
        }
    }
}

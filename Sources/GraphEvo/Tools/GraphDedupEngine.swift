import CoreData

/// A logical key used to group entities during deduplication.
public struct DedupKey: Hashable {
    public let entityType: String
    public let namespace: String
    public let value: String

    public init(entityType: String, namespace: String, value: String) {
        self.entityType = entityType
        self.namespace = namespace
        self.value = value
    }
}

/// Supplies the logical key of an entity, or nil when the entity is not
/// indexed by the current deduplication strategy.
public protocol DedupKeyProvider {
    func key(for entity: Entity) -> DedupKey?
}

/// A UUID-field key provider for the common GraphEvo use case.
public struct UUIDFieldKeyProvider: DedupKeyProvider {
    public let fields: [String: String]
    public let namespace: String

    public init(fields: [String: String], namespace: String = "uuid") {
        self.fields = fields
        self.namespace = namespace
    }

    public func key(for entity: Entity) -> DedupKey? {
        guard let field = fields[entity.type],
              let value = entity[dynamicMember: field] as? String,
              !value.isEmpty else {
            return nil
        }
        return DedupKey(entityType: entity.type, namespace: namespace, value: value)
    }
}

/// Selects the entity that survives a duplicate group.
public protocol DedupSurvivorSelector {
    func choosePreferred(_ lhs: Entity, _ rhs: Entity) -> Entity
}

/// Merges metadata without replacing values already present on the target.
public protocol DedupMetadataMerger {
    func mergeMetadata(from source: Node, into target: Node) throws
}

/// Default non-destructive metadata merger used by GraphEvo.
public struct DefaultDedupMetadataMerger: DedupMetadataMerger {
    public init() {}

    public func mergeMetadata(from source: Node, into target: Node) throws {
        for (key, value) in source.properties where target.properties[key] == nil {
            target[dynamicMember: key] = value
        }

        for tag in source.tags where !target.tags.contains(tag) {
            target.add(tags: tag)
        }

        for group in source.groups where !target.groups.contains(group) {
            target.add(to: group)
        }
    }
}

/// Defines how links to duplicate entities are handled.
public enum DedupLinkPolicy: Equatable {
    /// Recreate canonical links, merge duplicate link metadata, and delete old links.
    case rewireAndDeduplicate
    /// Change link endpoints but retain duplicate links.
    case rewireOnly
    /// Leave links involving duplicates untouched and retain those entities.
    case skip
    /// Abort when a link would need to be rewritten.
    case fail
}

/// Defines how entities without a logical key are handled.
public enum DedupUnkeyedEntityPolicy: Equatable {
    case skip
    case fail
}

/// Configuration for a general-purpose Graph deduplication run.
public struct GraphDedupConfiguration {
    public let keyProvider: any DedupKeyProvider
    public let survivorSelector: any DedupSurvivorSelector
    public let metadataMerger: any DedupMetadataMerger
    public let linkPolicy: DedupLinkPolicy
    public let unkeyedEntityPolicy: DedupUnkeyedEntityPolicy

    public init(
        keyProvider: any DedupKeyProvider,
        survivorSelector: any DedupSurvivorSelector,
        metadataMerger: any DedupMetadataMerger = DefaultDedupMetadataMerger(),
        linkPolicy: DedupLinkPolicy = .rewireAndDeduplicate,
        unkeyedEntityPolicy: DedupUnkeyedEntityPolicy = .skip
    ) {
        self.keyProvider = keyProvider
        self.survivorSelector = survivorSelector
        self.metadataMerger = metadataMerger
        self.linkPolicy = linkPolicy
        self.unkeyedEntityPolicy = unkeyedEntityPolicy
    }
}

/// Errors raised by the deduplication engine.
public enum GraphDedupError: LocalizedError {
    case missingContext
    case unkeyedEntities(Int)
    case invalidSurvivor(group: DedupKey, entityID: String)
    case unresolvedRelationship(id: String)
    case unresolvedAction(id: String)

    public var errorDescription: String? {
        switch self {
        case .missingContext:
            return "Graph deduplication requires a managed object context."
        case .unkeyedEntities(let count):
            return "Graph deduplication found \(count) entities without a logical key."
        case .invalidSurvivor(let group, let entityID):
            return "The survivor \(entityID) does not belong to deduplication group \(group.entityType)/\(group.namespace)/\(group.value)."
        case .unresolvedRelationship(let id):
            return "Relationship \(id) requires rewriting but the link policy is fail."
        case .unresolvedAction(let id):
            return "Action \(id) requires rewriting but the link policy is fail."
        }
    }
}

/// A compact result of a deduplication run.
public struct GraphDedupReport {
    public let scannedEntities: Int
    public let keyedEntities: Int
    public let unkeyedEntities: Int
    public let duplicateGroups: Int
    public let mergedEntities: Int
    public let deletedEntities: Int
    public let copiedProperties: Int
    public let rewiredRelationships: Int
    public let deletedRelationships: Int
    public let rewiredActions: Int
    public let deletedActions: Int
    public let skippedItems: Int

    public init(
        scannedEntities: Int,
        keyedEntities: Int,
        unkeyedEntities: Int,
        duplicateGroups: Int,
        mergedEntities: Int,
        deletedEntities: Int,
        copiedProperties: Int,
        rewiredRelationships: Int,
        deletedRelationships: Int,
        rewiredActions: Int,
        deletedActions: Int,
        skippedItems: Int
    ) {
        self.scannedEntities = scannedEntities
        self.keyedEntities = keyedEntities
        self.unkeyedEntities = unkeyedEntities
        self.duplicateGroups = duplicateGroups
        self.mergedEntities = mergedEntities
        self.deletedEntities = deletedEntities
        self.copiedProperties = copiedProperties
        self.rewiredRelationships = rewiredRelationships
        self.deletedRelationships = deletedRelationships
        self.rewiredActions = rewiredActions
        self.deletedActions = deletedActions
        self.skippedItems = skippedItems
    }
}

/// General-purpose, domain-neutral deduplication for a single Graph.
public enum GraphDedupEngine {
    private struct RelationshipKey: Hashable {
        let type: String
        let subjectID: String
        let objectID: String
    }

    private struct ActionKey: Hashable {
        let type: String
        let subjectIDs: [String]
        let objectIDs: [String]
    }

    /// Deduplicates entities and rewires their relationships and actions.
    @discardableResult
    public static func deduplicate(
        in graph: Graph,
        configuration: GraphDedupConfiguration
    ) throws -> GraphDedupReport {
        guard let context = graph.managedObjectContext else {
            throw GraphDedupError.missingContext
        }

        var result: Result<GraphDedupReport, Error> = .failure(GraphDedupError.missingContext)
        context.performAndWait {
            do {
                result = .success(try run(in: graph, context: context, configuration: configuration))
            } catch {
                result = .failure(error)
            }
        }
        return try result.get()
    }

    private static func run(
        in graph: Graph,
        context: NSManagedObjectContext,
        configuration: GraphDedupConfiguration
    ) throws -> GraphDedupReport {
        let entities = Search<Entity>(graph: graph)
            .where(.type("*"))
            .sync()
            .sorted { $0.id < $1.id }

        var groups: [DedupKey: [Entity]] = [:]
        var unkeyedEntities = 0
        for entity in entities {
            if let key = configuration.keyProvider.key(for: entity) {
                groups[key, default: []].append(entity)
            } else {
                unkeyedEntities += 1
            }
        }

        if configuration.unkeyedEntityPolicy == .fail, unkeyedEntities > 0 {
            throw GraphDedupError.unkeyedEntities(unkeyedEntities)
        }

        let duplicateGroups = groups
            .filter { $0.value.count > 1 }
            .sorted { keySort($0.key, $1.key) }

        var replacementByID: [String: Entity] = [:]
        var mergedEntities = 0

        for (key, members) in duplicateGroups {
            let orderedMembers = members.sorted { $0.id < $1.id }
            var survivor = orderedMembers[0]
            for candidate in orderedMembers.dropFirst() {
                let selected = configuration.survivorSelector.choosePreferred(survivor, candidate)
                guard orderedMembers.contains(where: { $0.id == selected.id }) else {
                    throw GraphDedupError.invalidSurvivor(group: key, entityID: selected.id)
                }
                survivor = selected
            }

            for entity in orderedMembers where entity.id != survivor.id {
                replacementByID[entity.id] = survivor
                mergedEntities += 1
            }
        }

        let relationships = Search<Relationship>(graph: graph)
            .where(.type("*"))
            .sync()
            .sorted { $0.id < $1.id }
        let actions = Search<Action>(graph: graph)
            .where(.type("*"))
            .sync()
            .sorted { $0.id < $1.id }

        try validateFailingLinks(
            relationships: relationships,
            actions: actions,
            replacementByID: replacementByID,
            policy: configuration.linkPolicy
        )

        var protectedDuplicateIDs = Set<String>()
        if configuration.linkPolicy == .skip {
            for relationship in relationships {
                let subjectChanged = relationship.subject.map { replacementByID[$0.id] != nil } ?? false
                let objectChanged = relationship.object.map { replacementByID[$0.id] != nil } ?? false
                if subjectChanged || objectChanged {
                    if let subject = relationship.subject {
                        if replacementByID[subject.id] != nil {
                            protectedDuplicateIDs.insert(subject.id)
                        }
                    }
                    if let object = relationship.object {
                        if replacementByID[object.id] != nil {
                            protectedDuplicateIDs.insert(object.id)
                        }
                    }
                }
            }
            for action in actions {
                let endpointIDs = action.subjects.map(\.id) + action.objects.map(\.id)
                if endpointIDs.contains(where: { replacementByID[$0] != nil }) {
                    endpointIDs.forEach {
                        if replacementByID[$0] != nil {
                            protectedDuplicateIDs.insert($0)
                        }
                    }
                }
            }
        }

        var copiedProperties = 0
        for (_, groupMembers) in duplicateGroups {
            let orderedMembers = groupMembers.sorted { $0.id < $1.id }
            guard let survivor = orderedMembers.first(where: { replacementByID[$0.id] == nil }) else { continue }
            for duplicate in orderedMembers where duplicate.id != survivor.id {
                let before = Set(survivor.properties.keys)
                try configuration.metadataMerger.mergeMetadata(from: duplicate, into: survivor)
                copiedProperties += survivor.properties.keys.filter { !before.contains($0) }.count
            }
        }

        var relationshipCounts = (rewired: 0, deleted: 0, skipped: 0)
        try processRelationships(
            relationships,
            graph: graph,
            replacementByID: replacementByID,
            policy: configuration.linkPolicy,
            merger: configuration.metadataMerger,
            counts: &relationshipCounts
        )

        var actionCounts = (rewired: 0, deleted: 0, skipped: 0)
        try processActions(
            actions,
            graph: graph,
            replacementByID: replacementByID,
            policy: configuration.linkPolicy,
            merger: configuration.metadataMerger,
            counts: &actionCounts
        )

        var deletedEntities = 0
        for duplicateID in replacementByID.keys.sorted() where !protectedDuplicateIDs.contains(duplicateID) {
            guard let duplicate = entities.first(where: { $0.id == duplicateID }) else { continue }
            duplicate.delete()
            deletedEntities += 1
        }

        try context.save()
        return GraphDedupReport(
            scannedEntities: entities.count,
            keyedEntities: entities.count - unkeyedEntities,
            unkeyedEntities: unkeyedEntities,
            duplicateGroups: duplicateGroups.count,
            mergedEntities: mergedEntities,
            deletedEntities: deletedEntities,
            copiedProperties: copiedProperties,
            rewiredRelationships: relationshipCounts.rewired,
            deletedRelationships: relationshipCounts.deleted,
            rewiredActions: actionCounts.rewired,
            deletedActions: actionCounts.deleted,
            skippedItems: relationshipCounts.skipped + actionCounts.skipped
        )
    }

    private static func validateFailingLinks(
        relationships: [Relationship],
        actions: [Action],
        replacementByID: [String: Entity],
        policy: DedupLinkPolicy
    ) throws {
        guard policy == .fail else { return }

        for relationship in relationships {
            if relationship.subject.map({ replacementByID[$0.id] != nil }) == true
                || relationship.object.map({ replacementByID[$0.id] != nil }) == true {
                throw GraphDedupError.unresolvedRelationship(id: relationship.id)
            }
        }

        for action in actions {
            let endpointIDs = action.subjects.map(\.id) + action.objects.map(\.id)
            if endpointIDs.contains(where: { replacementByID[$0] != nil }) {
                throw GraphDedupError.unresolvedAction(id: action.id)
            }
        }
    }

    private static func processRelationships(
        _ relationships: [Relationship],
        graph: Graph,
        replacementByID: [String: Entity],
        policy: DedupLinkPolicy,
        merger: any DedupMetadataMerger,
        counts: inout (rewired: Int, deleted: Int, skipped: Int)
    ) throws {
        var canonical: [RelationshipKey: Relationship] = [:]

        for relationship in relationships {
            guard let subject = relationship.subject, let object = relationship.object else { continue }
            let canonicalSubject = replacementByID[subject.id] ?? subject
            let canonicalObject = replacementByID[object.id] ?? object
            let subjectChanged = canonicalSubject.id.compare(subject.id) != .orderedSame
            let objectChanged = canonicalObject.id.compare(object.id) != .orderedSame
            let changed = subjectChanged ? true : objectChanged
            let key = RelationshipKey(type: relationship.type, subjectID: canonicalSubject.id, objectID: canonicalObject.id)

            if policy == .skip && changed {
                counts.skipped += 1
                continue
            }

            if policy == .rewireOnly {
                if changed {
                    relationship.subject = canonicalSubject
                    relationship.object = canonicalObject
                    counts.rewired += 1
                }
                continue
            }

            if let existing = canonical[key], existing.id != relationship.id {
                try merger.mergeMetadata(from: relationship, into: existing)
                relationship.delete()
                counts.deleted += 1
                continue
            }

            if changed {
                let replacement = canonicalSubject.is(relationship: relationship.type)
                replacement.object = canonicalObject
                try merger.mergeMetadata(from: relationship, into: replacement)
                relationship.delete()
                canonical[key] = replacement
                counts.rewired += 1
                counts.deleted += 1
            } else {
                canonical[key] = relationship
            }
        }
    }

    private static func processActions(
        _ actions: [Action],
        graph: Graph,
        replacementByID: [String: Entity],
        policy: DedupLinkPolicy,
        merger: any DedupMetadataMerger,
        counts: inout (rewired: Int, deleted: Int, skipped: Int)
    ) throws {
        var canonical: [ActionKey: Action] = [:]

        for action in actions {
            let subjects = action.subjects
            let objects = action.objects
            let canonicalSubjects = subjects.map { replacementByID[$0.id] ?? $0 }
            let canonicalObjects = objects.map { replacementByID[$0.id] ?? $0 }
            let subjectChanged = zip(subjects, canonicalSubjects).contains { pair in
                pair.0.id.compare(pair.1.id) != .orderedSame
            }
            let objectChanged = zip(objects, canonicalObjects).contains { pair in
                pair.0.id.compare(pair.1.id) != .orderedSame
            }
            let changed = subjectChanged ? true : objectChanged
            let key = ActionKey(
                type: action.type,
                subjectIDs: canonicalSubjects.map(\.id).sorted(),
                objectIDs: canonicalObjects.map(\.id).sorted()
            )

            if policy == .skip && changed {
                counts.skipped += 1
                continue
            }

            if policy == .rewireOnly {
                if changed {
                    action.remove(subjects: subjects)
                    action.remove(objects: objects)
                    action.add(subjects: canonicalSubjects)
                    action.add(objects: canonicalObjects)
                    counts.rewired += 1
                }
                continue
            }

            if let existing = canonical[key], existing.id != action.id {
                try merger.mergeMetadata(from: action, into: existing)
                action.delete()
                counts.deleted += 1
                continue
            }

            if changed {
                let replacement = Action(action.type, graph: graph)
                replacement.add(subjects: canonicalSubjects)
                replacement.add(objects: canonicalObjects)
                try merger.mergeMetadata(from: action, into: replacement)
                action.delete()
                canonical[key] = replacement
                counts.rewired += 1
                counts.deleted += 1
            } else {
                canonical[key] = action
            }
        }
    }

    private static func keySort(_ lhs: DedupKey, _ rhs: DedupKey) -> Bool {
        if lhs.entityType != rhs.entityType { return lhs.entityType < rhs.entityType }
        if lhs.namespace != rhs.namespace { return lhs.namespace < rhs.namespace }
        return lhs.value < rhs.value
    }
}

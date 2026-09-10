# GraphEvo — public API reference

GraphEvo is a Swift library for organizing connected data. It is built on Core
Data and supports both local stores and CloudKit-backed stores.

This document summarizes the public API, common usage patterns, and important
behavioral contracts. The source in `Sources/GraphEvo` and the test suite remain
the authoritative implementation references.

## 1. Module identity

```swift
import GraphEvo
```

- Public module: `GraphEvo`
- Supported platforms: iOS 16+, macOS 12+
- Runtime dependencies: none beyond the Apple platform frameworks required by GraphEvo
- CloudKit backend: `NSPersistentCloudKitContainer` when configured

The public domain model consists of `Graph`, `Node`, `Entity`, `Relationship`,
`Action`, `Search`, and `Watch`.

## 2. Store configuration

```swift
public struct GraphStoreConfiguration {
    public var name: String
    public var location: URL?
    public var backend: GraphStoreBackend
    public var appGroupIdentifier: String?
    public var cloudKitContainerIdentifier: String?
}
```

`location` is treated as an explicit SQLite file when its extension is
`.sqlite`; otherwise it is treated as a directory. For a directory, GraphEvo
builds `GraphEvo_<name>.sqlite`. An explicit file path is authoritative and is
never rewritten.

Important calculated properties include:

- `resolvedLocation`: the effective directory after App Group resolution;
- `storeURL`: the canonical URL calculated from the configuration;
- `legacyStoreURLs`: candidate legacy paths;
- `resolvedStoreURL`: the URL actually selected for opening.

GraphEvo internally identifies whether the resolved store is for CloudKit
Development, CloudKit Production, or local persistence. Directory-based
CloudKit stores select the environment automatically; Development stores use a
`-dev` filename suffix. `Graph(storeURL:)` always uses local persistence. The
environment and its scope are implementation details and are not part of the
application-facing API.

For `.inMemory`, URLs are still calculated for consistency but do not identify a
persistent file. `appGroupIdentifier` affects directory-based configurations;
it does not move an explicit SQLite file.

## 3. `Graph`

```swift
public init(configuration: GraphStoreConfiguration,
            migrationEnabled: Bool = true)
public init(storeURL: URL,
            backend: GraphStoreBackend = .sqlite,
            migrationEnabled: Bool = true)
```

`Graph(storeURL:)` always opens the supplied store as local persistence. It
does not inherit a CloudKit container identifier from `Graph`, configuration,
or `Info.plist`.

`Graph` opens a store and owns the Core Data context used by the public facades.
Use `whenReady` when opening must be coordinated explicitly:

```swift
let graph = Graph(configuration: configuration)
graph.whenReady { result in
    switch result {
    case .success(let graph): graph.sync()
    case .failure(let error): print(error.localizedDescription)
    }
}
```

Common properties and operations include `name`, `configuration`, `readiness`,
`isReady`, `batchSize`, `batchOffset`, and `eventDelegate`,
`sync()`, `async()`, `clear()`, `reset()`, `newBackgroundContext()`, and
`whenReady(_:)`.

`GraphReadiness` describes technical store availability:

```swift
public enum GraphReadiness {
    case initializing
    case ready
    case failed(Error)
}
```

`GraphStoreOpeningError` includes incompatible, unreadable, failed-to-load,
environment, registry-conflict, and incompatible-registered-store cases. An
incompatible store is not changed automatically.

## 4. Nodes and domain objects

`Node` is the common base for all public graph objects. It exposes `graph`,
`type`, `id`, `createdDate`, dynamic property access through
`node["key"]`, tags, groups, and `delete()`.

### `Entity`

```swift
public init(_ type: String, graph: Graph)
```

An `Entity` is a domain object with dynamic properties, tags, groups,
relationships, and actions. Use `Entity` rather than Core Data `Managed*`
classes.

```swift
let user = Entity("User", graph: graph)
user["email"] = "ada@example.com"
user.add(tags: "active")
```

Relationship and action shortcuts include `is(relationship:)`, `will(action:)`,
and `did(action:)`.

### `Relationship`

A relationship is a directed, typed edge with `subject` and `object` entities.
It can be created fluently:

```swift
user.is(relationship: "writes").of(note)
```

The related accessors distinguish `relationshipsWhenSubject` and
`relationshipsWhenObject`.

### `Action`

An action represents an event with one or more `subjects` and `objects`:

```swift
let review = user.will(action: "reviews")
review.add(objects: note)
```

`subjects`, `objects`, `actionsWhenSubject`, and `actionsWhenObject` expose the
associated domain entities.

### Tags and groups

Node mutations are fluent and set-based:

```swift
user.add(tags: "active", "verified")
user.remove(tags: "verified")
user.toggle(tags: "featured")
user.add(to: "authors")
```

`has(tags:using:)` supports `.and` and `.or`. Tags and groups do not contain
duplicates.

## 5. Predicates and search

`Predicate` provides typed constructors such as `.type`, `.exists`, `.has`, and
`.member`, together with property comparisons and the operators `&&`, `||`, and
`!`. String comparisons are case- and diacritic-insensitive.

```swift
let filter = (.type("User") && .has(tags: "active")) || .type("Admin")
let users = Search<Entity>(graph: graph).where(filter).sync()
```

`Search<T>` supports `Entity`, `Relationship`, and `Action`:

```swift
public init(graph: Graph)
public func `where`(_ predicate: Predicate) -> Search<T>
public func sync() -> [T]
public func async(completion: @escaping ([T]) -> Void)
```

Successive `where` calls are combined with OR. Searches combined with `+` must
belong to the same graph. A search without a predicate returns an empty array.

## 6. Watchers

`Watch<T>` observes changes to typed nodes:

```swift
public init(graph: Graph)
public weak var delegate: GraphNodeDelegate?
public var isRunning: Bool { get }
public func clear() -> Watch<T>
public func `where`(_ predicate: Predicate) -> Watch<T>
public func resume() -> Watch<T>
public func pause() -> Watch<T>
```

Watchers start stopped. `resume()` begins observation, `pause()` suspends it,
and `clear()` removes its filter. Use `GraphEntityDelegate`,
`GraphRelationshipDelegate`, or `GraphActionDelegate` according to `T`.
Callbacks cover insertion, update, deletion, property changes, tag changes, and
group membership changes. `GraphSource.local` and `.cloud` identify the change
source.

### Aggregated Watch reports

`Graph` also exposes an optional Graph-level batch path. It does not inherit or
apply predicates from individual `Watch` instances:

```swift
public enum GraphWatchEvent { /* typed Entity, Relationship, and Action cases */ }

public final class GraphWatchReport {
    public let graph: Graph
    public let source: GraphSource
    public let events: [GraphWatchEvent]
}

public typealias GraphWatchReportCompletion = (_ report: GraphWatchReport?, _ error: Error?) -> Void

public var Graph.watchReportCompletion: GraphWatchReportCompletion?
public var Graph.watchReportSources: Set<GraphSource>
```

`GraphWatchEvent` has one case for every atomic Watch callback: node insertion
and deletion, relationship update, and property, tag, and group addition,
update, or removal for the supported node family. Deleted events retain the
same `Entity`, `Relationship`, or `Action` wrappers used by legacy Watch.

Reports are non-empty, immutable, and delivered on the main thread. They are
not `Sendable`; their objects remain tied to the Graph managed object context.
The completion receives `(report, nil)` after a successful delivery. Structural
failures receive `(nil, error)`. A Persistent History retention gap may produce
`(report, error)` for best-effort delivery. Materialization failures are
retryable: no completion is called and the batch delivery token remains
unchanged. The default source set is `[.local, .cloud]`. Restrict it before
assigning the completion when only one source is wanted.

Batch reporting and legacy watchers are parallel. Enabling reports does not
disable atomic callbacks, so applications must not process both paths as the
same logical consumer unless duplicate handling is intentional.

## 7. Events and CloudKit

```swift
public enum GraphPersistenceMode { case local; case cloud; case localFallback }
public enum GraphEvent {
    case stateChanged(GraphState)
    case warning(GraphWarning)
    case error(GraphFailure)
}
// GraphFailure additionally reports watchEventMaterialization when one
// change cannot be represented while the remaining batch continues.
public enum GraphCloudImportState {
    case started(GraphCloudImportEvent)
    case finished(GraphCloudImportEvent)
}
public struct GraphCloudImportEvent {
    public let identifier: UUID?
    public let storeIdentifier: String
    public let isInitialImport: Bool
    public let succeeded: Bool
    public let startDate: Date?
    public let endDate: Date?
    public let error: Error?
}
public enum GraphCloudUploadState {
    case started(GraphCloudUploadEvent)
    case finished(GraphCloudUploadEvent)
}
public struct GraphCloudUploadEvent {
    public let identifier: UUID
    public let storeIdentifier: String
    public let startDate: Date?
    public let endDate: Date?
    public let succeeded: Bool
    public let error: Error?
}
public protocol GraphEventDelegate: AnyObject {
    func graph(_ graph: Graph, didReceive event: GraphEvent)
}
```

Events are delivered on the main thread. States and warnings are not printed
automatically; the application decides how to log them. Unrecoverable errors
remain available as minimal diagnostics.

CloudKit container precedence is explicit configuration, runtime
`Graph.cloudKitContainerIdentifier`, then the
`GraphCloudKitContainerIdentifier` Info.plist key. Without an identifier the
graph remains local. If CloudKit is unavailable, GraphEvo may emit
`GraphWarning.cloudStoreFallback` and use a local fallback.

`purgeCloudStore(completion:)` is restricted to a loaded CloudKit container and
does not delete or recreate local SQLite files. Import and export lifecycle
updates are delivered through `GraphEventDelegate`.

## 8. Persistent History

```swift
@objc func ph_prepareOnLaunchAfterContainerReady()
func processPersistentHistoryForRemoteChange()
func processPersistentHistoryBatch(completion: @escaping (Bool) -> Void)
```

Call the preparation method after the persistent container is ready. GraphEvo
stores a token, filters local-authored transactions, merges object changes, and
advances the token after watcher delivery. Corrupt, expired (`134301`), or
missing-store (`134501`) tokens are recovered at the current history head and
reported through `GraphWarning.persistentHistoryRecovery`.

`ph_debug_*` helpers are public test/diagnostic seams and are not an application
contract.

## 9. Migrations

```swift
public protocol GraphMigration {
    var id: String { get }
    var version: Int { get }
    func handlePhase(... completion: @escaping (GraphMigrationResult) -> Void)
    func needsRun(...) -> Bool
}

GraphMigrationManager.registerMigration(migration)
```

Lifecycle phases are `.preInit`, `.postInit`, `.postMigration`, and `.ready`.
Graph executes all four phases automatically in that order. Registration is
once per migration ID and follows registration order.

`GraphMigrationResult` includes `.done`, `.error(Error)`, `.fallback`, and
`.skipped`. `GraphMigrationContext` passes values between phases and exposes
`previousMigrationRecord` and `migrationStateSnapshot`. The snapshot supports
idempotent recovery decisions after an interrupted attempt. The versioned ledger records `started`, `done`,
`notRequired`, `notExecuted`, and `failed` states. Runtime queues and contexts
are isolated per normalized store scope; applications continue to provide only
a `GraphStoreConfiguration`.

`GraphMigrationManager` also supports `record(for:configuration:)` and the
throwing `recordThrowing(for:configuration:)`. Diagnostic clients can read
immutable history and state snapshots through `history(for:configuration:)`
and `stateSnapshot(for:configuration:)`. It also supports
`resetRecord(for:configuration:)`, the additive reset overload accepting
multiple targets, requester and reason, and
`forceMigration(_:configuration:requestedBy:reason:)` for a one-shot local
force request. `GraphMigrationRequestedBy` includes `.system`,
`.migrationManager`, `.supportCenter`, `.user`, and `.recovery`.
Reset and force requests preserve ledger history. Application migration errors
are delivered as `GraphFailure.migration`; environment routing, scope keys, and
KVS projection details remain internal to GraphEvo.

`GraphMigrationLedgerEntry` is a public, immutable, `Codable` diagnostic value.
It includes the migration state, phase, operation and generation identifiers,
request origin, pseudonymous device identifier, application and model versions,
backup reference, decision metadata, source, timestamps, store scope, and any
error or reset reason. `GraphMigrationDecisionReason` and
`GraphMigrationDecisionSource` are public supporting enums.

The internal schema-1 ledger keeps its current projection separate from its
append-only history and transaction journal. Recovery is driven by the
`migrationStateSnapshot` passed to `needsRun`; an interrupted attempt is
evaluated in its originally recorded lifecycle phase.

`MigrationBackupManager` backs up SQLite files and their optional WAL/SHM
sidecars. `ConflictPolicy` supports `.duplicate`, `.skip`, and `.overwrite`.
File logging is disabled by default and can be enabled with
`GraphMigrationLogger.fileLoggingEnabled = true`.

## 10. Utilities

Public utility types include `Model`, `GraphJSON`, `AnyCodable`,
`AnyCodableObject`, `NSArrayOfAnyCodableObject`,
`DictionaryOfAnyCodableObject`, `GraphArchiver`, `GraphValueTransformer`,
`File`, and `GraphStoreMetadata`.

Use `GraphValueTransformer.register()` when configuring a model manually.
`GraphStoreMetadata` handles compatibility/version metadata but does not
replace semantic data migrations.

## 11. Merge and deduplication

`GraphMergeEngine` imports entities from a secondary graph, recreates
relationships and actions, and returns `GraphMergeReport`. Imported entities
receive a `source` property.

`GraphDedupEngine.deduplicate(in:configuration:)` is the general-purpose
deduplication entry point. Configure a `DedupKeyProvider`, a
`DedupSurvivorSelector`, and, when needed, a custom `DedupMetadataMerger`.
`UUIDFieldKeyProvider` supplies the standard UUID-field strategy.

The default link policy rewires and deduplicates both relationships and
actions. Metadata copies only missing properties and merges tags and groups
without duplicates. The engine may delete objects and rewrite links; create a
backup before running it on production data.

## 12. Unsupported implementation details

Core Data `Managed*` classes, `Container`, `Context`, registries, coordinators,
and `internal`/`fileprivate` helpers are not public API contracts. Use the
`Entity`, `Relationship`, and `Action` facades.

## 13. Integration checklist

1. Configure `GraphStoreConfiguration` and, when needed, CloudKit.
2. Create `Graph` and handle `whenReady` or `eventDelegate`.
3. Create nodes through `Entity(type, graph:)`, mutate properties, and call
   `sync`.
4. Use `Search` for queries and `Watch` for local/CloudKit callbacks.
5. Prepare Persistent History after the container opens.
6. Register migrations before creating the graph and back up before modifying a
   SQLite store.
7. Handle `GraphStoreOpeningError.incompatibleStore` explicitly; GraphEvo
   leaves incompatible stores unchanged.

# Migrations

A migration is an application-level transformation of saved data. GraphEvo
provides the lifecycle and ledger, but does not decide how to interpret the
application's data.

## When a migration is needed

Use a migration when the meaning or format of properties, entity identity, or
relationship structure changes. An incompatible Core Data model change is not
migrated automatically.

## Contract

Implement `GraphMigration`:

```swift
struct AddNoteStatus: GraphMigration {
    let id = "add-note-status"
    let version = 1

    func needsRun(
        at phase: GraphMigrationManager.GraphLifecyclePhase,
        configuration: GraphStoreConfiguration?,
        graph: Graph?,
        context: inout GraphMigrationContext?
    ) -> Bool {
        phase == .postMigration
    }

    func handlePhase(
        _ phase: GraphMigrationManager.GraphLifecyclePhase,
        configuration: GraphStoreConfiguration?,
        graph: Graph?,
        context: GraphMigrationContext?,
        completion: @escaping (GraphMigrationResult) -> Void
    ) {
        // Transform data...
        completion(.done)
    }
}
```

Other protocol functions define backup behavior, remote-change handling, legacy
completion recognition, and state reset.

## Phases

- `.preInit`: before the graph fully opens;
- `.postInit`: after initialization;
- `.postMigration`: the migration phase;
- `.ready`: the graph is ready for normal use.

Graph invokes these phases automatically in the order shown. A migration that
spans phases remains owned by the same per-store coordinator.

Register migrations before creating the graph:

```swift
GraphMigrationManager.registerMigration(AddNoteStatus())
```

Registration occurs once per `id`, and execution follows registration order.

## Results and state

The completion receives `GraphMigrationResult`: `.done` for completion,
`.error(Error)` for failure, `.fallback` for an alternative path, and
`.skipped` when no migration is required.

The versioned ledger exposes `GraphMigrationRecord` and the `started`, `done`,
`notRequired`, `notExecuted`, and `failed` states. Its history is retained per
store and survives retries and resets. An application error is emitted as
`GraphFailure.migration`; it does not automatically mean that the graph is
unusable.

Ledger schema 1 separates the current projection from the append-only JSONL
history. Ordinary state reads decode only the projection; diagnostics and
recovery tools load history explicitly. A flushed transaction journal makes a
projection/history transition replayable after interruption without duplicating
an event. Legacy unversioned records are schema 0 and are upgraded directly to
schema 1. Other versioned formats are rejected without overwriting their files.
History is limited to 2 MB per normalized store scope; older events are folded
into a diagnostic summary while the current projection and recovery-relevant
tail remain available.

Migration queues and contexts are isolated per normalized store. The
application still supplies only its `GraphStoreConfiguration`; GraphEvo derives
the internal store scope and CloudKit environment. A one-shot local force or a
targeted reset can be requested with the additive manager APIs:

```swift
try GraphMigrationManager.forceMigration(migration, configuration: configuration)
try GraphMigrationManager.resetRecord(
    for: migration,
    configuration: configuration,
    targets: [.local, .remote],
    requestedBy: .supportCenter,
    reason: "Rebuild migration projection"
)
```

A reset appends a structured `notExecuted` event rather than deleting history.
A remote reset publishes that new projection to KVS; KVS is observational and
is never interpreted as a command channel.

The local projection keeps remote observations, the last projection accepted
by the local ubiquitous KVS store, and any publication still pending as
separate values. A failed or interrupted publication remains pending and is
surfaced as an error; GraphEvo retries the same operation ID during
reconciliation and after external KVS notifications. Acceptance does not mean
that another device
has already received the value; KVS provides no remote-delivery acknowledgement.

Diagnostic clients can read the immutable ledger history and current snapshot:

```swift
let history = try GraphMigrationManager.history(
    for: migration,
    configuration: configuration
)
let snapshot = try GraphMigrationManager.stateSnapshot(
    for: migration,
    configuration: configuration
)
```

These APIs propagate ledger, reconciliation, and publication errors. The
compatibility `record(for:configuration:)` API remains available for callers
that use its optional return value.

## Context

`GraphMigrationContext` passes data between phases.
`previousMigrationRecord` exposes the previous record when available, while
`migrationStateSnapshot` contains local and observed remote state, generation,
operation ID, phase, backup reference, attempt count, and interruption state.
After an interrupted `started` attempt, GraphEvo preserves the record until the
phase that originally started it. In that phase, `needsRun` must inspect durable
store data and make an idempotent decision: return `true` when work is missing
or uncertain, and `false` only when the saved transformation is verifiably
compatible. GraphEvo cannot infer an application's semantic postcondition, and
a consumed force request is not replayed.

## Safety rules

1. Back up persistent data before transforming it.
2. Make the migration repeatable or check the ledger before running it.
3. Do not delete the original store before verifying the result.
4. Record migration errors and version.
5. Test both success and restoration after failure.
6. Treat `.started` as potentially interrupted work and make recovery safe.

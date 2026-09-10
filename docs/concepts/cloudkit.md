# CloudKit

GraphEvo can use `NSPersistentCloudKitContainer` to synchronize a private
CloudKit store. Synchronization is optional: without a container identifier,
the graph remains local. GraphEvo derives the signed build environment
internally and keeps Development and Production stores, ledgers, and KVS
projections separate; the application continues to provide only a
`GraphStoreConfiguration`.

When the explicit CloudKit environment entitlement is unavailable in a signed
iOS product, GraphEvo derives Development from `get-task-allow = true` and
Production from a distribution signature, after verifying that the signed
iCloud services include CloudKit. Simulator builds remain Development. The
application does not configure this distinction.

While a migration-enabled Graph is alive, GraphEvo observes external KVS
changes for that normalized store. Entries include the logical store scope and
publication/observation timestamps. Conflicts are ordered deterministically by
generation, pseudonymous installation ID, then operation ID. Remote state is
made available to migrations as an observation and never replaces the local
ledger projection directly.

Migration publication is tracked independently from observation. The
per-store ledger persists both the last projection accepted by the local KVS
store and a pending projection to retry. External notifications trigger
reconciliation through the same environment-aware scope; legacy completion
keys are promoted only for Production and are ignored in Development.

## Configuration

```swift
var configuration = GraphStoreConfiguration()
configuration.name = "Main"
configuration.cloudKitContainerIdentifier = "iCloud.com.example.app"

let graph = Graph(configuration: configuration)
```

A runtime override is also available:

```swift
Graph.cloudKitContainerIdentifier = "iCloud.com.example.app"
```

As a fallback, GraphEvo reads `GraphCloudKitContainerIdentifier` from
Info.plist. Precedence is explicit configuration, runtime override, then
Info.plist.

## When CloudKit is unavailable

GraphEvo can open a regular local store as a fallback. The app receives
`GraphWarning.cloudStoreFallback` and a matching `GraphPersistenceMode` state.
This keeps the app usable, but data created during fallback is not necessarily
synchronized.

Observe states through `GraphEventDelegate` and, when needed for the legacy
contract, `GraphCloudStatusDelegate`.

## Remote store purge

Administrative tools can ask GraphEvo to delete the Core Data zone from the
private CloudKit database:

```swift
graph.purgeCloudStore { result in
    switch result {
    case .success:
        // The app must reopen or recreate the local store and
        // clear local tokens and Persistent History.
        break
    case .failure(let error):
        print(error.localizedDescription)
    }
}
```

The API operates only on an `NSPersistentCloudKitContainer` actually loaded
with a CloudKit-configured store. It does not delete SQLite files, recreate the
store, or purge during tests or on a local fallback. Local reset and token/
history management remain the app's responsibility.

`NSPersistentCloudKitContainer` does not expose a distinct native event for
the first sync. GraphEvo identifies the first import by combining the initial
local replica state (an empty store with no local objects) with the first
completed `.import` event for that store. The `.started` and `.finished`
updates are delivered through `GraphEventDelegate` on the main queue and are
deduplicated by `event.identifier`. The `isInitialImport` flag remains
available on `GraphCloudImportEvent` for the completed import state.
The app may use this signal for controlled post-import operations such as
explicit deduplication; GraphEvo performs no automatic deduplication.

Import lifecycle diagnostics are also available through `GraphEventDelegate`,
using the same start/finish API as uploads:

```swift
func graph(_ graph: Graph, didReceive event: GraphEvent) {
    guard case .stateChanged(.cloudImport(let importState)) = event else { return }

    switch importState {
    case .started(let importEvent):
        print("CloudKit import started: \(String(describing: importEvent.identifier))")
    case .finished(let importEvent):
        print("CloudKit import finished: \(importEvent.succeeded)")
    }
}
```


## CloudKit upload diagnostics

The same native container event stream also reports CloudKit exports (uploads).
GraphEvo forwards their lifecycle through `GraphEventDelegate`:

```swift
func graph(_ graph: Graph, didReceive event: GraphEvent) {
    guard case .stateChanged(.cloudUpload(let uploadState)) = event else { return }

    switch uploadState {
    case .started(let upload):
        print("CloudKit upload started: \(upload.identifier)")
    case .finished(let upload):
        print("CloudKit upload finished: \(upload.succeeded)")
    }
}
```

`started` is emitted when the export event has no `endDate`; `finished` is
emitted when the same event receives an `endDate`. Notifications are
deduplicated by event identifier and delivered on the main queue. This is an
informational diagnostic signal: Core Data does not expose a reliable upload
percentage or record count through `NSPersistentCloudKitContainer.Event`.

## Application requirements

An app integrating GraphEvo must configure in Xcode:

- the iCloud/CloudKit capability;
- a valid container identifier;
- the correct CloudKit environment;
- permissions and a model compatible with the data.

GraphEvo cannot replace the app's capability configuration.

## Remote changes

CloudKit changes pass through Persistent History, are merged into the observed
context, and are then forwarded to watchers with `GraphSource.cloud`. See
[Persistent History](../migrations/persistent-history.md).

When `Graph.watchReportCompletion` is configured for `.cloud`, the same
reconstructed events are also delivered as one non-empty report for each
Persistent History processing cycle. GraphEvo persists the history token after
filtering and merging, before materializing and delivering the report. The
completion is not an acknowledgment: delivery never delays or rewinds the
Persistent History processing token. Batch materialization failures are
retryable and leave the separate batch-delivery token unchanged; legacy Watch
callbacks retain their existing best-effort behavior.

In production, keep callbacks idempotent and verify behavior across multiple
devices: local and remote notifications may arrive at different times.

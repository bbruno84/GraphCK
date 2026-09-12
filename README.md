# GraphEvo

[![CI](https://github.com/bbruno84/GraphEvo/actions/workflows/ci.yml/badge.svg)](https://github.com/bbruno84/GraphEvo/actions/workflows/ci.yml)
[![Swift Package Manager](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-orange?logo=swift&logoColor=white)](https://www.swift.org/documentation/package-manager/)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2016%2B%20%7C%20macOS%2012%2B-blue?logo=apple&logoColor=white)](Package.swift)
[![License MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE.md)
[![Release](https://img.shields.io/github/v/release/bbruno84/GraphEvo?display_name=tag)](https://github.com/bbruno84/GraphEvo/releases)

GraphEvo is an independent Swift library evolved from
[CosmicMind/Graph](https://github.com/CosmicMind/Graph). It provides a Core
Data graph model with local persistence and CloudKit synchronization.

The library models entities, relationships, and actions, queries data with
readable predicates, and reacts to changes through watchers and notifications.

The companion demonstration app is maintained separately in the
[GraphEvoDemo repository](https://github.com/bbruno84/GraphEvoDemo).

## 📚 Documentation

- [Complete public API reference](docs/api/public-api.md)
- [Operational instructions for AI agents](AGENTS.md)
- [Documentation index](docs/README.md)
- [Getting started guide](docs/guides/getting-started.md)
- [Graph model](docs/concepts/graph-model.md)
- [Persistence](docs/concepts/persistence.md)
- [CloudKit](docs/concepts/cloudkit.md)
- [Migrations](docs/migrations/overview.md)

---

## ✨ Main features

- Core Data graph model with `Entity`, `Relationship`, and `Action`
- `NSPersistentCloudKitContainer` support with local fallback
- SQLite stores compatible with existing `GraphEvo_<name>.sqlite` paths
- Directory-based configuration with a backend-independent canonical path; legacy `Local/...` and `Cloud/...` paths are reused automatically
- `Graph(storeURL:)` accepts either a directory or an existing SQLite file, preserves an explicit file path, and always opens it as local persistence
- No automatic migration between incompatible models: the app must migrate its store and reopen it at the original path
- Secure encoding of heterogeneous values through `ValueTransformer`
- Enabled options: `NSPersistentHistoryTrackingKey`, `NSPersistentStoreRemoteChangeNotificationPostOptionKey`
- `GraphCloudStatusDelegate` for iCloud availability notifications, with local fallback when unavailable
- Local and remote watchers/notifications through **Persistent History Tracking**
- CloudKit configuration through a runtime override or an Info.plist fallback
- CloudKit precedence: explicit configuration, runtime override, then `Info.plist`

---

## 📦 Requirements

- iOS 16+
- Xcode 15.4+
- Swift Package Manager

The public module is `GraphEvo`:

```swift
import GraphEvo

let graph = Graph(configuration: configuration)
```

`Graph` remains the name of the main class and the domain concepts exposed by
the API.

The `GraphEvo_` prefix and its persistent internal paths and keys are
canonical for the new release. Stores created by earlier test versions with
the `GraphCK_` prefix are not migrated automatically.

GraphEvo does not impose `-Xfrontend` flags or strict-concurrency settings on
the integrating project. This keeps it consumable by targets using CocoaPods
or other SwiftPM dependencies with different settings. If the app wants to
enable concurrency checking, it can set `SWIFT_STRICT_CONCURRENCY` on its own
targets.

---

## 🧪 Tests

- The project builds correctly on iOS 16+
- Tests cover watchers for both local notifications and simulated remote changes
- Full compatibility with `Entity`, `Relationship`, and `Search`

---

## 📌 Operational notes

### Application-level store migration

GraphEvo checks SQLite compatibility before opening a store. If the model is
incompatible, it exposes `GraphStoreOpeningError.incompatibleStore` and leaves
the store path, name, and contents unchanged. Migration between the
CosmicMind/Graph model and the GraphEvo model must be performed by the app,
which understands the meaning of its own data.

---

## ☁️ CloudKit configuration

To enable synchronization with the private CloudKit database, provide a
**container identifier**.

1. **Runtime override** (recommended):

   ```swift
   Graph.cloudKitContainerIdentifier = "iCloud.com.yourdomain.yourApp"
   var configuration = GraphStoreConfiguration()
   configuration.name = "Main"
   let graph = Graph(configuration: configuration)
   ```

2. **Info.plist fallback** (optional): add a `String` key named
   `GraphCloudKitContainerIdentifier` with a value such as
   `iCloud.com.yourdomain.yourApp`.

Without an identifier, the store still works in **local** mode without
synchronization.

## 📣 State, warnings, and errors

GraphEvo does not depend on an application logging platform. To receive
important events and route them to the app logger, assign a `GraphEventDelegate`:

```swift
final class GraphEvents: GraphEventDelegate {
    func graph(_ graph: Graph, didReceive event: GraphEvent) {
        switch event {
        case .stateChanged(let state):
            appLogger.info("GraphEvo state: \(state)")
        case .warning(let warning):
            appLogger.warning(warning.localizedDescription)
        case .error(let error):
            appLogger.error(error.localizedDescription)
        }
    }
}

let graph = Graph(configuration: configuration)
let graphEvents = GraphEvents()
graph.eventDelegate = graphEvents
```

`GraphReadiness` describes only the technical usability of the store and its
Core Data context. An application migration error is delivered as
`GraphFailure.migration`, but does not automatically set readiness to `.failed`
if the store remains usable.

Events are delivered on the main thread. States and errors emitted while the
store is opening are queued until a delegate is assigned. Existing APIs
(`whenReady`, `GraphCloudStatusDelegate`, and `sync` completions) remain
available for compatibility.

States, warnings, and progress updates are not printed automatically to
stdout; the application is responsible for logging them. Unrecoverable errors
remain available on stdout as minimal diagnostic support.

Migration JSONL file logging is disabled by default. For diagnostics, the app
can enable it explicitly with
`GraphMigrationLogger.fileLoggingEnabled = true`.

## License and attribution

GraphEvo is derived from [CosmicMind/Graph](https://github.com/CosmicMind/Graph),
which is distributed under the MIT License. The original copyright and license
notice are preserved in [`LICENSE.md`](LICENSE.md).

GraphEvo and its modifications are released under the MIT License. Copyright
for GraphEvo modifications belongs to the GraphEvo contributors.

GraphEvo includes substantial changes and extensions to the original project,
including the `GraphEvo` module, updated persistence behavior, migrations,
CloudKit handling, tools, and documentation. GraphEvo is not affiliated with
or endorsed by CosmicMind.

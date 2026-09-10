# GraphEvo — instructions for AI agents

This file is the operational entry point for agents working in the repository.
Before changing code, read `README.md` for the project overview and consult the
relevant documentation in `docs/`.

## Library purpose

GraphEvo is a Swift library based on Core Data. It exposes a graph model:

- `Graph` represents an open store and its Core Data context;
- `Node` is the common base for public objects;
- `Entity` represents a domain object;
- `Relationship` connects a subject to an object;
- `Action` represents an action with subjects and objects;
- `Search` executes queries;
- `Watch` observes local and remote changes.

The complete public API reference is in
[`docs/api/public-api.md`](docs/api/public-api.md).

## Repository map

| Path | Responsibility |
|---|---|
| `Sources/GraphEvo/Graph.swift` | Graph opening, readiness, context, and delegates |
| `Sources/GraphEvo/Node.swift` | Common properties, tags, groups, and deletion |
| `Sources/GraphEvo/Entity.swift` | Entities and relationship/action access |
| `Sources/GraphEvo/Relationship.swift` | Directed relationships |
| `Sources/GraphEvo/Action.swift` | Actions and their subjects/objects |
| `Sources/GraphEvo/Search.swift` | Typed queries |
| `Sources/GraphEvo/Predicate.swift` | Filter construction |
| `Sources/GraphEvo/Watch.swift` | Change observation |
| `Sources/GraphEvo/Persistence/` | Configuration, stores, metadata, and contexts |
| `Sources/GraphEvo/Migration/` | Migrations, ledger, backups, and logging |
| `Sources/GraphEvo/Tools/` | Merge, deduplication, and diagnostics |
| `Sources/GraphEvo/Transformer/` | Safe encoding of heterogeneous values |
| `Tests/GraphEvoTests/` | Functional and regression tests |

## Architectural rules

1. Use the public `Entity`, `Relationship`, and `Action` facades. Do not create
   or manipulate Core Data `Managed*` classes directly; they are implementation
   details.
2. Every domain object must belong to the correct `Graph`. Do not combine
   `Search` instances built on different graphs.
3. After changing data, call `graph.sync()` when the context must be persisted.
4. Use `whenReady` when code must distinguish a ready graph from a failed open.
5. Do not add automatic migrations for incompatible stores: GraphEvo must leave
   the files and path unchanged and report `incompatibleStore`.
6. Preserve existing public behavior and update tests when changing a contract.

## Store configuration and URLs

`GraphStoreConfiguration.location` may identify a directory or a SQLite file. It
is an explicit file location when the extension is `.sqlite`.

- Directory: GraphEvo builds `GraphEvo_<name>.sqlite` inside it.
- `.sqlite` file: the complete path is authoritative and is not rewritten.
- `resolvedLocation`: the effective directory used for resolution.
- `storeURL`: the canonical URL calculated from the configuration.
- `resolvedStoreURL`: the URL actually opened, including legacy-store reuse.
- `appGroupIdentifier`: may replace a directory for directory-based
  configuration; it does not move an explicit `.sqlite` file.
- `.inMemory`: uses a temporary database; URLs are calculated but do not point
  to a persistent file.

When changing this logic, verify at least: a new directory, an existing
explicit file, a not-yet-created explicit file, App Group, legacy store,
in-memory backend, and names with upper- or lowercase extensions.

## Essential operational APIs

### Opening and saving

```swift
var config = GraphStoreConfiguration()
config.name = "Main"
let graph = Graph(configuration: config)

graph.whenReady { result in
    switch result {
    case .success(let graph): graph.sync()
    case .failure(let error): print(error.localizedDescription)
    }
}
```

Prefer `Graph(configuration:migrationEnabled:)` for explicit configurations,
`Graph(storeURL:backend:migrationEnabled:)` when the caller owns an exact
directory or file, `whenReady` for opening results, `sync` for synchronous
saves, `async` for asynchronous saves, and `newBackgroundContext()` for
background Core Data work.

### Creating and changing data

```swift
let user = Entity("User", graph: graph)
user["email"] = "ada@example.com"
user.add(tags: "active")

let note = Entity("Note", graph: graph)
user.is(relationship: "writes").of(note)
graph.sync()
```

Node properties are dynamic and typed as `Any?`. Use the public transformers
and coders documented in the API reference for complex values.

### Queries

```swift
let activeUsers = Search<Entity>(graph: graph)
    .where(.type("User"))
    .where(.has(tags: "active"))
    .sync()
```

Successive `where` calls are currently combined with OR. For an explicit
compound expression, build a `Predicate` with `&&`, `||`, and `!` first.

### Watchers

A watcher is initially stopped. Configure its filter and delegate, then call
`resume()`. Use `pause()` to suspend it and `clear()` to remove the filter.
Callbacks distinguish `GraphSource.local` and `GraphSource.cloud`.

For Graph-level batches, assign `Graph.watchReportCompletion` and select sources
with `Graph.watchReportSources`. Batch reports do not apply Watch predicates,
are delivered on the main thread, and do not disable legacy callbacks.

## CloudKit and Persistent History

Container identifier precedence is:

1. `configuration.cloudKitContainerIdentifier`;
2. `Graph.cloudKitContainerIdentifier`;
3. `GraphCloudKitContainerIdentifier` in Info.plist.

Without an identifier the graph remains local. If CloudKit is unavailable,
GraphEvo may emit a warning and use a local fallback.

Call `ph_prepareOnLaunchAfterContainerReady()` after the container is ready.
Persistent History uses a persisted token and filters local-authored
transactions to avoid duplicate callbacks on the originating device.

## Migrations

Register migrations before creating or opening a graph:

```swift
GraphMigrationManager.registerMigration(MyMigration())
```

The phases are `.preInit`, `.postInit`, `.postMigration`, and `.ready`. A
migration declares `id`, implements `handlePhase`, reports whether it needs to
run through `needsRun`, and calls its completion with `GraphMigrationResult`.

Use `MigrationBackupManager` before transforming a store. A store backup
includes `.sqlite` and, when present, `.sqlite-wal` and `.sqlite-shm` files.

## Change workflow

1. Identify the responsible module and read its related tests.
2. Check whether the change affects a public API, persistent URL, Core Data
   model, synchronization, or watcher behavior.
3. Implement the change while preserving compatibility and existing naming.
4. Add or update regression tests.
5. Update the API document and the relevant thematic guide.
6. Run `git diff --check` and the available tests.
7. Clearly summarize changed files, tests, and environmental limitations.

All comments and documentation must be written in English. This includes
Markdown files, API comments, inline code comments, test comments, and user-
facing diagnostic messages introduced or modified by an agent.

All implementations and distributions must comply with the requirements of
the applicable software licenses, including attribution, copyright, notice,
and redistribution obligations. Before adding or adapting third-party code,
review its license and preserve the required notices.

## Branching model

The repository uses three main branch roles:

- `master`: contains only the latest stable release. Hotfix branches start from
  `master` and are merged back through a pull request.
- `development`: the ongoing integration branch. Feature and bugfix branches
  start from `development` and are merged back through pull requests.
- `release/<version>`: created from `development` when the feature freeze is
  declared. During the release cycle, only bugfixes, stabilization work, and
  release refinements should be merged into this branch.

The historical branch `rebase/graphMHB-base` must be retained as project
history. Do not delete, rename, rewrite, or use it as a base for ordinary
feature work unless explicitly requested.

Stable releases are promoted from the appropriate release branch into
`master` through a pull request. Relevant hotfixes and release fixes should be
forward-merged into `development` when applicable so the branches do not drift.

## Git and pull-request workflow

Keep every change tracked, described, and easy to reverse. Do not work directly
on shared or release branches unless explicitly requested.

1. Start on the correct branch and verify a clean tree:

   ```bash
   git status --short --branch
   git fetch --prune
   ```

2. Create a dedicated descriptive branch, such as
   `codex/docs-agents-workflow` or `codex/fix-store-resolution`.
3. Keep the change focused; do not include unrelated files or formatting.
4. Update code, tests, and documentation together when they describe one
   behavior. Commit messages should explain intent, for example:

   ```text
   docs: document GraphStoreConfiguration URL resolution
   fix: preserve explicit SQLite store URLs
   test: cover legacy store fallback
   ```

5. Before opening a PR, run:

   ```bash
   git diff --check
   git status --short --branch
   git diff --stat
   swift package dump-package
   swift test
   ```

   If a check cannot run, describe why in the PR and work summary. Do not hide
   a failed test or alter code only to bypass a non-representative limitation.
6. Publish the branch and open a PR against the intended target branch. Include
   the goal, context, behavior before/after, files or modules, tests, risks,
   limitations, follow-up work, and updated documentation.
7. Wait for review and automated checks before merging. Merge through the PR.
8. For tracked fixes, add a new commit or update the PR. Avoid rewriting shared
   branch history. Prefer a revert commit for already-merged changes.
9. Never use destructive commands such as `git reset --hard` or `git checkout --`
   without an explicit request and a verified target.

## Recommended checks

```bash
git diff --check
swift package dump-package
swift test
```

The package declares iOS 16+ and macOS 12+, but some code imports Apple
frameworks available only in the corresponding SDK. If `swift test` fails on a
macOS runner because of `UIKit` or `PDFKit`, report the limitation without
changing imports just to make a non-representative local test pass.

## Avoid these mistakes

- Do not use `Graph(name:)`; the public initializer requires a configuration or
  a `storeURL`.
- Do not assume `location` is always the final SQLite file.
- Do not use `storeURL` when you need to know which legacy file is opened; use
  `resolvedStoreURL`.
- Do not modify `Managed*` classes directly to fix public API behavior.
- Do not treat `GraphReadiness` as the result of an application migration;
  migrations report errors through `GraphEvent`.
- Do not introduce CloudKit synchronization without fallback and event handling.
- Do not commit store files, tokens, or test-generated logs.

## Documentation updates

When a public signature changes, always update
[`docs/api/public-api.md`](docs/api/public-api.md). When an operational flow
changes, update this file and the corresponding guide in `docs/`. Keep
`README.md` introductory; do not duplicate the complete API reference there.

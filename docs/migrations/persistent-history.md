# Persistent History

Persistent History identifies changes saved in Core Data since the last
processing point. GraphEvo uses it to deliver changes from other contexts and
CloudKit to watchers.

## Startup

Call the public method after the persistent container is ready:

```swift
graph.ph_prepareOnLaunchAfterContainerReady()
```

GraphEvo loads the saved token or prepares an initial session without losing
the required history.

## Processing

`processPersistentHistoryForRemoteChange()` queues processing. To process one
batch with a completion:

```swift
graph.processPersistentHistoryBatch { processed in
    print("Batch processed: \(processed)")
}
```

The general flow is: load the latest token; read subsequent transactions;
ignore local-authored transactions when appropriate; collect inserted, updated,
and deleted object IDs; merge changes into the observed context; notify
watchers; and save the new token only after delivery.

## Tokens

### Persisted deletion replay

Merging history and materializing events can fault rows that have already been
deleted, including after a remote purge and a subsequent app launch. Core Data
may then leave empty deletions pending in the view context. GraphEvo finalizes
them only when every pending object is a deletion with an ID in the committed
batch and no changed values. Inserts, updates, and unrelated deletions prevent
this save; genuine user edits are never rolled back or implicitly committed.
The same rule covers batch reports, history-gap delivery, legacy callbacks, and
private Graph transactions. Regression tests assert that finalization adds no
persistent-history transaction and leaves subsequent Graph transactions usable.
This behavior is independent of application migrations and does not erase
SQLite files or history tokens.


The token is stored on disk at a store-associated path and also kept in a local
backup. With `appGroupIdentifier`, the token path may reside in the App Group.

Token identity is derived from the canonical URL and, when available, the
persistent store's `NSStoreUUID`. If GraphEvo detects a rebuilt store with a
new identity, it does not reuse the previous token.

The token identifies a processed history position, not a domain object. Do not
use it to reconstruct entity identity directly.

## Duplicate callbacks

GraphEvo assigns a transaction author to local contexts and filters transactions
from the originating device. The app must still design idempotent callbacks:
the same change may be observed at different times when Core Data, CloudKit,
and the UI use different contexts.

## Events and errors

Corrupt tokens are invalidated together with the file and UserDefaults backup,
and GraphEvo moves recovery to the current history head. The same recovery is
used for `NSCocoaErrorDomain` `134301` (an expired token) and `134501` (a token
that refers to a missing store).

The coordinator does not retry the invalid token on later remote-change
notifications and GraphEvo emits one `GraphWarning.persistentHistoryRecovery`
diagnostic. This bootstrap may skip transactions no longer representable by the
token; it does not generate artificial watcher callbacks.

Other token errors produce `GraphWarning.persistentHistoryTokenStore`; a
transaction without an author produces
`GraphWarning.persistentHistoryMissingTransactionAuthor`; processing errors
produce `GraphFailure.persistentHistory`. Use `GraphEventDelegate` to record
them.

`ph_debug_*` helpers are intended for tests and diagnostics, not normal
application flow. Variants without `print` in the name produce no implicit
output; `ph_debug_print...` variants print only when explicitly called.

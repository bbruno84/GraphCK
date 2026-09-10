# Public utilities and tools

These APIs complement the GraphEvo core. They are most useful when properties
contain heterogeneous values, when managing migrations, or when importing data
from another graph.

## `GraphJSON`

`GraphJSON` wraps JSON values and provides safe access to arrays, dictionaries,
and fields:

```swift
if let json = GraphJSON.parse(data) {
    let title = json["title"].asString
    let first = json["items"][0].asDictionary
}
```

Main APIs are `parse`, `serialize`, `stringify`, `asArray`, `asDictionary`,
`asString`, `asInt`, `asDouble`, `asFloat`, `asBool`, `asNSData`, and subscripts
for indexes, keys, and dynamic members.

## Heterogeneous values and archiving

- `AnyCodable` wraps different codable values;
- `AnyCodableObject` supports `NSSecureCoding` and `Codable`;
- `NSArrayOfAnyCodableObject` represents ordered collections;
- `DictionaryOfAnyCodableObject` represents heterogeneous dictionaries;
- `GraphArchiver.archive` and `unarchive` handle securely archived data;
- `GraphValueTransformer.register()` registers the transformer used by the model.

Use these types when a value is not a simple string, number, date, or Boolean.
Always verify that the value belongs to a class permitted by the transformer.

Platform images are stored as PNG `Data`. Legacy archives containing `UIImage`
on iOS or `NSImage` on macOS are accepted on their originating platform and
normalized to PNG data when first read, allowing existing stores to migrate
without an application-level rewrite.

## Files and metadata

`File` provides asynchronous operations for existence, reading, writing,
directories, permissions, and file type. `GraphStoreMetadata` reads and writes
store versions but does not perform semantic data transformations.

## Merge

`GraphMergeEngine.merge` imports entities from a secondary graph into a primary
graph. It first copies entities and then recreates relationships and actions. It
returns a `GraphMergeReport` with counts for imports, mappings, relationships,
and actions.

Imported entities receive a `source` property; entities without the UUID named
in `uuidFieldMap` are marked as unmapped.

## Deduplication

`GraphDedupEngine` groups entities through a `DedupKeyProvider`, selects
survivors through a `DedupSurvivorSelector`, and merges metadata through a
non-destructive `DedupMetadataMerger`. `UUIDFieldKeyProvider` provides the
standard type-to-UUID-field strategy.

```swift
struct PreferNewest: DedupSurvivorSelector {
    func choosePreferred(_ lhs: Entity, _ rhs: Entity) -> Entity {
        lhs.createdDate >= rhs.createdDate ? lhs : rhs
    }
}

let configuration = GraphDedupConfiguration(
    keyProvider: UUIDFieldKeyProvider(fields: ["User": "remoteID"]),
    survivorSelector: PreferNewest()
)

let report = try GraphDedupEngine.deduplicate(
    in: graph,
    configuration: configuration
)
```

The default policy rewires and deduplicates relationships and actions. Metadata
copies only missing properties and merges tags and groups without duplicates.
Entities without a key are skipped by default; use `.fail` when every entity
must be indexed. Deduplication may delete objects and change relationships:
always create a backup before using it on production data.

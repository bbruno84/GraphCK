//
//  WatchersRemoteChangeTests.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 07/09/25.
//

import XCTest
@testable import GraphEvo
import CoreData

final class WatchersRemoteChangeTests: XCTestCase {

    private var strongWatcher: AnyObject?
    private var strongDelegate: AnyObject?

    // MARK: - Helpers

    /// Create a Graph and a Watcher for a given entity type, retain the watcher strongly.
    @discardableResult
    private func makeGraphAndWatcher(named graphName: String, watchingType type: String) -> (graph: Graph, watcher: Watch<Entity>) {
        var config = GraphStoreConfiguration()
        config.name = graphName
        let graph = Graph(configuration: config)
        let watcher = Watch<Entity>(graph: graph).where(.type(type))
        self.strongWatcher = watcher
        return (graph, watcher)
    }

    /// Post a simulated remote change notification with the provided inserted/updated/deleted objects.
    private func postSimulatedRemote(
        on graph: Graph,
        inserted: [NSManagedObject] = [],
        updated: [NSManagedObject] = [],
        deleted: [NSManagedObject] = []
    ) {
        let userInfo: [AnyHashable: Any] = [
            NSInsertedObjectsKey: NSSet(array: inserted),
            NSUpdatedObjectsKey:  NSSet(array: updated),
            NSDeletedObjectsKey:  NSSet(array: deleted)
        ]
        NotificationCenter.default.post(
            name: .GraphEvoSimulatedRemoteChange,
            object: graph.managedObjectContext,
            userInfo: userInfo
        )
    }

    /// Convenience to fetch a ManagedEntityProperty by name from an Entity.
    private func managedProperty(from entity: Entity, named name: String) -> ManagedEntityProperty? {
        let managed = entity.managedNode
        return managed.propertySet
            .compactMap { $0 as? ManagedEntityProperty }
            .first { $0.name == name }
    }

    func testRelatedEntityInsertionReachesAllLegacyWatchers() {
        final class Delegate: NSObject, GraphEntityDelegate {
            var onInsert: ((Entity) -> Void)?

            func graph(_ graph: Graph, inserted entity: Entity, source: GraphSource) {
                guard source == .local else { return }
                onInsert?(entity)
            }
        }

        var config = GraphStoreConfiguration()
        config.name = "RelatedEntityLegacyWatchers"
        let graph = Graph(configuration: config)
        let delegate = Delegate()
        let firstReceived = expectation(description: "first related entity watcher")
        let secondReceived = expectation(description: "second related entity watcher")
        delegate.onInsert = { entity in
            if entity.type == "First" { firstReceived.fulfill() }
            if entity.type == "Second" { secondReceived.fulfill() }
        }

        let firstWatcher = Watch<Entity>(graph: graph).where(.type("First"))
        firstWatcher.delegate = delegate
        let secondWatcher = Watch<Entity>(graph: graph).where(.type("Second"))
        secondWatcher.delegate = delegate

        let first = Entity("First", graph: graph)
        let second = Entity("Second", graph: graph)
        _ = first.is(relationship: "relatesTo").of(second)
        graph.sync()

        wait(for: [firstReceived, secondReceived], timeout: 2)
        withExtendedLifetime((firstWatcher, secondWatcher)) {}
    }

    func testEntityAndRelationshipWatchersBothReceiveRelatedInsertion() {
        final class EntityDelegate: NSObject, GraphEntityDelegate {
            func graph(_ graph: Graph, inserted entity: Entity, source: GraphSource) {
                if source == .local { onInsert?() }
            }

            var onInsert: (() -> Void)?
        }

        final class RelationshipDelegate: NSObject, GraphRelationshipDelegate {
            func graph(_ graph: Graph, inserted relationship: Relationship, source: GraphSource) {
                if source == .local { onInsert?() }
            }

            var onInsert: (() -> Void)?
        }

        var config = GraphStoreConfiguration()
        config.name = "RelatedEntityAndRelationshipWatchers"
        let graph = Graph(configuration: config)
        let entityDelegate = EntityDelegate()
        let relationshipDelegate = RelationshipDelegate()
        let entityReceived = expectation(description: "entity watcher")
        let relationshipReceived = expectation(description: "relationship watcher")
        entityDelegate.onInsert = { entityReceived.fulfill() }
        relationshipDelegate.onInsert = { relationshipReceived.fulfill() }

        let entityWatcher = Watch<Entity>(graph: graph).where(.type("Inserted"))
        entityWatcher.delegate = entityDelegate
        let relationshipWatcher = Watch<Relationship>(graph: graph).where(.type("relatesTo"))
        relationshipWatcher.delegate = relationshipDelegate

        let existing = Entity("Existing", graph: graph)
        graph.sync()
        let inserted = Entity("Inserted", graph: graph)
        _ = inserted.is(relationship: "relatesTo").of(existing)
        graph.sync()

        wait(for: [entityReceived, relationshipReceived], timeout: 2)
        withExtendedLifetime((entityWatcher, relationshipWatcher)) {}
    }

    func testEntityInsertTriggersWatcherDelegateWithSourceLocal() {
        let saveExpectation = expectation(description: "Save should succeed")
        let delegateExpectation = expectation(description: "Watcher should notify delegate")

        final class Delegate: NSObject, GraphEntityDelegate {
            var onInsert: ((Entity, GraphSource) -> Void)?

            func graph(_ graph: Graph, inserted entity: Entity, source: GraphSource) {
                onInsert?(entity, source)
            }
        }
        
        var config = GraphStoreConfiguration()
        config.name = "TestLocalWatcher"
        let graph = Graph(configuration: config)
        let delegate = Delegate()
        let watcher = Watch<Entity>(graph: graph).where(.type("T"))
        watcher.delegate = delegate

        delegate.onInsert = { entity, source in
            XCTAssertEqual(entity.type, "T")
            XCTAssertEqual(source, .local)
            delegateExpectation.fulfill()
        }

        let entity = Entity("T", graph: graph)
        entity[dynamicMember: "foo"] = "bar"

        graph.async { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            saveExpectation.fulfill()
        }

        wait(for: [saveExpectation, delegateExpectation], timeout: 2.0)
    }
    
    func testEntityUpdatePropertyTriggersWatcherDelegateWithSourceLocal() {
        let saveExpectation = expectation(description: "Save should succeed")
        let delegateExpectation = expectation(description: "Watcher should notify delegate on update")

        final class Delegate: NSObject, GraphEntityDelegate {
            var onUpdate: ((Entity, String, Any, GraphSource) -> Void)?

            func graph(_ graph: Graph, entity: Entity, updated property: String, with value: Any, source: GraphSource) {
                onUpdate?(entity, property, value, source)
            }
        }
        
        var config = GraphStoreConfiguration()
        config.name = "TestUpdateWatcher"
        let graph = Graph(configuration: config)
        let delegate = Delegate()
        let watcher = Watch<Entity>(graph: graph).where(.type("T"))
        watcher.delegate = delegate

        delegate.onUpdate = { entity, property, value, source in
            XCTAssertEqual(entity.type, "T")
            XCTAssertEqual(property, "foo")
            XCTAssertEqual(value as? String, "updated")
            XCTAssertEqual(source, .local)
            delegateExpectation.fulfill()
        }

        let entity = Entity("T", graph: graph)
        entity[dynamicMember: "foo"] = "original"
        graph.sync()
        entity[dynamicMember: "foo"] = "updated"

        graph.async { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            saveExpectation.fulfill()
        }

        wait(for: [saveExpectation, delegateExpectation], timeout: 2.0)
    }

    func testEntityRemovePropertyTriggersWatcherDelegateWithSourceLocal() {
        let saveExpectation = expectation(description: "Save should succeed")
        let delegateExpectation = expectation(description: "Watcher should notify delegate on property removal")

        final class Delegate: NSObject, GraphEntityDelegate {
            var onRemove: ((Entity, String, Any, GraphSource) -> Void)?

            func graph(_ graph: Graph, entity: Entity, removed property: String, with value: Any, source: GraphSource) {
                onRemove?(entity, property, value, source)
            }
        }
        
        var config = GraphStoreConfiguration()
        config.name = "TestRemoveWatcher"
        let graph = Graph(configuration: config)
        let delegate = Delegate()
        let watcher = Watch<Entity>(graph: graph).where(.type("T"))
        watcher.delegate = delegate

        delegate.onRemove = { entity, property, value, source in
            XCTAssertEqual(entity.type, "T")
            XCTAssertEqual(property, "foo")
            XCTAssertEqual(value as? String, "toRemove")
            XCTAssertEqual(source, .local)
            delegateExpectation.fulfill()
        }

        let entity = Entity("T", graph: graph)
        entity[dynamicMember: "foo"] = "toRemove"
        graph.sync()
        entity[dynamicMember: "foo"] = nil

        graph.async { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            saveExpectation.fulfill()
        }

        wait(for: [saveExpectation, delegateExpectation], timeout: 2.0)
    }
    
    func testRemoteInsertTriggersDelegateWithSourceCloud() {
        let expectationSave = expectation(description: "Save finished")
        let expectationDelegate = expectation(description: "Remote insert")

        final class Delegate: NSObject, GraphEntityDelegate {
            var onInsert: ((Entity, GraphSource) -> Void)?
            func graph(_ graph: Graph, inserted entity: Entity, source: GraphSource) {
                guard source == .cloud else { return }
                onInsert?(entity, source)
            }
        }

        let (graph, watcher) = makeGraphAndWatcher(named: "WatchersRemoteInsert", watchingType: "RemoteNote")
        let delegate = Delegate()
        watcher.delegate = delegate
        self.strongDelegate = delegate

        let entity = Entity("RemoteNote", graph: graph)
        entity[dynamicMember: "title"] = "Hello from cloud"
        graph.sync()

        delegate.onInsert = { entity, source in
            XCTAssertEqual(entity.type, "RemoteNote")
            XCTAssertEqual(source, .cloud)
            expectationDelegate.fulfill()
        }

        postSimulatedRemote(on: graph, inserted: [entity.managedNode])

        graph.async { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            expectationSave.fulfill()
        }

        wait(for: [expectationSave, expectationDelegate], timeout: 3.0)
    }
    
    func testRemoteUpdateTriggersDelegateWithSourceCloud() {
        let expectationSave = expectation(description: "Save finished (update)")
        let expectationDelegate = expectation(description: "Remote update")

        final class Delegate: NSObject, GraphEntityDelegate {
            var onUpdate: ((Entity, String, Any, GraphSource) -> Void)?
            func graph(_ graph: Graph, entity: Entity, updated property: String, with value: Any, source: GraphSource) {
                guard source == .cloud else { return }
                onUpdate?(entity, property, value, source)
            }
        }

        let (graph, watcher) = makeGraphAndWatcher(named: "WatchersRemoteUpdate", watchingType: "RemoteNote")
        let delegate = Delegate()
        watcher.delegate = delegate
        self.strongDelegate = delegate

        let entity = Entity("RemoteNote", graph: graph)
        entity[dynamicMember: "title"] = "v1"
        graph.sync()

        delegate.onUpdate = { entity, property, value, source in
            XCTAssertEqual(entity.type, "RemoteNote")
            XCTAssertEqual(property, "title")
            XCTAssertEqual(value as? String, "Hello from cloud (updated)")
            XCTAssertEqual(source, .cloud)
            expectationDelegate.fulfill()
        }

        // Apply the update now (no sync): the simulated cloud notification will drive the callback
        entity[dynamicMember: "title"] = "Hello from cloud (updated)"

        guard let titleProp = managedProperty(from: entity, named: "title") else {
            XCTFail("Missing ManagedEntityProperty 'title' for update payload")
            return
        }

        postSimulatedRemote(on: graph, updated: [titleProp])

        graph.async { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            expectationSave.fulfill()
        }

        wait(for: [expectationSave, expectationDelegate], timeout: 3.0)
    }

    func testRemoteDeleteTriggersDelegateWithSourceCloud() {
        let expectationSave = expectation(description: "Save finished (delete)")
        let expectationDelegate = expectation(description: "Remote delete")

        final class Delegate: NSObject, GraphEntityDelegate {
            var onDelete: ((Entity, GraphSource) -> Void)?
            func graph(_ graph: Graph, deleted entity: Entity, source: GraphSource) {
                guard source == .cloud else { return }
                onDelete?(entity, source)
            }
        }

        let (graph, watcher) = makeGraphAndWatcher(named: "WatchersRemoteDelete", watchingType: "RemoteNote")
        let delegate = Delegate()
        watcher.delegate = delegate
        self.strongDelegate = delegate

        let entity = Entity("RemoteNote", graph: graph)
        entity[dynamicMember: "title"] = "to delete"
        graph.sync()

        delegate.onDelete = { entity, source in
            XCTAssertEqual(entity.type, "RemoteNote")
            XCTAssertEqual(source, .cloud)
            expectationDelegate.fulfill()
        }

        postSimulatedRemote(on: graph, deleted: [entity.managedNode])

        graph.async { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            expectationSave.fulfill()
        }

        wait(for: [expectationSave, expectationDelegate], timeout: 3.0)
    }
    
    func testRemoteMixedBatchTriggersDelegatesWithSourceCloud() {
        let expInsert = expectation(description: "Remote insert")
        let expUpdate = expectation(description: "Remote update")
        let expDelete = expectation(description: "Remote delete")
        let expSave   = expectation(description: "Save finished (mixed)")

        final class Delegate: NSObject, GraphEntityDelegate {
            var onInsert: ((Entity, GraphSource) -> Void)?
            var onUpdate: ((Entity, String, Any, GraphSource) -> Void)?
            var onDelete: ((Entity, GraphSource) -> Void)?

            func graph(_ graph: Graph, inserted entity: Entity, source: GraphSource) { if source == .cloud { onInsert?(entity, source) } }
            func graph(_ graph: Graph, entity: Entity, updated property: String, with value: Any, source: GraphSource) { if source == .cloud { onUpdate?(entity, property, value, source) } }
            func graph(_ graph: Graph, deleted entity: Entity, source: GraphSource) { if source == .cloud { onDelete?(entity, source) } }
        }

        let (graph, watcher) = makeGraphAndWatcher(named: "WatchersRemoteMixedBatch", watchingType: "RemoteNote")
        let delegate = Delegate()
        watcher.delegate = delegate
        self.strongDelegate = delegate

        // Seed: one entity to update, one to delete
        let toUpdate = Entity("RemoteNote", graph: graph)
        toUpdate[dynamicMember: "title"] = "v1"
        let toDelete = Entity("RemoteNote", graph: graph)
        toDelete[dynamicMember: "title"] = "bye"
        graph.sync()

        // Prepare expectations handlers
        delegate.onInsert = { entity, source in
            XCTAssertEqual(entity.type, "RemoteNote")
            XCTAssertEqual(entity[dynamicMember: "title"] as? String, "new from cloud")
            XCTAssertEqual(source, .cloud)
            expInsert.fulfill()
        }
        delegate.onUpdate = { entity, property, value, source in
            XCTAssertEqual(entity.type, "RemoteNote")
            XCTAssertEqual(property, "title")
            XCTAssertEqual(value as? String, "v2")
            XCTAssertEqual(source, .cloud)
            expUpdate.fulfill()
        }
        delegate.onDelete = { entity, source in
            XCTAssertEqual(entity.type, "RemoteNote")
            XCTAssertEqual(source, .cloud)
            expDelete.fulfill()
        }

        // Build the mixed batch payload
        let inserted = Entity("RemoteNote", graph: graph)
        inserted[dynamicMember: "title"] = "new from cloud"

        // For update: modify property value now (so the managed property exists) and craft payload
        toUpdate[dynamicMember: "title"] = "v2"
        guard let updatedProp = managedProperty(from: toUpdate, named: "title") else {
            return XCTFail("Missing ManagedEntityProperty 'title' for update payload")
        }

        // Post a single simulated remote notification containing all 3 kinds
        postSimulatedRemote(on: graph,
                            inserted: [inserted.managedNode],
                            updated:  [updatedProp],
                            deleted:  [toDelete.managedNode])

        graph.async { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            expSave.fulfill()
        }

        wait(for: [expInsert, expUpdate, expDelete, expSave], timeout: 3.0)
    }

    func testAlreadyMergedRemotePayloadKeepsLegacyWatcherCallback() {
        let expectation = expectation(description: "Already-merged remote update")

        final class Delegate: NSObject, GraphEntityDelegate {
            var onUpdate: ((Entity, String, Any, GraphSource) -> Void)?

            func graph(_ graph: Graph, entity: Entity, updated property: String, with value: Any, source: GraphSource) {
                onUpdate?(entity, property, value, source)
            }
        }

        let (graph, watcher) = makeGraphAndWatcher(named: "WatchersAlreadyMerged", watchingType: "RemoteNote")
        let delegate = Delegate()
        watcher.delegate = delegate
        self.strongDelegate = delegate

        let entity = Entity("RemoteNote", graph: graph)
        entity[dynamicMember: "title"] = "v1"
        graph.sync()

        entity[dynamicMember: "title"] = "v2"
        guard let updatedProperty = managedProperty(from: entity, named: "title") else {
            return XCTFail("Missing ManagedEntityProperty 'title'")
        }

        delegate.onUpdate = { _, property, value, source in
            XCTAssertEqual(property, "title")
            XCTAssertEqual(value as? String, "v2")
            XCTAssertEqual(source, .cloud)
            expectation.fulfill()
        }

        var userInfo: [AnyHashable: Any] = [
            NSInsertedObjectsKey: NSSet(),
            NSUpdatedObjectsKey: NSSet(array: [updatedProperty]),
            NSDeletedObjectsKey: NSSet()
        ]
        userInfo[GraphEvoRemoteChangeAlreadyMergedKey] = true

        NotificationCenter.default.post(
            name: .GraphEvoSimulatedRemoteChange,
            object: graph.managedObjectContext,
            userInfo: userInfo
        )

        wait(for: [expectation], timeout: 2.0)
    }
    
    override func tearDown() {
        strongWatcher = nil
        strongDelegate = nil
        super.tearDown()
    }

}

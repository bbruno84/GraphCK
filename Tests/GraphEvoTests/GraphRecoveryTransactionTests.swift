import XCTest
import CoreData
@testable import GraphEvo

final class GraphRecoveryTransactionTests: XCTestCase {
    func testWholeEntityDeletionLeavesViewCleanAfterDelivery() throws {
        try assertWholeEntityDeletion(backend: .sqlite)
    }

    func testInMemoryWholeEntityDeletionLeavesViewCleanAfterDelivery() throws {
        try assertWholeEntityDeletion(backend: .inMemory)
    }

    func testRewiredEntityDeletionLeavesViewCleanAfterDelivery() throws {
        try assertWholeEntityDeletion(backend: .sqlite, rewire: true)
    }

    private func assertWholeEntityDeletion(backend: GraphStoreBackend, rewire: Bool = false) throws {
        var config = GraphStoreConfiguration()
        config.name = UUID().uuidString
        config.backend = backend
        config.location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let graph = Graph(configuration: config, migrationEnabled: false)
        let ready = expectation(description: "ready")
        graph.whenReady { _ in ready.fulfill() }
        wait(for: [ready], timeout: 10)
        let category = Entity("Category", graph: graph)
        category[dynamicMember: "uuid"] = "duplicate-category"
        category.add(tags: "test")
        category.add(to: "fixture")
        let bill = Entity("Bill", graph: graph)
        bill[dynamicMember: "amount"] = 42.0
        let link = bill.is(relationship: "category").of(category)
        link[dynamicMember: "source"] = "fixture"
        if rewire { _ = Entity("Winner", graph: graph) }
        graph.sync()
        func historyCount() throws -> Int {
            guard backend == .sqlite else { return 0 }
            let result = try graph.managedObjectContext.execute(NSPersistentHistoryChangeRequest.fetchHistory(after: Date.distantPast)) as? NSPersistentHistoryResult
            return try XCTUnwrap(result?.result as? [NSPersistentHistoryTransaction]).count
        }
        let historyBefore = try historyCount()
        XCTAssertEqual(link.object?.id, category.id)
        XCTAssertEqual(category[dynamicMember: "uuid"] as? String, "duplicate-category")
        try graph.transaction { scoped in
            let duplicate = try XCTUnwrap(Search<Entity>(graph: scoped).where(.type("Category")).sync().first)
            if rewire {
                let winner = try XCTUnwrap(Search<Entity>(graph: scoped).where(.type("Winner")).sync().first)
                let relation = try XCTUnwrap(Search<Relationship>(graph: scoped).where(.type("category")).sync().first)
                relation.object = winner
            }
            duplicate.delete()
        }
        XCTAssertFalse(graph.managedObjectContext.hasChanges, "dirty immediately after deletion")
        let delivered = expectation(description: "merge delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { delivered.fulfill() }
        wait(for: [delivered], timeout: 5)
        XCTAssertFalse(graph.managedObjectContext.hasChanges, "\(graph.pendingChangeDiagnostics(checkpoint: "test")!.summary)")
        XCTAssertTrue(Search<Entity>(graph: graph).where(.type("Category")).sync().isEmpty)
        XCTAssertEqual(Search<Relationship>(graph: graph).where(.type("category")).sync().count, rewire ? 1 : 0)
        if rewire { XCTAssertEqual(link.object?.type, "Winner") }
        XCTAssertEqual(bill[dynamicMember: "amount"] as? Double, 42)
        if backend == .sqlite { XCTAssertEqual(try historyCount(), historyBefore + 1, "Merge finalization must not create a second persistent-history transaction") }
        XCTAssertNoThrow(try graph.transaction { _ in })
        withExtendedLifetime((category, link)) {}
    }

    func testPropertyDeletionCommitLeavesViewCleanAfterDelivery() throws {
        try assertPropertyDeletionCommitLeavesViewClean(backend: .sqlite)
    }

    func testUserInsertionDuringDeletionMergeIsNotSavedOrDiscarded() throws {
        var config = GraphStoreConfiguration()
        config.name = UUID().uuidString
        config.backend = .inMemory
        let graph = Graph(configuration: config, migrationEnabled: false)
        let ready = expectation(description: "ready")
        graph.whenReady { _ in ready.fulfill() }
        wait(for: [ready], timeout: 10)
        let victim = Entity("Victim", graph: graph)
        graph.sync()
        let view = try XCTUnwrap(graph.managedObjectContext)
        var edit: Entity?
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextObjectsDidChange, object: view, queue: nil) { notification in
            guard edit == nil, notification.userInfo?[NSDeletedObjectsKey] != nil else { return }
            edit = Entity("UnsavedUserEdit", graph: graph)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try graph.transaction { scoped in
            Search<Entity>(graph: scoped).where(.type("Victim")).sync().forEach { $0.delete() }
        }
        XCTAssertNotNil(edit)
        XCTAssertTrue(view.hasChanges)
        XCTAssertTrue(view.insertedObjects.contains { $0.entity.name == "ManagedEntity" })
        let probe = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        probe.persistentStoreCoordinator = view.persistentStoreCoordinator
        try probe.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "ManagedEntity")
            request.predicate = NSPredicate(format: "type == %@", "UnsavedUserEdit")
            XCTAssertTrue(try probe.fetch(request).isEmpty, "User edit must remain unsaved")
        }
        XCTAssertThrowsError(try graph.transaction { _ in })
        withExtendedLifetime(victim) {}
    }

    func testBulkDeletionLikeLocalWipeLeavesViewClean() throws {
        var config = GraphStoreConfiguration()
        config.name = UUID().uuidString
        config.location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let graph = Graph(configuration: config, migrationEnabled: false)
        let ready = expectation(description: "ready")
        graph.whenReady { _ in ready.fulfill() }
        wait(for: [ready], timeout: 10)
        let nodes = (0..<20).map { index -> Entity in
            let entity = Entity("Bill", graph: graph)
            entity[dynamicMember: "uuid"] = "bill-\(index)"
            entity.add(tags: "fixture")
            return entity
        }
        for index in 1..<nodes.count { nodes[index].is(relationship: "link").of(nodes[0]) }
        graph.sync()
        try graph.transaction { scoped in
            let context = try XCTUnwrap(scoped.managedObjectContext)
            for entity in try XCTUnwrap(context.persistentStoreCoordinator).managedObjectModel.entities where entity.superentity == nil {
                let request = NSFetchRequest<NSManagedObject>(entityName: try XCTUnwrap(entity.name))
                try context.fetch(request).forEach(context.delete)
            }
        }
        XCTAssertFalse(graph.managedObjectContext.hasChanges)
        let delivered = expectation(description: "merge delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { delivered.fulfill() }
        wait(for: [delivered], timeout: 5)
        XCTAssertFalse(graph.managedObjectContext.hasChanges)
        XCTAssertNoThrow(try graph.transaction { scoped in
            let context = try XCTUnwrap(scoped.managedObjectContext)
            for entity in try XCTUnwrap(context.persistentStoreCoordinator).managedObjectModel.entities where entity.superentity == nil {
                XCTAssertEqual(try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: try XCTUnwrap(entity.name))), 0)
            }
        })
        withExtendedLifetime(nodes) {}
    }

    func testVerboseDiagnosticIdentifiesDeletedEntityWithoutChangingPendingState() throws {
        var config = GraphStoreConfiguration()
        config.name = UUID().uuidString
        config.backend = .inMemory
        let graph = Graph(configuration: config, migrationEnabled: false)
        let ready = expectation(description: "ready")
        graph.whenReady { _ in ready.fulfill() }
        wait(for: [ready], timeout: 10)
        let entity = Entity("FixtureCategory", graph: graph)
        entity[dynamicMember: "uuid"] = "fixture-category-id"
        graph.sync()
        graph.managedObjectContext.delete(entity.node)
        let pending = graph.managedObjectContext.deletedObjects
        let diagnostic = try XCTUnwrap(graph.pendingChangeDiagnostics(checkpoint: "test.deletedEntity"))
        XCTAssertTrue(diagnostic.debugDetails.contains { $0.contains("nodeType=FixtureCategory") && $0.contains("fixture-category-id") })
        XCTAssertFalse(diagnostic.summary.contains("fixture-category-id"))
        XCTAssertEqual(graph.managedObjectContext.deletedObjects, pending)
        graph.managedObjectContext.rollback()
    }

    func testInMemoryPropertyDeletionCommitLeavesViewCleanAfterDelivery() throws {
        try assertPropertyDeletionCommitLeavesViewClean(backend: .inMemory)
    }

    private func assertPropertyDeletionCommitLeavesViewClean(backend: GraphStoreBackend) throws {
        var config = GraphStoreConfiguration()
        config.name = UUID().uuidString
        config.backend = backend
        config.location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let graph = Graph(configuration: config, migrationEnabled: false)
        let ready = expectation(description: "ready")
        graph.whenReady { _ in ready.fulfill() }
        wait(for: [ready], timeout: 10)
        let entities = (0..<5).map { _ in Entity("Bill", graph: graph) }
        for entity in entities {
            entity[dynamicMember: "keep"] = "value"
            entity[dynamicMember: "remove"] = "obsolete"
        }
        graph.sync()
        for entity in entities { XCTAssertNotNil(entity[dynamicMember: "remove"]) }
        try graph.transaction { scoped in
            for entity in Search<Entity>(graph: scoped).where(.type("Bill")).sync() {
                entity[dynamicMember: "remove"] = nil
                entity[dynamicMember: "keep"] = "updated"
            }
        }
        XCTAssertFalse(graph.managedObjectContext.hasChanges, "dirty immediately after commit")
        for entity in entities {
            XCTAssertNil(entity[dynamicMember: "remove"])
            XCTAssertEqual(entity[dynamicMember: "keep"] as? String, "updated")
        }
        let delivered = expectation(description: "merge delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { delivered.fulfill() }
        wait(for: [delivered], timeout: 5)
        for entity in entities {
            XCTAssertNil(entity[dynamicMember: "remove"])
            XCTAssertEqual(entity[dynamicMember: "keep"] as? String, "updated")
        }
        XCTAssertFalse(graph.managedObjectContext.hasChanges, "deleted=\(graph.managedObjectContext.deletedObjects.count)")
        XCTAssertNoThrow(try graph.transaction { _ in })
    }

    func testVerboseDiagnosticIdentifiesPropertyOwnerAndBothValuesWithoutSaving() throws {
        var config = GraphStoreConfiguration()
        config.name = UUID().uuidString
        config.backend = .inMemory
        let graph = Graph(configuration: config, migrationEnabled: false)
        let ready = expectation(description: "ready")
        graph.whenReady { _ in ready.fulfill() }
        wait(for: [ready], timeout: 10)
        let owner = Entity("Conteggi_abitazione", graph: graph)
        owner[dynamicMember: "codice_anno"] = "fixture-owner"
        owner[dynamicMember: "dato"] = 10.0
        graph.sync()
        owner[dynamicMember: "dato"] = 20.0
        let before = graph.managedObjectContext.updatedObjects
        let diagnostic = try XCTUnwrap(graph.pendingChangeDiagnostics(checkpoint: "test.afterCounts"))
        let details = diagnostic.debugDetails.joined(separator: "\n")
        for expected in ["property=dato", "ownerType=Conteggi_abitazione", "fixture-owner", "previous=10", "current=20", "ownerID="] {
            XCTAssertTrue(details.contains(expected), "Missing \(expected): \(details)")
        }
        XCTAssertFalse(diagnostic.summary.contains("fixture-owner"))
        XCTAssertEqual(graph.managedObjectContext.updatedObjects, before)
        XCTAssertEqual(owner[dynamicMember: "dato"] as? Double, 20)
        XCTAssertThrowsError(try graph.transaction { _ in })
        graph.managedObjectContext.rollback()
        XCTAssertEqual(owner[dynamicMember: "dato"] as? Double, 10)
        owner[dynamicMember: "dato"] = nil
        let deletedBefore = graph.managedObjectContext.deletedObjects
        let deletion = try XCTUnwrap(graph.pendingChangeDiagnostics(checkpoint: "test.afterDeletion"))
        XCTAssertTrue(deletion.debugDetails.contains { $0.contains("delete schema=ManagedEntityProperty") && $0.contains("property=dato") })
        XCTAssertEqual(graph.managedObjectContext.deletedObjects, deletedBefore)
        graph.managedObjectContext.rollback()
        XCTAssertEqual(owner[dynamicMember: "dato"] as? Double, 10)
    }

    private final class TransactionEvents: GraphEventDelegate {
        var diagnostics: [GraphTransactionDiagnostics] = []
        var descriptions: [String] = []
        func graph(_ graph: Graph, didReceive event: GraphEvent) {
            if case .error(let failure) = event,
               case .transaction(_, let details) = failure {
                diagnostics.append(details)
                descriptions.append(failure.localizedDescription)
            }
        }
    }

    func testPendingChangesDiagnosticPreservesErrorAndOmitsPayload() throws {
        var config = GraphStoreConfiguration()
        config.name = UUID().uuidString
        config.backend = .inMemory
        let graph = Graph(configuration: config, migrationEnabled: false)
        let ready = expectation(description: "ready")
        graph.whenReady { _ in ready.fulfill() }
        wait(for: [ready], timeout: 10)
        let events = TransactionEvents()
        graph.eventDelegate = events
        let entity = Entity("PRIVATE_DOMAIN_TYPE", graph: graph)
        entity[dynamicMember: "PRIVATE_DYNAMIC_KEY"] = "PRIVATE_PAYLOAD_DO_NOT_LOG"
        let before = graph.managedObjectContext.insertedObjects
        XCTAssertThrowsError(try graph.transaction { _ in XCTFail("Body must not execute") }) { error in
            guard case GraphTransactionError.pendingUserChanges = error else { XCTFail("Error type changed"); return }
            XCTAssertEqual((error as NSError).code, 1)
            XCTAssertTrue(error.localizedDescription.contains("pendingUserChanges"))
        }
        let details = try XCTUnwrap(events.diagnostics.first)
        XCTAssertEqual(details.checkpoint, "beforeBody")
        XCTAssertEqual(details.containerKind, "local")
        XCTAssertEqual(details.inserted, before.count)
        XCTAssertFalse(details.groups.isEmpty)
        let message = events.descriptions.joined()
        XCTAssertTrue(message.contains("keys="))
        for secret in ["PRIVATE_DOMAIN_TYPE", "PRIVATE_DYNAMIC_KEY", "PRIVATE_PAYLOAD_DO_NOT_LOG", config.name] {
            XCTAssertFalse(message.contains(secret))
        }
        XCTAssertEqual(graph.managedObjectContext.insertedObjects, before)
        XCTAssertTrue(graph.managedObjectContext.hasChanges)
        graph.managedObjectContext.rollback()
    }
    override func setUp() { super.setUp(); GraphMigrationManager.resetForTesting() }
    override func tearDown() { GraphMigrationManager.resetForTesting(); super.tearDown() }
    private struct Delayed: GraphMigration {
        let id: String
        let run: (@escaping (GraphMigrationResult) -> Void) -> Void
        func needsRun(at phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: inout GraphMigrationContext?) -> Bool {
            configuration?.name == id && phase == .preInit
        }
        func handlePhase(_ phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: GraphMigrationContext?, completion: @escaping (GraphMigrationResult) -> Void) {
            if phase == .preInit { run(completion) } else { completion(.done) }
        }
    }

    func testBootstrapWaitsBeforeCreatingStore() throws {
        var config = GraphStoreConfiguration()
        config.name = UUID().uuidString
        config.location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        config.waitsForApplicationMigrations = true
        var release: ((GraphMigrationResult) -> Void)?
        GraphMigrationManager.registerMigration(Delayed(id: config.name) { release = $0 })
        let graph = Graph(configuration: config)
        XCTAssertNil(graph.managedObjectContext)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.storeURL.path))
        XCTAssertNotNil(release)
        let ready = expectation(description: "ready after barrier")
        graph.whenReady { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            ready.fulfill()
        }
        release?(.done)
        wait(for: [ready], timeout: 10)
        XCTAssertTrue(graph.isReady)
    }

    func testBootstrapFailureDoesNotOpenStore() throws {
        var config = GraphStoreConfiguration()
        config.name = UUID().uuidString
        config.location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        config.waitsForApplicationMigrations = true
        GraphMigrationManager.registerMigration(Delayed(id: config.name) { $0(.error(GraphTransactionError.storeChanged)) })
        let graph = Graph(configuration: config)
        let ready = expectation(description: "failed readiness")
        graph.whenReady { result in
            guard case .failure(.applicationMigrationFailed) = result else { XCTFail("Expected failure"); ready.fulfill(); return }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 10)
        XCTAssertNil(graph.managedObjectContext)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.storeURL.path))
    }

    func testTransactionCommitsMarkerWithDataAndRollsBackOnFailure() throws {
        var config = GraphStoreConfiguration()
        config.name = UUID().uuidString
        config.backend = .inMemory
        let graph = Graph(configuration: config, migrationEnabled: false)
        let ready = expectation(description: "ready")
        graph.whenReady { _ in ready.fulfill() }
        wait(for: [ready], timeout: 10)
        XCTAssertThrowsError(try graph.transaction { scoped in
            _ = Entity("Bill", graph: scoped)
            throw GraphTransactionError.storeChanged
        })
        XCTAssertEqual(Search<Entity>(graph: graph).where(.type("*")).sync().count, 0)
        try graph.transaction { scoped in
            _ = Entity("Bill", graph: scoped)
            _ = Entity("Marker", graph: scoped)
        }
        XCTAssertEqual(Search<Entity>(graph: graph).where(.type("*")).sync().count, 2)
        let bill = try XCTUnwrap(Search<Entity>(graph: graph).where(.type("Bill")).sync().first)
        let id = bill.id
        try graph.transaction { scoped in
            let same = try XCTUnwrap(Search<Entity>(graph: scoped).where(.type("Bill")).sync().first)
            same[dynamicMember: "edited"] = true
            same.setCreatedDate(Date(timeIntervalSince1970: 123))
        }
        XCTAssertEqual(Search<Entity>(graph: graph).where(.type("Bill")).sync().first?.id, id)
        XCTAssertEqual(Search<Entity>(graph: graph).where(.type("Bill")).sync().first?.createdDate, Date(timeIntervalSince1970: 123))
    }

    func testUnsavedUserEditDuringBodyCancelsCommitWithoutLosingEdit() throws {
        var config = GraphStoreConfiguration()
        config.name = UUID().uuidString
        config.backend = .inMemory
        let graph = Graph(configuration: config, migrationEnabled: false)
        let ready = expectation(description: "ready")
        graph.whenReady { _ in ready.fulfill() }
        wait(for: [ready], timeout: 10)
        let events = TransactionEvents()
        graph.eventDelegate = events
        let finished = expectation(description: "concurrent edit protected")
        DispatchQueue.global().async {
            do {
                try graph.transaction { scoped in
                    _ = Entity("MustRollback", graph: scoped)
                    graph.managedObjectContext.performAndWait { _ = Entity("UserEdit", graph: graph) }
                }
                XCTFail("Expected pending edit conflict")
            } catch GraphTransactionError.pendingUserChanges {
                graph.managedObjectContext.performAndWait {
                    XCTAssertTrue(graph.managedObjectContext.hasChanges)
                    XCTAssertEqual(Search<Entity>(graph: graph).where(.type("UserEdit")).sync().count, 1)
                    XCTAssertTrue(Search<Entity>(graph: graph).where(.type("MustRollback")).sync().isEmpty)
                    graph.managedObjectContext.rollback()
                }
            } catch { XCTFail("\(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(events.diagnostics.first?.checkpoint, "beforeCommit")
        XCTAssertEqual(events.diagnostics.first?.inserted, 1)
    }

    func testSQLiteGenerationDetectsConcurrentInsertion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let graph = Graph(storeURL: root.appendingPathComponent("test.sqlite"), migrationEnabled: false)
        let ready = expectation(description: "SQLite ready")
        graph.whenReady { _ in ready.fulfill() }
        wait(for: [ready], timeout: 10)
        try graph.transaction { scoped in _ = Entity("Original", graph: scoped) }
        XCTAssertThrowsError(try graph.transaction { scoped in
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = scoped.managedObjectContext.persistentStoreCoordinator
            try context.performAndWait {
                let writer = Graph(transactionContext: context, configuration: scoped.configuration)
                _ = Entity("Concurrent", graph: writer)
                try context.save()
            }
            _ = Entity("MustRollback", graph: scoped)
        }) { error in
            guard case GraphTransactionError.storeChanged = error else { XCTFail("Unexpected \(error)"); return }
        }
        XCTAssertEqual(try graph.transaction { scoped in Search<Entity>(graph: scoped).where(.type("MustRollback")).sync().count }, 0)
        XCTAssertEqual(try graph.transaction { scoped in Search<Entity>(graph: scoped).where(.type("Concurrent")).sync().count }, 1)
    }
}

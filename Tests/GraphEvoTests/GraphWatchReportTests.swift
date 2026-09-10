import CoreData
import XCTest
@testable import GraphEvo

final class GraphWatchReportTests: XCTestCase {
    private final class ReportCollector {
        var reports: [GraphWatchReport] = []
        var onReport: ((GraphWatchReport) -> Void)?

        func receive(_ report: GraphWatchReport) {
            reports.append(report)
            onReport?(report)
        }
    }

    private func makeGraph() -> Graph {
        var configuration = GraphStoreConfiguration()
        configuration.name = "WatchReport-\(UUID().uuidString)"
        return Graph(configuration: configuration, migrationEnabled: false)
    }

    private func install(_ collector: ReportCollector, on graph: Graph) {
        graph.watchReportCompletion = { report, _ in
            if let report { collector.receive(report) }
        }
    }

    func testCompletionDeliversReportAndNilErrorOnLocalBatch() {
        let graph = makeGraph()
        let received = expectation(description: "completion report")
        graph.watchReportSources = [.local]
        graph.watchReportCompletion = { report, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNotNil(report)
            XCTAssertNil(error)
            if let report {
                XCTAssertEqual(report.source, .local)
                XCTAssertFalse(report.events.isEmpty)
            }
            received.fulfill()
        }

        _ = Entity("Completion", graph: graph)
        graph.sync()
        wait(for: [received], timeout: 2)
    }

    func testLocalSaveProducesOneGraphLevelReportWithAllNodeFamilies() {
        let graph = makeGraph()
        let delegate = ReportCollector()
        let received = expectation(description: "local report")
        delegate.onReport = { report in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(report.source, .local)
            received.fulfill()
        }
        install(delegate, on: graph)

        let subject = Entity("Person", graph: graph)
        subject[dynamicMember: "name"] = "Ada"
        subject.add(tags: "active").add(to: "people")
        let object = Entity("Person", graph: graph)
        let relationship = subject.is(relationship: "knows")
        relationship.object = object
        relationship[dynamicMember: "weight"] = 1
        relationship.add(tags: "social").add(to: "links")
        let action = subject.will(action: "message").add(objects: object)
        action[dynamicMember: "body"] = "Hello"
        action.add(tags: "outgoing").add(to: "activity")

        graph.sync()
        wait(for: [received], timeout: 2)

        XCTAssertEqual(delegate.reports.count, 1)
        let events = delegate.reports[0].events
        XCTAssertTrue(events.contains { if case .insertedEntity = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .insertedRelationship = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .insertedAction = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedEntityProperty(_, "name", _) = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedEntityTag(_, "active") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedEntityToGroup(_, "people") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedRelationshipProperty(_, "weight", _) = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedRelationshipTag(_, "social") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedRelationshipToGroup(_, "links") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedActionProperty(_, "body", _) = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedActionTag(_, "outgoing") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedActionToGroup(_, "activity") = $0 { return true }; return false })
    }

    func testLocalDeletionKeepsGraphObjectAndIsDeliveredWithTheSaveBatch() {
        let graph = makeGraph()
        let entity = Entity("Temporary", graph: graph)
        graph.sync()

        let delegate = ReportCollector()
        let received = expectation(description: "delete report")
        delegate.onReport = { _ in received.fulfill() }
        install(delegate, on: graph)

        entity.delete()
        XCTAssertTrue(delegate.reports.isEmpty, "The batch must wait for the save boundary")
        graph.sync()
        wait(for: [received], timeout: 2)

        guard case .deletedEntity(let deleted)? = delegate.reports.first?.events.first(where: {
            if case .deletedEntity = $0 { return true }
            return false
        }) else {
            return XCTFail("Missing deleted Entity wrapper")
        }
        XCTAssertTrue(deleted === entity || deleted.managedNode === entity.managedNode)
    }

    func testCloudOnlySelectionAndLegacyWatcherRemainParallel() {
        let graph = makeGraph()
        let entity = Entity("RemoteNote", graph: graph)
        graph.sync()

        let reportDelegate = ReportCollector()
        let reportReceived = expectation(description: "cloud report")
        reportDelegate.onReport = { report in
            XCTAssertEqual(report.source, .cloud)
            reportReceived.fulfill()
        }
        graph.watchReportSources = [.cloud]
        install(reportDelegate, on: graph)

        final class LegacyDelegate: NSObject, GraphEntityDelegate {
            let expectation: XCTestExpectation
            init(_ expectation: XCTestExpectation) { self.expectation = expectation }
            func graph(_ graph: Graph, inserted entity: Entity, source: GraphSource) {
                guard source == .cloud else { return }
                expectation.fulfill()
            }
        }
        let legacyReceived = expectation(description: "legacy cloud callback")
        let legacyDelegate = LegacyDelegate(legacyReceived)
        let watcher = Watch<Entity>(graph: graph).where(.type("RemoteNote"))
        watcher.delegate = legacyDelegate

        NotificationCenter.default.post(
            name: .GraphEvoSimulatedRemoteChange,
            object: graph.managedObjectContext,
            userInfo: [NSInsertedObjectsKey: NSSet(object: entity.managedNode)]
        )

        wait(for: [reportReceived, legacyReceived], timeout: 2)
        XCTAssertEqual(reportDelegate.reports.count, 1)
        XCTAssertEqual(reportDelegate.reports.first?.events.count, 1)
        withExtendedLifetime(watcher) {}
        withExtendedLifetime(legacyDelegate) {}
    }

    func testEmptyAndUnselectedSourcesDoNotProduceReports() {
        let graph = makeGraph()
        let delegate = ReportCollector()
        graph.watchReportSources = [.cloud]
        install(delegate, on: graph)

        _ = Entity("LocalOnly", graph: graph)
        graph.sync()
        NotificationCenter.default.post(
            name: .GraphEvoSimulatedRemoteChange,
            object: graph.managedObjectContext,
            userInfo: [:]
        )

        XCTAssertTrue(delegate.reports.isEmpty)
    }

    func testDeterministicOrderingDoesNotDependOnInputSetOrder() throws {
        let graph = makeGraph()
        let first = Entity("B", graph: graph)
        let second = Entity("A", graph: graph)
        graph.sync()

        let firstEnvelope = try XCTUnwrap(GraphWatchEventMaterializer.materialize(
            object: first.managedNode,
            operation: .insert,
            source: .cloud,
            transactionIndex: 2,
            changeIndex: 0
        ))
        let secondEnvelope = try XCTUnwrap(GraphWatchEventMaterializer.materialize(
            object: second.managedNode,
            operation: .insert,
            source: .cloud,
            transactionIndex: 1,
            changeIndex: 0
        ))

        let ordered = [firstEnvelope, secondEnvelope].sorted { $0.isOrdered(before: $1) }
        XCTAssertTrue(ordered[0].owner === second.managedNode)
        XCTAssertTrue(ordered[1].owner === first.managedNode)
    }

    func testUpdatesAndRemovalsCoverEveryNodeFamily() {
        let graph = makeGraph()
        let subject = Entity("Person", graph: graph)
        let object = Entity("Person", graph: graph)
        subject[dynamicMember: "name"] = "Before"
        subject.add(tags: "entity-tag").add(to: "entity-group")
        let relationship = subject.is(relationship: "knows")
        relationship.object = object
        relationship[dynamicMember: "weight"] = 1
        relationship.add(tags: "relationship-tag").add(to: "relationship-group")
        let action = subject.will(action: "message").add(objects: object)
        action[dynamicMember: "body"] = "Before"
        action.add(tags: "action-tag").add(to: "action-group")
        graph.sync()

        let delegate = ReportCollector()
        let updateReport = expectation(description: "update report")
        let removalReport = expectation(description: "removal report")
        delegate.onReport = { report in
            if delegate.reports.count == 1 { updateReport.fulfill() }
            if delegate.reports.count == 2 { removalReport.fulfill() }
        }
        install(delegate, on: graph)

        subject[dynamicMember: "name"] = "After"
        relationship[dynamicMember: "weight"] = 2
        relationship.object = subject
        action[dynamicMember: "body"] = "After"
        graph.sync()

        subject[dynamicMember: "name"] = nil
        subject.remove(tags: "entity-tag").remove(from: "entity-group")
        relationship[dynamicMember: "weight"] = nil
        relationship.remove(tags: "relationship-tag").remove(from: "relationship-group")
        action[dynamicMember: "body"] = nil
        action.remove(tags: "action-tag").remove(from: "action-group")
        graph.sync()

        wait(for: [updateReport, removalReport], timeout: 2)
        let updates = delegate.reports[0].events
        XCTAssertTrue(updates.contains { if case .updatedEntityProperty(_, "name", _) = $0 { return true }; return false })
        XCTAssertTrue(updates.contains { if case .updatedRelationship = $0 { return true }; return false })
        XCTAssertTrue(updates.contains { if case .updatedRelationshipProperty(_, "weight", _) = $0 { return true }; return false })
        XCTAssertTrue(updates.contains { if case .updatedActionProperty(_, "body", _) = $0 { return true }; return false })

        let removals = delegate.reports[1].events
        XCTAssertTrue(removals.contains { if case .removedEntityProperty(_, "name", _) = $0 { return true }; return false })
        XCTAssertTrue(removals.contains { if case .removedEntityTag(_, "entity-tag") = $0 { return true }; return false })
        XCTAssertTrue(removals.contains { if case .removedEntityFromGroup(_, "entity-group") = $0 { return true }; return false })
        XCTAssertTrue(removals.contains { if case .removedRelationshipProperty(_, "weight", _) = $0 { return true }; return false })
        XCTAssertTrue(removals.contains { if case .removedRelationshipTag(_, "relationship-tag") = $0 { return true }; return false })
        XCTAssertTrue(removals.contains { if case .removedRelationshipFromGroup(_, "relationship-group") = $0 { return true }; return false })
        XCTAssertTrue(removals.contains { if case .removedActionProperty(_, "body", _) = $0 { return true }; return false })
        XCTAssertTrue(removals.contains { if case .removedActionTag(_, "action-tag") = $0 { return true }; return false })
        XCTAssertTrue(removals.contains { if case .removedActionFromGroup(_, "action-group") = $0 { return true }; return false })
    }

    func testDeletingEveryNodeFamilyProducesTypedDeletionEvents() {
        let graph = makeGraph()
        let first = Entity("Person", graph: graph)
        let second = Entity("Person", graph: graph)
        let relationship = first.is(relationship: "knows")
        relationship.object = second
        let action = first.will(action: "message").add(objects: second)
        graph.sync()

        let delegate = ReportCollector()
        let received = expectation(description: "typed deletions")
        delegate.onReport = { _ in received.fulfill() }
        install(delegate, on: graph)

        relationship.delete()
        action.delete()
        first.delete()
        graph.sync()
        wait(for: [received], timeout: 2)

        let events = delegate.reports[0].events
        XCTAssertTrue(events.contains { if case .deletedEntity = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .deletedRelationship = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .deletedAction = $0 { return true }; return false })
    }

    func testMaterializationFailureIsReportedAndOtherEventsContinue() {
        final class EventDelegate: GraphEventDelegate {
            var failures: [GraphFailure] = []
            func graph(_ graph: Graph, didReceive event: GraphEvent) {
                if case .error(let failure) = event { failures.append(failure) }
            }
        }

        let graph = makeGraph()
        let valid = Entity("Valid", graph: graph)
        graph.sync()
        let invalid = NSEntityDescription.insertNewObject(
            forEntityName: "ManagedEntityProperty",
            into: graph.managedObjectContext
        )
        invalid.setValue("orphan", forKey: "name")
        invalid.setValue("value", forKey: "object")

        let reports = ReportCollector()
        let reportReceived = expectation(description: "partial report")
        reports.onReport = { _ in reportReceived.fulfill() }
        let events = EventDelegate()
        install(reports, on: graph)
        graph.eventDelegate = events

        NotificationCenter.default.post(
            name: .GraphEvoSimulatedRemoteChange,
            object: graph.managedObjectContext,
            userInfo: [NSInsertedObjectsKey: NSSet(array: [invalid, valid.managedNode])]
        )
        wait(for: [reportReceived], timeout: 2)

        XCTAssertEqual(reports.reports.first?.events.count, 1)
        XCTAssertTrue(events.failures.contains {
            if case .watchEventMaterialization(source: .cloud, underlying: _) = $0 { return true }
            return false
        })
        graph.managedObjectContext.rollback()
    }

    func testPersistentHistoryTokenIsPersistedBeforeCloudReportDelivery() throws {
        let graph = makeGraph()
        graph.ph_debug_clearToken()
        let delegate = ReportCollector()
        let received = expectation(description: "persistent history report")
        delegate.onReport = { report in
            XCTAssertEqual(report.source, .cloud)
            XCTAssertTrue(graph.ph_debug_lastTokenExists())
            received.fulfill()
        }
        graph.watchReportSources = [.cloud]
        install(delegate, on: graph)

        let background = try XCTUnwrap(graph.newBackgroundContext())
        background.performAndWait {
            background.transactionAuthor = "REMOTE-WATCH-REPORT-TEST"
            _ = ManagedEntity("Remote", managedObjectContext: background)
            try! background.save()
        }

        graph.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        wait(for: [received], timeout: 3)
        XCTAssertEqual(delegate.reports.count, 1)
    }

    func testGraphsSharingAContextReceiveOneReportPerInstance() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "SharedWatchReport-\(UUID().uuidString)"
        let first = Graph(configuration: configuration, migrationEnabled: false)
        let second = Graph(configuration: configuration, migrationEnabled: false)
        XCTAssertTrue(first.managedObjectContext === second.managedObjectContext)

        let firstDelegate = ReportCollector()
        let secondDelegate = ReportCollector()
        let firstReceived = expectation(description: "first graph report")
        let secondReceived = expectation(description: "second graph report")
        firstDelegate.onReport = { report in
            XCTAssertTrue(report.graph === first)
            firstReceived.fulfill()
        }
        secondDelegate.onReport = { report in
            XCTAssertTrue(report.graph === second)
            secondReceived.fulfill()
        }
        install(firstDelegate, on: first)
        install(secondDelegate, on: second)

        _ = Entity("Shared", graph: first)
        first.sync()
        wait(for: [firstReceived, secondReceived], timeout: 2)

        XCTAssertEqual(firstDelegate.reports.count, 1)
        XCTAssertEqual(secondDelegate.reports.count, 1)
    }
}

import XCTest
@testable import GraphEvo

final class GraphDedupEngineTests: XCTestCase {
    private struct PreferCanonical: DedupSurvivorSelector {
        func choosePreferred(_ lhs: Entity, _ rhs: Entity) -> Entity {
            let lhsCanonical = (lhs[dynamicMember: "source"] as? String) == "canonical"
            let rhsCanonical = (rhs[dynamicMember: "source"] as? String) == "canonical"
            if lhsCanonical != rhsCanonical {
                return lhsCanonical ? lhs : rhs
            }
            return lhs.id < rhs.id ? lhs : rhs
        }
    }

    private struct CustomKeyProvider: DedupKeyProvider {
        func key(for entity: Entity) -> DedupKey? {
            guard entity.type == "Person",
                  let value = entity[dynamicMember: "email"] as? String else { return nil }
            return DedupKey(entityType: entity.type, namespace: "email", value: value.lowercased())
        }
    }

    private func makeGraph(_ name: String = "Dedup-\(UUID().uuidString)") -> Graph {
        var configuration = GraphStoreConfiguration()
        configuration.name = name
        configuration.backend = .inMemory
        return Graph(configuration: configuration, migrationEnabled: false)
    }

    private func configuration(
        keyProvider: any DedupKeyProvider = UUIDFieldKeyProvider(fields: ["Person": "uuid"]),
        policy: DedupLinkPolicy = .rewireAndDeduplicate
    ) -> GraphDedupConfiguration {
        GraphDedupConfiguration(
            keyProvider: keyProvider,
            survivorSelector: PreferCanonical(),
            linkPolicy: policy
        )
    }

    func testDeduplicatesThreeEntitiesAndMergesMetadata() throws {
        let graph = makeGraph()
        let first = Entity("Person", graph: graph)
        first[dynamicMember: "uuid"] = "person-1"
        first[dynamicMember: "source"] = "duplicate"
        first[dynamicMember: "firstOnly"] = "one"

        let canonical = Entity("Person", graph: graph)
        canonical[dynamicMember: "uuid"] = "person-1"
        canonical[dynamicMember: "source"] = "canonical"
        canonical[dynamicMember: "name"] = "Ada"
        canonical.add(tags: "canonical")

        let third = Entity("Person", graph: graph)
        third[dynamicMember: "uuid"] = "person-1"
        third[dynamicMember: "source"] = "duplicate"
        third[dynamicMember: "thirdOnly"] = "three"
        third.add(tags: "imported")

        graph.sync()
        let report = try GraphDedupEngine.deduplicate(in: graph, configuration: configuration())

        XCTAssertEqual(report.duplicateGroups, 1)
        XCTAssertEqual(report.mergedEntities, 2)
        XCTAssertEqual(report.deletedEntities, 2)
        let people = Search<Entity>(graph: graph).where(.type("Person")).sync()
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0][dynamicMember: "name"] as? String, "Ada")
        XCTAssertEqual(people[0][dynamicMember: "firstOnly"] as? String, "one")
        XCTAssertEqual(people[0][dynamicMember: "thirdOnly"] as? String, "three")
        XCTAssertTrue(people[0].has(tags: "canonical", "imported"))
    }

    func testCustomKeyProviderAndUnkeyedEntitiesAreSkipped() throws {
        let graph = makeGraph()
        let first = Entity("Person", graph: graph)
        first[dynamicMember: "email"] = "ADA@example.com"
        let second = Entity("Person", graph: graph)
        second[dynamicMember: "email"] = "ada@example.com"
        let unkeyed = Entity("Legacy", graph: graph)
        unkeyed[dynamicMember: "value"] = "untouched"
        graph.sync()

        let report = try GraphDedupEngine.deduplicate(
            in: graph,
            configuration: configuration(keyProvider: CustomKeyProvider())
        )

        XCTAssertEqual(report.duplicateGroups, 1)
        XCTAssertEqual(report.unkeyedEntities, 1)
        XCTAssertEqual(Search<Entity>(graph: graph).where(.type("Person")).sync().count, 1)
        XCTAssertEqual(Search<Entity>(graph: graph).where(.type("Legacy")).sync().count, 1)
    }

    func testIncomingOutgoingRelationshipsAndActionsAreCanonicalized() throws {
        let graph = makeGraph()
        let survivor = Entity("Person", graph: graph)
        survivor[dynamicMember: "uuid"] = "person-1"
        survivor[dynamicMember: "source"] = "canonical"
        let duplicate = Entity("Person", graph: graph)
        duplicate[dynamicMember: "uuid"] = "person-1"
        duplicate[dynamicMember: "source"] = "duplicate"
        let duplicateID = duplicate.id
        let other = Entity("Person", graph: graph)
        other[dynamicMember: "uuid"] = "person-2"

        other.is(relationship: "knows").object = duplicate
        duplicate.is(relationship: "likes").object = other
        let action = duplicate.will(action: "send")
        action.add(objects: other)
        let secondAction = survivor.will(action: "send")
        secondAction.add(objects: other)
        graph.sync()

        let report = try GraphDedupEngine.deduplicate(in: graph, configuration: configuration())

        XCTAssertEqual(report.deletedEntities, 1)
        let relationships = Search<Relationship>(graph: graph).where(.type("*")).sync()
        XCTAssertEqual(relationships.count, 2)
        XCTAssertTrue(relationships.allSatisfy { $0.subject?.id != duplicateID && $0.object?.id != duplicateID })
        let actions = Search<Action>(graph: graph).where(.type("*")).sync()
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].subjects.first?.id, survivor.id)
        XCTAssertEqual(actions[0].objects.first?.id, other.id)
    }

    func testSkipPreservesDuplicateWithUnrewritableLinks() throws {
        let graph = makeGraph()
        let first = Entity("Person", graph: graph)
        first[dynamicMember: "uuid"] = "person-1"
        first[dynamicMember: "source"] = "canonical"
        let duplicate = Entity("Person", graph: graph)
        duplicate[dynamicMember: "uuid"] = "person-1"
        let other = Entity("Person", graph: graph)
        other[dynamicMember: "uuid"] = "person-2"
        duplicate.is(relationship: "knows").object = other
        graph.sync()

        let report = try GraphDedupEngine.deduplicate(
            in: graph,
            configuration: configuration(policy: .skip)
        )

        XCTAssertEqual(report.skippedItems, 1)
        XCTAssertEqual(Search<Entity>(graph: graph).where(.type("Person")).sync().count, 3)
    }

    func testFailPolicyRejectsBeforeMutating() throws {
        let graph = makeGraph()
        let first = Entity("Person", graph: graph)
        first[dynamicMember: "uuid"] = "person-1"
        let duplicate = Entity("Person", graph: graph)
        duplicate[dynamicMember: "uuid"] = "person-1"
        first.is(relationship: "knows").object = duplicate
        graph.sync()

        XCTAssertThrowsError(
            try GraphDedupEngine.deduplicate(
                in: graph,
                configuration: configuration(policy: .fail)
            )
        )
        XCTAssertEqual(Search<Entity>(graph: graph).where(.type("Person")).sync().count, 2)
    }

    func testSecondRunIsIdempotent() throws {
        let graph = makeGraph()
        let first = Entity("Person", graph: graph)
        first[dynamicMember: "uuid"] = "person-1"
        let second = Entity("Person", graph: graph)
        second[dynamicMember: "uuid"] = "person-1"
        graph.sync()

        let configuration = self.configuration()
        _ = try GraphDedupEngine.deduplicate(in: graph, configuration: configuration)
        let secondReport = try GraphDedupEngine.deduplicate(in: graph, configuration: configuration)

        XCTAssertEqual(secondReport.duplicateGroups, 0)
        XCTAssertEqual(secondReport.deletedEntities, 0)
        XCTAssertEqual(secondReport.deletedRelationships, 0)
        XCTAssertEqual(secondReport.deletedActions, 0)
    }
}

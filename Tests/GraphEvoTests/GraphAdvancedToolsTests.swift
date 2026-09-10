import XCTest
@testable import GraphEvo

final class GraphAdvancedToolsTests: XCTestCase {
    private struct PreferCanonical: DedupSurvivorSelector {
        func choosePreferred(_ lhs: Entity, _ rhs: Entity) -> Entity {
            let lhsSource = lhs[dynamicMember: "source"] as? String
            return lhsSource == "canonical" ? lhs : rhs
        }
    }

    func testGraphMergeCopiesEntitiesRelationshipsActionsAndSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-Merge-\(UUID().uuidString)", isDirectory: true)
        let primaryDirectory = root.appendingPathComponent("primary", isDirectory: true)
        let secondaryDirectory = root.appendingPathComponent("secondary", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var primaryConfiguration = GraphStoreConfiguration()
        primaryConfiguration.name = "Primary"
        primaryConfiguration.location = primaryDirectory
        let primary = Graph(configuration: primaryConfiguration, migrationEnabled: false)

        var secondaryConfiguration = GraphStoreConfiguration()
        secondaryConfiguration.name = "Secondary"
        secondaryConfiguration.location = secondaryDirectory
        let secondary = Graph(configuration: secondaryConfiguration, migrationEnabled: false)

        let source = Entity("Person", graph: secondary)
        source[dynamicMember: "uuid"] = "person-1"
        let target = Entity("Person", graph: secondary)
        target[dynamicMember: "uuid"] = "person-2"
        source.is(relationship: "knows").object = target
        source.will(action: "message").add(objects: target)
        secondary.sync()

        let report = try GraphMergeEngine.merge(
            from: secondary,
            into: primary,
            uuidFieldMap: ["Person": "uuid"],
            sourceTag: "legacy"
        )

        XCTAssertEqual(report.importedEntities, 2)
        XCTAssertEqual(report.unmappedEntities, 0)
        XCTAssertEqual(report.recreatedRelationships, 1)
        XCTAssertEqual(report.recreatedActions, 1)

        let merged = Search<Entity>(graph: primary).where(.type("Person")).sync()
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.compactMap { $0[dynamicMember: "source"] as? String }.count, 2)
        XCTAssertEqual(
            Search<Relationship>(graph: primary).where(.type("knows")).sync().first?.object?.type,
            "Person"
        )
        XCTAssertEqual(
            Search<Action>(graph: primary).where(.type("message")).sync().first?.objects.count,
            1
        )
    }

    func testGraphDedupKeepsPreferredEntityAndRemovesDuplicate() throws {
        var configuration = GraphStoreConfiguration()
        configuration.name = "Dedup-\(UUID().uuidString)"
        let graph = Graph(configuration: configuration, migrationEnabled: false)

        let canonical = Entity("Person", graph: graph)
        canonical[dynamicMember: "uuid"] = "person-1"
        canonical[dynamicMember: "source"] = "canonical"
        let duplicate = Entity("Person", graph: graph)
        duplicate[dynamicMember: "uuid"] = "person-1"
        duplicate[dynamicMember: "source"] = "duplicate"
        let other = Entity("Person", graph: graph)
        other[dynamicMember: "uuid"] = "person-2"
        duplicate.is(relationship: "knows").object = other
        graph.sync()

        let dedupConfiguration = GraphDedupConfiguration(
            keyProvider: UUIDFieldKeyProvider(fields: ["Person": "uuid"]),
            survivorSelector: PreferCanonical()
        )
        let report = try GraphDedupEngine.deduplicate(in: graph, configuration: dedupConfiguration)

        let people = Search<Entity>(graph: graph).where(.type("Person")).sync()
        XCTAssertEqual(people.count, 2)
        XCTAssertEqual(report.deletedEntities, 1)
        XCTAssertEqual(
            people.first(where: { ($0[dynamicMember: "uuid"] as? String) == "person-1" })?[dynamicMember: "source"] as? String,
            "canonical"
        )
        let relationship = Search<Relationship>(graph: graph).where(.type("knows")).sync().first
        XCTAssertEqual(relationship?.subject?[dynamicMember: "source"] as? String, "canonical")
    }
}

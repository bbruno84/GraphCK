import XCTest
@testable import GraphEvo

final class StorePathResolutionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-Path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory,
           FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testDirectoryConfigurationUsesCanonicalBackendIndependentURL() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "primary"
        configuration.location = directory

        XCTAssertEqual(
            configuration.storeURL,
            directory.appendingPathComponent("GraphEvo_primary.sqlite")
        )
        XCTAssertEqual(configuration.resolvedStoreURL, configuration.storeURL)
    }

    func testDevelopmentEnvironmentUsesSuffixedStoreURL() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "primary"
        configuration.location = directory
        configuration.cloudKitContainerIdentifier = "iCloud.example"
        configuration.setResolvedEnvironment(.development)

        XCTAssertEqual(
            configuration.storeURL,
            directory.appendingPathComponent("GraphEvo_primary-dev.sqlite")
        )
        XCTAssertTrue(configuration.route.contains("Development"))
        XCTAssertTrue(configuration.legacyStoreURLs.isEmpty)
    }

    func testEnvironmentResolverAcceptsBuildEntitlementWithoutAnAccountCheck() {
        var configuration = GraphStoreConfiguration()
        configuration.cloudKitContainerIdentifier = "iCloud.example"

        let development = GraphStoreEnvironmentResolver.resolve(
            configuration: configuration,
            entitlementValue: "Development",
            runningUnderTests: false
        )
        let production = GraphStoreEnvironmentResolver.resolve(
            configuration: configuration,
            entitlementValue: "Production",
            runningUnderTests: false
        )

        XCTAssertEqual(try? development.get(), .development)
        XCTAssertEqual(try? production.get(), .production)
    }

    func testIOSSignatureFallbackDistinguishesDevelopmentAndProduction() {
        XCTAssertEqual(
            GraphStoreEnvironmentResolver.environmentFromIOSSignature(
                developmentSigned: true,
                hasSignedCloudKitService: true
            ),
            .development
        )
        XCTAssertEqual(
            GraphStoreEnvironmentResolver.environmentFromIOSSignature(
                developmentSigned: false,
                hasSignedCloudKitService: true
            ),
            .production
        )
        XCTAssertEqual(
            GraphStoreEnvironmentResolver.environmentFromIOSSignature(
                developmentSigned: nil,
                hasSignedCloudKitService: true
            ),
            .production
        )
        XCTAssertNil(
            GraphStoreEnvironmentResolver.environmentFromIOSSignature(
                developmentSigned: true,
                hasSignedCloudKitService: false
            )
        )
    }

    func testCloudKitReservationAllowsOnlyOneIndependentStore() {
        let key = "test-cloud-kit-\(UUID().uuidString)"
        XCTAssertTrue(GraphContextRegistry.shared.claimCloudKitStore(key: key))
        XCTAssertFalse(GraphContextRegistry.shared.claimCloudKitStore(key: "other-\(key)"))
        GraphContextRegistry.shared.releaseCloudKitStore(key: key)
        XCTAssertTrue(GraphContextRegistry.shared.claimCloudKitStore(key: "other-\(key)"))
        GraphContextRegistry.shared.releaseCloudKitStore(key: "other-\(key)")
    }

    func testExplicitSQLiteFileIsPreservedExactly() {
        let file = directory.appendingPathComponent("Existing.sqlite")
        let previousCloudKitIdentifier = Graph.cloudKitContainerIdentifier
        Graph.cloudKitContainerIdentifier = "iCloud.should-not-be-used"
        defer { Graph.cloudKitContainerIdentifier = previousCloudKitIdentifier }

        let graph = Graph(storeURL: file, migrationEnabled: false)
        let storeKey = graph.configuration.storeIdentityKey

        XCTAssertEqual(graph.configuration.storeURL, file)
        XCTAssertEqual(graph.configuration.resolvedStoreURL, file)
        XCTAssertEqual(graph.runtimeStoreURL, file)
        XCTAssertNil(graph.configuration.cloudKitContainerIdentifier)

        // The production registry intentionally owns contexts for reuse. Remove
        // this test's entry before deleting the temporary SQLite sidecars.
        GraphContextRegistry.shared.removeStore(forKey: storeKey)
    }

    func testGraphsForTheSameStoreReuseTheRegisteredContext() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "shared-context"
        configuration.location = directory

        let first = Graph(configuration: configuration, migrationEnabled: false)
        XCTAssertNotNil(first.managedObjectContext)

        let second = Graph(configuration: configuration, migrationEnabled: false)

        XCTAssertTrue(first.managedObjectContext === second.managedObjectContext)
        XCTAssertTrue(first.persistentContainer === second.persistentContainer)

        XCTAssertTrue(
            GraphContextRegistry.shared.claimObserver(
                graph: first,
                key: configuration.storeIdentityKey
            )
        )
        XCTAssertIdentical(
            GraphContextRegistry.shared.release(
                graph: first,
                key: configuration.storeIdentityKey
            ),
            second
        )

        GraphContextRegistry.shared.removeStore(forKey: configuration.storeIdentityKey)
    }

    func testConcurrentRegistryRegistrationRemainsAtomic() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "ConcurrentRegistry"
        configuration.backend = .inMemory
        let graph = Graph(configuration: configuration, migrationEnabled: false)
        let context = graph.managedObjectContext!
        let container = graph.persistentContainer
        let key = configuration.storeIdentityKey

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            GraphContextRegistry.shared.register(
                graph: graph,
                key: key,
                context: context,
                container: container,
                configuration: configuration
            )
        }

        XCTAssertTrue(GraphContextRegistry.shared.context(for: key) === context)
        XCTAssertTrue(GraphContextRegistry.shared.container(for: key) === container)
        XCTAssertEqual(GraphContextRegistry.shared.configuration(for: context)?.name, configuration.name)
        GraphContextRegistry.shared.removeStore(forKey: key)
    }

    func testConcurrentOpenOfSameStoreConvergesOnOneRegisteredContext() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "ConcurrentShared"
        configuration.location = directory
        let graphCount = 2
        var graphs = Array<Graph?>(repeating: nil, count: graphCount)
        let lock = NSLock()

        let openExpectation = expectation(description: "concurrent store opens complete")
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: graphCount) { index in
                let graph = Graph(configuration: configuration, migrationEnabled: false)
                lock.lock()
                graphs[index] = graph
                lock.unlock()
            }
            DispatchQueue.main.async { openExpectation.fulfill() }
        }
        wait(for: [openExpectation], timeout: 10)

        let openedGraphs = graphs.compactMap { $0 }
        XCTAssertEqual(openedGraphs.count, graphCount)
        XCTAssertTrue(openedGraphs.allSatisfy { $0.storeOpeningError == nil })
        let contexts = openedGraphs.compactMap(\.managedObjectContext)
        let containers = openedGraphs.compactMap(\.persistentContainer)
        XCTAssertEqual(contexts.count, graphCount)
        XCTAssertEqual(containers.count, graphCount)
        XCTAssertTrue(contexts.dropFirst().allSatisfy { $0 === contexts.first })
        XCTAssertTrue(containers.dropFirst().allSatisfy { $0 === containers.first })

        GraphContextRegistry.shared.removeStore(forKey: configuration.storeIdentityKey)
    }

    func testSameStoreNameInDifferentDirectoriesDoesNotReuseContext() throws {
        let otherDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-Path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: otherDirectory) }
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)

        var firstConfiguration = GraphStoreConfiguration()
        firstConfiguration.name = "same-name"
        firstConfiguration.location = directory

        var secondConfiguration = GraphStoreConfiguration()
        secondConfiguration.name = firstConfiguration.name
        secondConfiguration.location = otherDirectory

        let first = Graph(configuration: firstConfiguration, migrationEnabled: false)
        let second = Graph(configuration: secondConfiguration, migrationEnabled: false)

        XCTAssertNotNil(first.managedObjectContext)
        XCTAssertNotNil(second.managedObjectContext)
        XCTAssertFalse(first.managedObjectContext === second.managedObjectContext)
        XCTAssertNotEqual(firstConfiguration.storeIdentityKey, secondConfiguration.storeIdentityKey)

        GraphContextRegistry.shared.removeStore(forKey: firstConfiguration.storeIdentityKey)
        GraphContextRegistry.shared.removeStore(forKey: secondConfiguration.storeIdentityKey)
    }

    func testExistingLegacyRouteStoreIsReused() throws {
        var configuration = GraphStoreConfiguration()
        configuration.name = "legacy"
        configuration.location = directory
        let legacy = directory
            .appendingPathComponent("Local", isDirectory: true)
            .appendingPathComponent("legacy", isDirectory: true)
            .appendingPathComponent("GraphEvo_legacy.sqlite")
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: legacy)

        XCTAssertEqual(configuration.resolvedStoreURL, legacy)
    }

    func testConfiguredLegacyRouteWinsOverOlderDirectLegacyStore() throws {
        var configuration = GraphStoreConfiguration()
        configuration.name = "legacy-priority"
        configuration.location = directory

        let routeStore = directory
            .appendingPathComponent("Local/legacy-priority", isDirectory: true)
            .appendingPathComponent("GraphEvo_legacy-priority.sqlite")
        let directStore = directory.appendingPathComponent("Graph.sqlite")
        try FileManager.default.createDirectory(
            at: routeStore.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: routeStore)
        try Data().write(to: directStore)

        XCTAssertEqual(configuration.resolvedStoreURL, routeStore)
    }

    func testTwoDirectoriesDoNotShareTheSameRegistryIdentity() {
        var first = GraphStoreConfiguration()
        first.name = "same-name"
        first.location = directory.appendingPathComponent("one", isDirectory: true)

        var second = first
        second.location = directory.appendingPathComponent("two", isDirectory: true)

        XCTAssertNotEqual(first.storeIdentityKey, second.storeIdentityKey)
    }
}

import XCTest
@testable import GraphEvo

final class CloudKitConfigurationTests: XCTestCase {
    func testPublicEnvironmentResolutionDoesNotOpenOrMutateStore() throws {
        var configuration = GraphStoreConfiguration()
        configuration.cloudKitContainerIdentifier = "iCloud.explicit"
        configuration.location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let normalized = try configuration.resolvingEnvironment()
        XCTAssertNil(configuration.environment)
        XCTAssertEqual(normalized.environment, .development)
        XCTAssertTrue(normalized.storeFilename.hasSuffix("-dev.sqlite"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: normalized.resolvedStoreURL.path))
        XCTAssertEqual(try normalized.resolvingEnvironment().resolvedStoreURL, normalized.resolvedStoreURL)
        XCTAssertEqual(try GraphMigrationManager.normalizedConfigurationThrowing(configuration).resolvedStoreURL,
                       normalized.resolvedStoreURL)
    }

    func testPublicResolutionPreservesExplicitFileAndForcedLocalMode() throws {
        var configuration = GraphStoreConfiguration()
        configuration.location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        configuration.cloudKitContainerIdentifier = "iCloud.explicit"
        configuration.disablesCloudKit = true
        let normalized = try configuration.resolvingEnvironment()
        XCTAssertEqual(normalized.environment, .local)
        XCTAssertNil(normalized.cloudKitContainerIdentifier)
        XCTAssertEqual(normalized.resolvedStoreURL, configuration.location)
    }

    func testExplicitConfigurationWinsOverRuntimeAndInfoPlist() {
        var configuration = GraphStoreConfiguration()
        configuration.cloudKitContainerIdentifier = "iCloud.explicit"

        XCTAssertEqual(
            Graph.resolvedCloudKitContainerIdentifier(
                configuration: configuration,
                runtimeOverride: "iCloud.runtime",
                infoPlistValue: "iCloud.plist"
            ),
            "iCloud.explicit"
        )
    }

    func testRuntimeOverrideWinsOverInfoPlist() {
        let configuration = GraphStoreConfiguration()
        XCTAssertEqual(
            Graph.resolvedCloudKitContainerIdentifier(
                configuration: configuration,
                runtimeOverride: "iCloud.runtime",
                infoPlistValue: "iCloud.plist"
            ),
            "iCloud.runtime"
        )
    }

    func testInfoPlistIsUsedWhenNoExplicitValueExists() {
        let configuration = GraphStoreConfiguration()
        XCTAssertEqual(
            Graph.resolvedCloudKitContainerIdentifier(
                configuration: configuration,
                runtimeOverride: nil,
                infoPlistValue: " iCloud.plist "
            ),
            "iCloud.plist"
        )
    }

}

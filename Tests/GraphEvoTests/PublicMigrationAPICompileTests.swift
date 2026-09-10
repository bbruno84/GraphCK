import XCTest
import GraphEvo

final class PublicMigrationAPICompileTests: XCTestCase {
    func testDiagnosticTypesAndAPIsArePubliclyConsumable() throws {
        let entry = GraphMigrationLedgerEntry(
            schemaVersion: 1,
            operationID: "operation",
            generation: 1,
            migrationID: "migration",
            version: 1,
            state: .started,
            phase: "postMigration",
            requestedBy: .user,
            deviceID: "redacted-device",
            appVersion: "1.0",
            graphModelVersion: nil,
            backupReference: nil,
            previousOperationID: nil,
            decisionReason: .noCandidate,
            decisionSource: .localEvaluation,
            source: "localLedger",
            date: Date(),
            errorDescription: nil,
            storeScope: "scope",
            observedAt: nil,
            publishedAt: nil
        )
        XCTAssertEqual(entry.state, .started)
        _ = GraphMigrationManager.history
        _ = GraphMigrationManager.stateSnapshot
    }
}

import GraphEvo
import XCTest

final class PublicGraphWatchReportAPICompileTests: XCTestCase {
    func testBatchWatchAPIIsPubliclyConsumable() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "PublicWatchReport-\(UUID().uuidString)"
        let graph = Graph(configuration: configuration, migrationEnabled: false)
        graph.watchReportSources = [.cloud]
        graph.watchReportCompletion = { report, error in
            if let report {
                _ = report.graph
                _ = report.source
                _ = report.events
            }
            _ = error
        }

        let event: GraphWatchEvent = .insertedEntity(Entity("Public", graph: graph))
        if case .insertedEntity = event {} else { XCTFail("Unexpected event") }
        XCTAssertNotNil(graph.watchReportCompletion)
    }

    func testBatchWatchCompletionAPIIsPubliclyConsumable() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "PublicWatchCompletion-\(UUID().uuidString)"
        let graph = Graph(configuration: configuration, migrationEnabled: false)
        graph.watchReportSources = [.local, .cloud]
        graph.watchReportCompletion = { report, error in
            if let report {
                _ = report.graph
                _ = report.source
                _ = report.events
            }
            _ = error
        }

        let completion: GraphWatchReportCompletion? = graph.watchReportCompletion
        XCTAssertNotNil(completion)
    }
}

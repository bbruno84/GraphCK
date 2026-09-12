import Foundation

/// Internal identity used to isolate migration runtime state per store.
struct GraphStoreScope: Hashable, Codable, Sendable {
    let runtimeURL: String
    let logicalName: String
    let cloudKitContainerIdentifier: String?
    let environment: GraphStoreEnvironment
    let backend: String
    let graphModelVersion: Int?

    var logicalKey: String {
        [logicalName, cloudKitContainerIdentifier ?? "local", environment.rawValue,
         backend, graphModelVersion.map(String.init) ?? "unknown"].joined(separator: "|")
    }

    init(configuration: GraphStoreConfiguration) {
        runtimeURL = configuration.resolvedStoreURL.standardizedFileURL.path
        logicalName = configuration.name
        cloudKitContainerIdentifier = configuration.cloudKitContainerIdentifier
        environment = configuration.environment ?? .local
        backend = configuration.backend.coreDataType
        graphModelVersion = configuration.requiredGraphModelVersion
    }
}

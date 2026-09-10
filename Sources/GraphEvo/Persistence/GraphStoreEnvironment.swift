import Foundation
import Security

#if !os(macOS)
// SecTask is exported by Security on iOS, but its header is not shipped in
// the iOS SDK. Keep the declarations local so the entitlement lookup remains
// available to iOS clients without exposing another public API.
private typealias GraphSecTaskRef = CFTypeRef

@_silgen_name("SecTaskCreateFromSelf")
private func graphSecTaskCreateFromSelf(_ allocator: CFAllocator?) -> GraphSecTaskRef?

@_silgen_name("SecTaskCopyValueForEntitlement")
private func graphSecTaskCopyValueForEntitlement(
    _ task: GraphSecTaskRef,
    _ entitlement: CFString,
    _ error: UnsafeMutablePointer<CFError?>?
) -> CFTypeRef?
#endif

/// The persistence environment selected for a Graph store.
internal enum GraphStoreEnvironment: String, Codable, Equatable, Sendable {
    case development
    case production
    case local
}

internal enum GraphStoreEnvironmentResolver {
    static let entitlementKey = "com.apple.developer.icloud-container-environment"
    static let cloudServicesEntitlementKey = "com.apple.developer.icloud-services"
    static let developmentSigningEntitlementKey = "get-task-allow"

    static func resolve(
        configuration: GraphStoreConfiguration,
        entitlementValue: String? = readEntitlement(),
        developmentSigned: Bool? = readBooleanEntitlement(developmentSigningEntitlementKey),
        hasSignedCloudKitService: Bool = readCloudKitServices().contains("CloudKit"),
        runningUnderTests: Bool = Graph.isRunningUnderTests
    ) -> Result<GraphStoreEnvironment, GraphStoreOpeningError> {
        if configuration.disablesCloudKit || configuration.cloudKitContainerIdentifier == nil {
            return .success(.local)
        }

        // Test bundles intentionally use local Core Data containers. Treat
        // their CloudKit configurations as development for deterministic paths.
        if runningUnderTests {
            return .success(.development)
        }

        if let entitlementValue {
            switch entitlementValue.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "Development": return .success(.development)
            case "Production": return .success(.production)
            default: break
            }
        }

#if os(iOS)
#if targetEnvironment(simulator)
        return .success(.development)
#else
        if let environment = environmentFromIOSSignature(
            developmentSigned: developmentSigned,
            hasSignedCloudKitService: hasSignedCloudKitService
        ) {
            return .success(environment)
        }
        return .failure(.cloudKitEnvironmentUnavailable)
#endif
#else
        return .failure(.cloudKitEnvironmentUnavailable)
#endif
    }

    static func environmentFromIOSSignature(
        developmentSigned: Bool?,
        hasSignedCloudKitService: Bool
    ) -> GraphStoreEnvironment? {
        guard hasSignedCloudKitService else { return nil }
        return developmentSigned == true ? .development : .production
    }

    private static func readEntitlement() -> String? {
        readEntitlementValue(for: entitlementKey) as? String
    }

    private static func readBooleanEntitlement(_ key: String) -> Bool? {
        readEntitlementValue(for: key) as? Bool
    }

    private static func readCloudKitServices() -> [String] {
        readEntitlementValue(for: cloudServicesEntitlementKey) as? [String] ?? []
    }

    private static func readEntitlementValue(for key: String) -> Any? {
#if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(
            task,
            key as CFString,
            nil
        )
#else
        guard let task = graphSecTaskCreateFromSelf(nil) else { return nil }
        return graphSecTaskCopyValueForEntitlement(
            task,
            key as CFString,
            nil
        )
#endif
    }
}

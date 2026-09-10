//
//  GraphStoreConfiguration.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 21/09/25.
//

import Foundation
import CoreData

/// Configuration object for a Graph store.
/// Encapsulates all options for backend, location, versioning and CloudKit.
public struct GraphStoreConfiguration {
    public var name: String = "default"
    public var backend: GraphStoreBackend = .sqlite
    public var location: URL = File.path(.applicationSupportDirectory, path: "CosmicMind/Graph/")!
    public var appGroupIdentifier: String? = nil
    public var cloudKitContainerIdentifier: String? = nil
    public var requiredGraphModelVersion: Int = 1
    public var requiredAppDataVersion: Int = 1

    /// Internal marker used by `Graph(storeURL:)` to force a directly supplied
    /// SQLite file to remain local, regardless of global CloudKit settings.
    internal var disablesCloudKit = false
    internal private(set) var environment: GraphStoreEnvironment? = nil

    /// Public default initializer so this type can be used in default argument values.
    public init() {}

    // MARK: - Computed resolution

    /// Directory di default dello store, considerando App Group se presente.
    ///
    /// When `location` is an explicit SQLite file, the file itself always wins
    /// over the App Group fallback. This keeps `Graph(storeURL:)` lossless.
    public var resolvedLocation: URL {
        if isExplicitStoreFile {
            return location.deletingLastPathComponent()
        }
        if let id = appGroupIdentifier,
           let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            return base.appendingPathComponent("CosmicMind/Graph/")
        }
        return location
    }

    /// Nome file dello store.
    public var storeFilename: String {
        let suffix = environment == .development ? "-dev" : ""
        return "GraphEvo_\(name)\(suffix).sqlite"
    }

    /// Canonical URL of the store.
    ///
    /// A file passed in `location` is returned unchanged. Directory-based
    /// configurations use one backend-independent filename; the backend must
    /// not change the identity of the SQLite file.
    public var storeURL: URL {
        if isExplicitStoreFile {
            return location
        }
        return resolvedLocation.appendingPathComponent(storeFilename)
    }

    /// Route (Local vs Cloud) determined by the presence of a CloudKit container.
    public var route: String {
        guard cloudKitContainerIdentifier != nil else { return "Local/\(name)" }
        let environmentName: String
        switch environment {
        case .development: environmentName = "Development"
        case .production: environmentName = "Production"
        default: environmentName = "Unknown"
        }
        return "Cloud/\(environmentName)/\(name)"
    }

    /// Convenience versions wrapper.
    public var requiredVersions: Versions {
        Versions(graphModel: requiredGraphModelVersion, appData: requiredAppDataVersion)
    }

    /// Candidate URLs for stores created by earlier GraphEvo revisions.
    ///
    /// The route folders were an intermediate layout. They remain readable so
    /// upgrading GraphEvo does not silently create an empty store beside an
    /// existing one.
    public var legacyStoreURLs: [URL] {
        guard !isExplicitStoreFile, environment != .development else { return [] }

        let directLegacy = resolvedLocation.appendingPathComponent("Graph.sqlite")
        let local = resolvedLocation
            .appendingPathComponent("Local", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(storeFilename)
        let cloud = resolvedLocation
            .appendingPathComponent("Cloud", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(storeFilename)

        // Prefer the currently configured route when both legacy variants
        // exist, then inspect the other route for maximum compatibility.
        let preferred = route.hasPrefix("Cloud/") ? cloud : local
        let alternate = route.hasPrefix("Cloud/") ? local : cloud
        return [preferred, directLegacy, alternate]
    }

    /// Resolved store URL used by Core Data.
    ///
    /// Explicit files are never rewritten. For directory configurations the
    /// canonical location wins, followed by an existing legacy location.
    public var resolvedStoreURL: URL {
        let canonical = storeURL
        if isExplicitStoreFile || FileManager.default.fileExists(atPath: canonical.path) {
            return canonical
        }
        if let existingLegacy = legacyStoreURLs.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            return existingLegacy
        }
        return canonical
    }

    /// Stable key used by the in-process context registry.
    /// It identifies the resolved store, not just its public route/name.
    internal var storeIdentityKey: String {
        resolvedStoreURL.standardizedFileURL.path
    }

    internal mutating func setResolvedEnvironment(_ environment: GraphStoreEnvironment) {
        self.environment = environment
    }

    private var isExplicitStoreFile: Bool {
        location.pathExtension.caseInsensitiveCompare("sqlite") == .orderedSame
    }

    public struct Versions: Equatable {
        public var graphModel: Int?
        public var appData: Int?
        public init(graphModel: Int?, appData: Int?) {
            self.graphModel = graphModel
            self.appData = appData
        }
    }
}

/// Backend types supported by Graph.
public enum GraphStoreBackend {
    case sqlite
    case inMemory

    var coreDataType: String {
        switch self {
        case .sqlite: return NSSQLiteStoreType
        case .inMemory: return NSInMemoryStoreType
        }
    }
}

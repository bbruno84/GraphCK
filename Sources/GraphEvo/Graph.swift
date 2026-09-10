/*
 * The MIT License (MIT)
 *
 * Copyright (C) 2019, CosmicMind, Inc. <http://cosmicmind.com>.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

import CoreData
import CloudKit

extension Notification.Name {
    /// Custom remote-change notification used by tests to avoid clashing with the real CloudKit one.
    static let GraphEvoSimulatedRemoteChange = Notification.Name("GraphEvo.SimulatedRemoteChange")
}

// Internal marker used by RemoteChangeCoordinator. Existing callers that post
// GraphEvoSimulatedRemoteChange do not provide it and retain the legacy merge
// behavior.
internal let GraphEvoRemoteChangeAlreadyMergedKey = "GraphEvo.remoteChangeAlreadyMerged"

/// Errors reported when Graph refuses to open a persistent store.
/// GraphEvo never migrates or moves an incompatible existing store.
public enum GraphStoreOpeningError: LocalizedError {
    case incompatibleStore(URL)
    case unreadableStore(URL, underlying: Error)
    case failedToLoadStore(URL, underlying: Error)
    case cloudKitEnvironmentUnavailable
    case cloudKitGraphAlreadyActive
    case incompatibleRegisteredStore(URL)

    public var errorDescription: String? {
        switch self {
        case .incompatibleStore(let url):
            return "The store at \(url.path) is incompatible with the GraphEvo model. Migrate it in the application before opening GraphEvo."
        case .unreadableStore(let url, let error):
            return "The store at \(url.path) could not be inspected: \(error.localizedDescription)"
        case .failedToLoadStore(let url, let error):
            return "The store at \(url.path) could not be opened: \(error.localizedDescription)"
        case .cloudKitEnvironmentUnavailable:
            return "The CloudKit environment could not be determined for this build."
        case .cloudKitGraphAlreadyActive:
            return "A CloudKit Graph is already active in this process."
        case .incompatibleRegisteredStore(let url):
            return "The store at \(url.path) is already registered with an incompatible persistence configuration."
        }
    }
}

/// Availability state of a Graph instance's persistent store.
///
/// This state describes whether Core Data opened a usable store and context.
/// Migration outcomes are reported independently through `GraphEvent`; a
/// failed application migration does not make the store technically unusable.
public enum GraphReadiness {
    case initializing
    case ready
    case failed(GraphStoreOpeningError)
}

@objc(Graph)
public class Graph: NSObject {
    
    /// The configuration used to initialize this Graph.
    public private(set) var configuration: GraphStoreConfiguration

    /// Current availability of the persistent store and lifecycle setup.
    public internal(set) var readiness: GraphReadiness = .initializing

    /// Convenience check for callers that do not need the failure detail.
    public var isReady: Bool {
        if case .ready = readiness { return true }
        return false
    }
    
    /// Graph name.
    public var name: String { configuration.name }
    /// Graph route.
    public var route: String { configuration.route }
    /// Graph location.
    public var runtimeStoreURL: URL?
    public var location: URL {
        runtimeStoreURL ?? configuration.resolvedLocation
    }
    /// Graph type.
    public var type: String { configuration.backend.coreDataType }
    
    /// Graph should be rebuilded from cloud data
    public internal(set) var rebuildFromCloud: Bool?
    
    /// Worker managedObjectContext.
    public internal(set) var managedObjectContext: NSManagedObjectContext!

    /// Non-nil when GraphEvo refused or failed to open the configured store.
    /// In that case the existing store remains at its original URL untouched.
    public internal(set) var storeOpeningError: GraphStoreOpeningError?
    
    /// Number of items to return.
    public var batchSize = 0 // 0 == no limit
    
    /// Start the return results from this offset.
    public var batchOffset = 0
    
    /// Watch instances.
    public internal(set) lazy var watchers : [Watcher] = []

    /// Receives non-empty aggregated change reports on the main thread.
    public var watchReportCompletion: GraphWatchReportCompletion?

    /// Sources delivered to the batch completion.
    /// Legacy Watch callbacks are independent and remain active for all sources.
    public var watchReportSources: Set<GraphSource> = [.local, .cloud]

    internal var watchEventCoordinator: GraphWatchEventCoordinator?
    
    /// Optional delegate to receive iCloud availability updates (informational).
    public weak var cloudStatusDelegate: GraphCloudStatusDelegate? {
        didSet {
            if let status = lastCloudStatus, let delegate = cloudStatusDelegate {
                delegate.graph(self, iCloudStatusChanged: status)
            }
        }
    }

    /// M2: cache last known iCloud availability to notify late-bound delegates.
    private var lastCloudStatus: GraphCloudStatus?
    
    public weak var delegate: GraphDelegate?

    /// Receives GraphEvo state, warning and error events.
    /// Events are delivered on the main thread. Events emitted before a
    /// delegate is attached are retained and delivered when it is attached.
    public weak var eventDelegate: GraphEventDelegate? {
        didSet {
            flushPendingEvents()
        }
    }

    private var pendingEvents: [GraphEvent] = []

    internal var cloudSyncEventObserver: NSObjectProtocol?
    internal var cloudSyncStoreIdentifier: String?
    internal var cloudSyncInitialImportPending = false
    internal var pendingCloudKitEvents: [GraphCloudKitEventSnapshot] = []
    internal var cloudSyncUploadStartedEventIdentifiers = Set<UUID>()
    internal var cloudSyncUploadFinishedEventIdentifiers = Set<UUID>()
    internal var cloudSyncImportStartedEventIdentifiers = Set<UUID>()
    internal var cloudSyncImportFinishedEventIdentifiers = Set<UUID>()
    internal let cloudSyncStateLock = NSLock()
    
    /// M2: Optional override for the CloudKit container identifier.
    /// If set, this takes precedence over Info.plist and enables CloudKit sync without relying on plist UX.
    public static var cloudKitContainerIdentifier: String?

    /// Resolves CloudKit configuration once for a Graph instance.
    /// Explicit configuration wins over the runtime override, which wins over
    /// the application fallback in Info.plist.
    internal static func resolvedCloudKitContainerIdentifier(
        configuration: GraphStoreConfiguration,
        runtimeOverride: String?,
        infoPlistValue: String? = Bundle.main.object(forInfoDictionaryKey: "GraphCloudKitContainerIdentifier") as? String
    ) -> String? {
        guard !configuration.disablesCloudKit else { return nil }
        let candidates: [String?] = [configuration.cloudKitContainerIdentifier, runtimeOverride, infoPlistValue]
        return candidates
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .first
    }

    internal static var isRunningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }
    
    /// Keep a reference to the persistent container so background contexts can
    /// be created for both CloudKit and local stores.
    internal var persistentContainer: NSPersistentContainer?

    /// Serializes saves with administrative CloudKit operations such as purge.
    /// The lock is intentionally internal: the public API remains the only
    /// supported entry point for purging a store.
    internal let persistenceOperationLock = NSRecursiveLock()

    private let cloudPurgeStateLock = NSLock()
    private var cloudPurgeInProgress = false

    internal func beginCloudPurge() -> Bool {
        cloudPurgeStateLock.lock()
        defer { cloudPurgeStateLock.unlock() }
        guard !cloudPurgeInProgress else { return false }
        cloudPurgeInProgress = true
        return true
    }

    internal func endCloudPurge() {
        cloudPurgeStateLock.lock()
        cloudPurgeInProgress = false
        cloudPurgeStateLock.unlock()
    }

    internal var isCloudPurgeInProgress: Bool {
        cloudPurgeStateLock.lock()
        defer { cloudPurgeStateLock.unlock() }
        return cloudPurgeInProgress
    }

    /// Stable registry key captured when the store is opened.
    internal var contextRegistryKey: String?
    internal var cloudKitRegistryClaimed = false
    
    /**
     A reference to the graph completion handler.
     - Parameter success: A boolean indicating if the cloud connection
     is possible or not.
     */
    internal var completion: ((Bool, Error?) -> Void)?

    internal let migrationEnabled: Bool
    internal var readinessCompletions: [(Result<Graph, GraphStoreOpeningError>) -> Void] = []
    
    /// Deinitializer that removes the Graph from NSNotificationCenter.
    deinit {
        if migrationEnabled { GraphMigrationManager.unregisterKVSObservation(configuration: configuration) }
        removeCloudSyncEventObserver()
        if let key = contextRegistryKey,
           let promoted = GraphContextRegistry.shared.release(graph: self, key: key) {
            promoted.installRemoteObserverIfNeeded()
        }
        NotificationCenter.default.removeObserver(self)
    }
    
    /// New initializer using GraphStoreConfiguration.
    public init(configuration: GraphStoreConfiguration, migrationEnabled: Bool = true) {
        var resolvedConfiguration = configuration
        resolvedConfiguration.cloudKitContainerIdentifier = Self.resolvedCloudKitContainerIdentifier(
            configuration: configuration,
            runtimeOverride: Self.cloudKitContainerIdentifier
        )
        let environmentResult = GraphStoreEnvironmentResolver.resolve(configuration: resolvedConfiguration)
        if case .success(let environment) = environmentResult {
            resolvedConfiguration.setResolvedEnvironment(environment)
        }
        self.configuration = resolvedConfiguration
        self.migrationEnabled = migrationEnabled
        GraphValueTransformer.register()
        super.init()
        if case .failure(let error) = environmentResult {
            failStoreOpening(error)
            return
        }
        if migrationEnabled {
            GraphMigrationManager.handlePhase(.preInit, configuration: resolvedConfiguration, graph: nil)
        }
        observeRemoteStoreChanges()
        checkICloudAccountStatus()
        prepareGraphContextRegistry()
        GraphContextRegistry.shared.withStoreOpenLock {
            prepareManagedObjectContext(configuration: resolvedConfiguration)
        }
    }

    /// Initializes a Graph and reports when its store and lifecycle are ready.
    /// The legacy initializer remains available, but callers that need a
    /// deterministic readiness contract should use this overload.
    public convenience init(
        configuration: GraphStoreConfiguration,
        migrationEnabled: Bool = true,
        onReady completion: @escaping (Result<Graph, GraphStoreOpeningError>) -> Void
    ) {
        self.init(configuration: configuration, migrationEnabled: migrationEnabled)
        whenReady(completion)
    }

    /// Emits a diagnostic event to the application delegate.
    internal func emit(_ event: GraphEvent) {
        if Thread.isMainThread {
            deliver(event)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.deliver(event)
            }
        }
    }

    private func deliver(_ event: GraphEvent) {
        guard let eventDelegate else {
            pendingEvents.append(event)
            return
        }
        eventDelegate.graph(self, didReceive: event)
    }

    private func flushPendingEvents() {
        guard eventDelegate != nil else { return }
        if Thread.isMainThread {
            let events = pendingEvents
            pendingEvents.removeAll()
            events.forEach(deliver)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.flushPendingEvents()
            }
        }
    }

    /// Registers a callback for the first terminal readiness result.
    /// If initialization already finished, the callback is invoked immediately.
    public func whenReady(_ completion: @escaping (Result<Graph, GraphStoreOpeningError>) -> Void) {
        switch readiness {
        case .ready:
            completion(.success(self))
        case .failed(let error):
            completion(.failure(error))
        case .initializing:
            readinessCompletions.append(completion)
        }
    }
    
    
    /// Initialize a Graph directly from a store URL.
    /// If the URL points to a .sqlite file, the name is derived from the filename (without extension).
    /// If the URL points to a directory, the name is derived from the directory name
    /// and GraphEvo resolves the canonical filename inside that directory. Existing
    /// legacy route-based stores are reused automatically.
    public convenience init(storeURL: URL, backend: GraphStoreBackend = .sqlite, migrationEnabled: Bool = true) {
        let resolvedName: String
        let resolvedLocation: URL
        
        if storeURL.pathExtension.caseInsensitiveCompare("sqlite") == .orderedSame {
            // An explicit file is authoritative: preserve its complete URL.
            resolvedName = storeURL.deletingPathExtension().lastPathComponent
            resolvedLocation = storeURL
        } else {
            resolvedName = storeURL.lastPathComponent
            resolvedLocation = storeURL
        }
        
        var config = GraphStoreConfiguration()
        config.name = resolvedName
        config.backend = backend
        config.location = resolvedLocation
        config.disablesCloudKit = true
        
        self.init(configuration: config, migrationEnabled: migrationEnabled)
    }
    // MARK: - Context factory (modern API)
    /// Returns a new background context backed by the same NSPersistentCloudKitContainer.
    /// Returns nil if the container is not yet initialized.
    public func newBackgroundContext() -> NSManagedObjectContext? {
        guard let container = persistentContainer else { return nil }
        let bg = container.newBackgroundContext()
        // Ensure history filtering can identify this device's writes
        bg.transactionAuthor = GraphDeviceAuthor.current()
        // Prefer incoming server values to win on conflict
        bg.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return bg
    }
    
    // MARK: - CloudKit / Remote change hooks (M2)
    
    /// Observe only the custom test channel here (the real remote observer lives in Graph+PersistentHistory).
    private func observeRemoteStoreChanges() {
#if canImport(CoreData)
        let nc = NotificationCenter.default
        // Test channel: watchers already know how to consume this payload.
        nc.addObserver(self,
                       selector: #selector(handleRemoteStoreChange(_:)),
                       name: .GraphEvoSimulatedRemoteChange,
                       object: nil)
#endif
    }
    
    @objc
    private func handleRemoteStoreChange(_ notification: Notification) {
        // RemoteChangeCoordinator merges the context before publishing the
        // notification. Keep the old behavior for direct/test callers that
        // post GraphEvoSimulatedRemoteChange themselves.
        guard notification.name == .GraphEvoSimulatedRemoteChange else { return }
        guard !isCloudPurgeInProgress else { return }
        guard let moc = managedObjectContext else { return }
        if (notification.userInfo?[GraphEvoRemoteChangeAlreadyMergedKey] as? Bool) == true {
            return
        }
        moc.perform { [weak moc] in
            guard let moc = moc else { return }
            moc.mergeChanges(fromContextDidSave: notification)
        }
    }
    
    /// Check iCloud account status and notify the optional cloudStatusDelegate.
    private func checkICloudAccountStatus() {
        // Unit-test bundles do not have CloudKit entitlements. Avoid touching
        // CloudKit there and report the deterministic local status instead.
        if Self.isRunningUnderTests {
            self.lastCloudStatus = .unavailable
            self.emit(.stateChanged(.cloudStatus(.unavailable)))
            if let delegate = self.cloudStatusDelegate {
                delegate.graph(self, iCloudStatusChanged: .unavailable)
            }
            return
        }
        
        // If no identifier is configured (SPM / no capabilities), don't touch CloudKit APIs.
        guard let containerID = configuration.cloudKitContainerIdentifier else {
            self.lastCloudStatus = .unavailable
            self.emit(.stateChanged(.cloudStatus(.unavailable)))
            if let delegate = self.cloudStatusDelegate {
                delegate.graph(self, iCloudStatusChanged: .unavailable)
            }
            return
        }
        
        // Use the explicitly resolved container to query account status.
        CKContainer(identifier: containerID).accountStatus { [weak self] status, _ in
            guard let self = self else { return }
            let mapped: GraphCloudStatus = (status == .available) ? .available : .unavailable
            self.lastCloudStatus = mapped
            self.emit(.stateChanged(.cloudStatus(mapped)))
            DispatchQueue.main.async {
                self.cloudStatusDelegate?.graph(self, iCloudStatusChanged: mapped)
            }
        }
    }
}

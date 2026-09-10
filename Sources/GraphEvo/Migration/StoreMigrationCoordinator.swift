import Foundation
import CoreData

private struct GraphMigrationIndeterminateError: LocalizedError {
    let migrationError: Error
    let ledgerError: Error

    var errorDescription: String? {
        "Migration result is indeterminate. Migration error: \(migrationError.localizedDescription). Ledger error: \(ledgerError.localizedDescription)."
    }
}

/// Owns the runtime migration state for one normalized store scope.
final class StoreMigrationCoordinator {
    private struct PendingPhase {
        let phase: GraphMigrationManager.GraphLifecyclePhase
        let configuration: GraphStoreConfiguration?
        let graph: Graph?
        let completion: (() -> Void)?
    }

    private final class CompletionGate {
        private let lock = NSLock()
        private var consumed = false
        func consume() -> Bool { lock.lock(); defer { lock.unlock() }; guard !consumed else { return false }; consumed = true; return true }
    }

    let scope: GraphStoreScope
    private let lock = NSRecursiveLock()
    private var index = 0
    private var phaseInFlight = false
    private var active = Set<String>()
    private var attemptMetadata: [String: (operationID: String, generation: UInt64, backupReference: String?, requestedBy: GraphMigrationRequestedBy)] = [:]
    private var context = GraphMigrationContext()
    private var pending: [PendingPhase] = []
    private var generation: UInt64 = 0
    private var completion: (() -> Void)?

    init(scope: GraphStoreScope) { self.scope = scope }

    func handle(_ phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, completion: (() -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        if phaseInFlight { pending.append(PendingPhase(phase: phase, configuration: configuration, graph: graph, completion: completion)); return }
        phaseInFlight = true; self.completion = completion
        start(phase, configuration: configuration, graph: graph)
    }

    func handleRemoteChanges(configuration: GraphStoreConfiguration?, graph: Graph?, context: GraphMigrationContext?, inserted: [NSManagedObjectID], updated: [NSManagedObjectID]) {
        lock.lock(); defer { lock.unlock() }
        let migrations = GraphMigrationManager.registeredMigrationsSnapshot()
        migrations.forEach { $0.handleRemoteChanges(configuration: configuration, graph: graph, context: context ?? self.context, inserted: inserted, updated: updated) }
    }

    private func start(_ phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?) {
        GraphMigrationManager.postPhaseNotification(phase: phase, configuration: configuration, graph: graph)
        GraphMigrationManager.callbacksSnapshot(for: phase).forEach { $0(configuration, graph) }
        index = 0; run(phase, configuration: configuration, graph: graph)
    }

    private func run(_ phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?) {
        let migrations = GraphMigrationManager.registeredMigrationsSnapshot()
        guard index < migrations.count else { finish(); return }
        let migration = migrations[index]
        let isActive = active.contains(migration.id)
        var mutableContext: GraphMigrationContext? = context

        if !isActive, let configuration {
            let forced: GraphMigrationForceRequest?
            do {
                try GraphMigrationLedger.validate(migrationID: migration.id, version: migration.version, configuration: configuration)
                forced = try GraphMigrationLedger.consumeForce(migrationID: migration.id, version: migration.version, configuration: configuration)
                try GraphMigrationLedger.reconcileRemoteObservation(migrationID: migration.id, version: migration.version, synchronization: migration.completionSynchronization, configuration: configuration)
                let snapshot = try GraphMigrationLedger.stateSnapshot(migrationID: migration.id, version: migration.version, configuration: configuration)
                mutableContext?.set("GraphMigration.stateSnapshot", value: snapshot)
            }
            catch { fail(migration: migration, phase: phase, configuration: configuration, graph: graph, error: error); return }
            let previous: GraphMigrationRecord?
            do {
                previous = try GraphMigrationManager.recordThrowing(for: migration, configuration: configuration)
            } catch {
                fail(migration: migration, phase: phase, configuration: configuration, graph: graph, error: error)
                return
            }
            if let previous { mutableContext?.set("GraphMigration.previousRecord", value: previous) }
            if forced != nil { mutableContext?.set("GraphMigration.forceRequest", value: forced) }
            if forced == nil,
               let snapshot = mutableContext?.migrationStateSnapshot,
               snapshot.interrupted,
               snapshot.phase != String(describing: phase) {
                // Recovery must be decided in the phase that originally
                // started the operation. Earlier lifecycle phases must not
                // overwrite the durable `started` projection.
                advance(phase, configuration: configuration, graph: graph)
                return
            }
            // `notRequired` is phase-specific: a migration may have no work to
            // do during preInit and still be required during postInit or ready.
            // Only a completed migration is terminal for the whole lifecycle.
            if forced == nil, let previous, previous.state == .done {
                advance(phase, configuration: configuration, graph: graph); return
            }
            if migration.recognizesLegacyCompletion(at: phase, configuration: configuration, graph: graph) {
                do { try transition(.done, migration: migration, configuration: configuration, phase: String(describing: phase)) }
                catch { fail(migration: migration, phase: phase, configuration: configuration, graph: graph, error: error); return }
                advance(phase, configuration: configuration, graph: graph); return
            }
        }

        let forceRequest: GraphMigrationForceRequest? = mutableContext?["GraphMigration.forceRequest"]
        let needsRun = forceRequest != nil || migration.needsRun(at: phase, configuration: configuration, graph: graph, context: &mutableContext)
        context = mutableContext ?? GraphMigrationContext()
        if !isActive && !needsRun {
            if let configuration {
                let reason: GraphMigrationDecisionReason
                let decisionSource: GraphMigrationDecisionSource
                if mutableContext?.migrationStateSnapshot?.interrupted == true { reason = .alreadyCompatible; decisionSource = .recovery }
                else if case .observed(let remote)? = mutableContext?.migrationStateSnapshot?.remoteState, remote.state == .done { reason = .remoteDone; decisionSource = .remoteKVS }
                else { reason = .noCandidate; decisionSource = .localEvaluation }
                do { try transition(.notRequired, migration: migration, configuration: configuration, phase: String(describing: phase), reason: reason, decisionSource: decisionSource) }
                catch { fail(migration: migration, phase: phase, configuration: configuration, graph: graph, error: error); return }
            }
            advance(phase, configuration: configuration, graph: graph); return
        }
        if !isActive, needsRun, let configuration {
            let snapshot = mutableContext?.migrationStateSnapshot
            let generation = (snapshot?.generation ?? 0) + 1
            let requestedBy = forceRequest?.requestedBy ?? .migrationManager
            let operationID = "\(GraphMigrationLedger.installationIdentifier)-\(generation)-\(UUID().uuidString)"
            let backupReference: String?
            do {
                if configuration.backend == .sqlite,
                   FileManager.default.fileExists(atPath: configuration.resolvedStoreURL.path) {
                    let backup = try MigrationBackupManager.backupStore(at: configuration.resolvedStoreURL, configuration: configuration, migration: migration, label: "pre-migration")
                    backupReference = backup.folderURL.path
                } else { backupReference = nil }
                _ = try GraphMigrationLedger.markStarted(migrationID: migration.id, version: migration.version, configuration: configuration, phase: String(describing: phase), operationID: operationID, generation: generation, backupReference: backupReference, requestedBy: requestedBy)
            }
            catch { fail(migration: migration, phase: phase, configuration: configuration, graph: graph, error: error); return }
            attemptMetadata[migration.id] = (operationID, generation, backupReference, requestedBy)
            if phase == .preInit { active.insert(migration.id) }
        }

        let gate = CompletionGate(); generation &+= 1; let expected = generation
        migration.handlePhase(phase, configuration: configuration, graph: graph, context: mutableContext) { [weak self] result in
            guard let self, gate.consume() else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard expected == self.generation else { return }
            switch result {
            case .done, .fallback:
                let completesMigration = phase == .ready || !self.active.contains(migration.id)
                self.finishSuccessfulMigration(migration, phase: phase, configuration: configuration, graph: graph, completesMigration: completesMigration)
            case .skipped:
                if let configuration {
                    do { try self.transition(.notRequired, migration: migration, configuration: configuration, phase: String(describing: phase), reason: .manualSkip, decisionSource: .manual) }
                    catch { self.fail(migration: migration, phase: phase, configuration: configuration, graph: graph, error: error); return }
                }
                self.active.remove(migration.id); self.attemptMetadata.removeValue(forKey: migration.id); self.advance(phase, configuration: configuration, graph: graph)
            case .error(let error):
                self.fail(migration: migration, phase: phase, configuration: configuration, graph: graph, error: error)
            }
        }
    }

    private func finishSuccessfulMigration(_ migration: GraphMigration, phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, completesMigration: Bool) {
        guard let configuration else { active.remove(migration.id); attemptMetadata.removeValue(forKey: migration.id); advance(phase, configuration: configuration, graph: graph); return }
        let persist: (Bool, Error?) -> Void = { [weak self] success, error in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard success else { self.fail(migration: migration, phase: phase, configuration: configuration, graph: graph, error: error ?? NSError(domain: "GraphEvo.Migration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Migration save failed."])); return }
            do {
                guard completesMigration else { self.advance(phase, configuration: configuration, graph: graph); return }
                let metadata = self.attemptMetadata[migration.id]
                _ = try GraphMigrationLedger.markDone(migrationID: migration.id, version: migration.version, synchronization: migration.completionSynchronization, configuration: configuration, phase: String(describing: phase), operationID: metadata?.operationID ?? UUID().uuidString, generation: metadata?.generation, backupReference: metadata?.backupReference, requestedBy: metadata?.requestedBy ?? .migrationManager)
                self.active.remove(migration.id); self.attemptMetadata.removeValue(forKey: migration.id); self.advance(phase, configuration: configuration, graph: graph)
            } catch { self.fail(migration: migration, phase: phase, configuration: configuration, graph: graph, error: error) }
        }
        if let graph { graph.sync(persist) } else { persist(true, nil) }
    }

    private func transition(_ state: GraphMigrationState, migration: GraphMigration, configuration: GraphStoreConfiguration, phase: String = "unknown", reason: GraphMigrationDecisionReason? = nil, decisionSource: GraphMigrationDecisionSource = .localEvaluation) throws {
        let metadata = attemptMetadata[migration.id]
        switch state {
        case .done: _ = try GraphMigrationLedger.markDone(migrationID: migration.id, version: migration.version, synchronization: migration.completionSynchronization, configuration: configuration, phase: phase)
        case .notRequired: _ = try GraphMigrationLedger.markNotRequired(migrationID: migration.id, version: migration.version, configuration: configuration, reason: reason ?? .noCandidate, decisionSource: decisionSource, phase: phase, operationID: metadata?.operationID ?? UUID().uuidString, generation: metadata?.generation, backupReference: metadata?.backupReference, requestedBy: metadata?.requestedBy ?? .migrationManager)
        default: break
        }
    }

    private func fail(migration: GraphMigration, phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, error: Error) {
        let metadata = attemptMetadata[migration.id]
        let originalError = error
        var reportedError: Error = originalError
        if let configuration {
            do {
                _ = try GraphMigrationLedger.markFailed(migrationID: migration.id, version: migration.version, error: originalError, configuration: configuration, phase: String(describing: phase), operationID: metadata?.operationID ?? UUID().uuidString, generation: metadata?.generation, backupReference: metadata?.backupReference, requestedBy: metadata?.requestedBy ?? .migrationManager)
            } catch {
                GraphMigrationLogger.log(migrationID: migration.id, level: .error, event: "migration_failed_write_failed", message: "Original error: \(originalError.localizedDescription); ledger error: \(error.localizedDescription)", configuration: configuration)
                reportedError = GraphMigrationIndeterminateError(migrationError: originalError, ledgerError: error)
            }
        }
        GraphMigrationManager.postFailureNotification(migrationID: migration.id, phase: phase, configuration: configuration, graph: graph, error: reportedError)
        graph?.emit(.error(.migration(migrationID: migration.id, phase: String(describing: phase), underlying: reportedError)))
        active.remove(migration.id); attemptMetadata.removeValue(forKey: migration.id); finish()
    }

    private func advance(_ phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?) { index += 1; run(phase, configuration: configuration, graph: graph) }

    private func finish() {
        guard phaseInFlight else { return }
        phaseInFlight = false; generation &+= 1
        let completed = completion; completion = nil
        if let next = pending.first { pending.removeFirst(); phaseInFlight = true; completion = next.completion; start(next.phase, configuration: next.configuration, graph: next.graph) }
        else if active.isEmpty { GraphMigrationManager.discardCoordinator(self) }
        completed?()
    }
}

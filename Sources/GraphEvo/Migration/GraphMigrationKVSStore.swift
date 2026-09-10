import Foundation

protocol GraphMigrationKVSStore: AnyObject {
    var changeNotification: Notification.Name { get }
    var notificationObject: AnyObject? { get }
    func object(forKey key: String) -> Any?
    func dictionary(forKey key: String) -> [String: Any]?
    func set(_ value: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

final class GraphMigrationUbiquitousKVSStore: GraphMigrationKVSStore {
    static let shared = GraphMigrationUbiquitousKVSStore()
    private let store = NSUbiquitousKeyValueStore.default

    var changeNotification: Notification.Name { NSUbiquitousKeyValueStore.didChangeExternallyNotification }
    var notificationObject: AnyObject? { store }
    func object(forKey key: String) -> Any? { store.object(forKey: key) }
    func dictionary(forKey key: String) -> [String: Any]? { store.dictionary(forKey: key) }
    func set(_ value: Any?, forKey key: String) { store.set(value, forKey: key) }
    func synchronize() -> Bool { store.synchronize() }
}

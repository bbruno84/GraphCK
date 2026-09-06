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

@objc(GraphSource)
public enum GraphSource: Int {
  case cloud
  case local
}

@objc(GraphNodeDelegate)
public protocol GraphNodeDelegate {}

@objc(GraphEntityDelegate)
public protocol GraphEntityDelegate: GraphNodeDelegate {
  /**
   A delegation method that is executed when an Entity is inserted.
   - Parameter graph: A Graph instance.
   - Parameter inserted entity: An Entity instance.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, inserted entity: Entity, source: GraphSource)
  
  /**
   A delegation method that is executed when an Entity is deleted.
   - Parameter graph: A Graph instance.
   - Parameter deleted entity: An Entity instance.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, deleted entity: Entity, source: GraphSource)
  
  /**
   A delegation method that is executed when an Entity added a property and value.
   - Parameter graph: A Graph instance.
   - Parameter entity: An Entity instance.
   - Parameter added property: A String.
   - Parameter with value: Any object.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, entity: Entity, added property: String, with value: Any, source: GraphSource)
  
  /**
   A delegation method that is executed when an Entity updated a property and value.
   - Parameter graph: A Graph instance.
   - Parameter entity: An Entity instance.
   - Parameter updated property: A String.
   - Parameter with value: Any object.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, entity: Entity, updated property: String, with value: Any, source: GraphSource)
  
  /**
   A delegation method that is executed when an Entity removed a property and value.
   - Parameter graph: A Graph instance.
   - Parameter entity: An Entity instance.
   - Parameter removed property: A String.
   - Parameter with value: Any object.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, entity: Entity, removed property: String, with value: Any, source: GraphSource)
  
  /**
   A delegation method that is executed when an Entity added a tag.
   - Parameter graph: A Graph instance.
   - Parameter entity: An Entity instance.
   - Parameter added tag: A String.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, entity: Entity, added tag: String, source: GraphSource)
  
  /**
   A delegation method that is executed when an Entity removed a tag.
   - Parameter graph: A Graph instance.
   - Parameter entity: An Entity instance.
   - Parameter removed tag: A String.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, entity: Entity, removed tag: String, source: GraphSource)
  
  /**
   A delegation method that is executed when an Entity was added to a group.
   - Parameter graph: A Graph instance.
   - Parameter entity: An Entity instance.
   - Parameter addedTo group: A String.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, entity: Entity, addedTo group: String, source: GraphSource)
  
  /**
   A delegation method that is executed when an Entity was removed from a group.
   - Parameter graph: A Graph instance.
   - Parameter entity: An Entity instance.
   - Parameter removedFrom group: A String.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, entity: Entity, removedFrom group: String, source: GraphSource)
}

@objc(GraphRelationshipDelegate)
public protocol GraphRelationshipDelegate: GraphNodeDelegate {
  /**
   A delegation method that is executed when a Relationship is inserted.
   - Parameter graph: A Graph instance.
   - Parameter inserted relationship: A Relationship instance.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, inserted relationship: Relationship, source: GraphSource)
  
  /**
   A delegation method that is executed when a Relationship is updated.
   - Parameter graph: A Graph instance.
   - Parameter updated relationship: A Relationship instance.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, updated relationship: Relationship, source: GraphSource)
  
  /**
   A delegation method that is executed when a Relationship is deleted.
   - Parameter graph: A Graph instance.
   - Parameter deleted relationship: A Relationship instance.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, deleted relationship: Relationship, source: GraphSource)
  
  /**
   A delegation method that is executed when a Relationship added a property and value.
   - Parameter graph: A Graph instance.
   - Parameter relationship: A Relationship instance.
   - Parameter added property: A String.
   - Parameter with value: Any object.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, relationship: Relationship, added property: String, with value: Any, source: GraphSource)
  
  /**
   A delegation method that is executed when a Relationship updated a property and value.
   - Parameter graph: A Graph instance.
   - Parameter relationship: A Relationship instance.
   - Parameter updated property: A String.
   - Parameter with value: Any object.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, relationship: Relationship, updated property: String, with value: Any, source: GraphSource)
  
  /**
   A delegation method that is executed when a Relationship removed a property and value.
   - Parameter graph: A Graph instance.
   - Parameter relationship: A Relationship instance.
   - Parameter removed property: A String.
   - Parameter with value: Any object.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, relationship: Relationship, removed property: String, with value: Any, source: GraphSource)
  
  /**
   A delegation method that is executed when a Relationship added a tag.
   - Parameter graph: A Graph instance.
   - Parameter relationship: A Relationship instance.
   - Parameter added tag: A String.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, relationship: Relationship, added tag: String, source: GraphSource)
  
  /**
   A delegation method that is executed when a Relationship removed a tag.
   - Parameter graph: A Graph instance.
   - Parameter relationship: A Relationship instance.
   - Parameter removed tag: A String.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, relationship: Relationship, removed tag: String, source: GraphSource)
  
  /**
   A delegation method that is executed when a Relationship was added to a group.
   - Parameter graph: A Graph instance.
   - Parameter relationship: A Relationship instance.
   - Parameter addedTo group: A String.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, relationship: Relationship, addedTo group: String, source: GraphSource)
  
  /**
   A delegation method that is executed when a Relationship was removed from a group.
   - Parameter graph: A Graph instance.
   - Parameter relationship: A Relationship instance.
   - Parameter removedFrom group: A String.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, relationship: Relationship, removedFrom group: String, source: GraphSource)
}

@objc(GraphActionDelegate)
public protocol GraphActionDelegate: GraphNodeDelegate {
  /**
   A delegation method that is executed when an Action is inserted.
   - Parameter graph: A Graph instance.
   - Parameter inserted action: An Action instance.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, inserted action: Action, source: GraphSource)
  
  /**
   A delegation method that is executed when an Action is deleted.
   - Parameter graph: A Graph instance.
   - Parameter deleted action: An Action instance.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, deleted action: Action, source: GraphSource)
  
  /**
   A delegation method that is executed when an Action added a property and value.
   - Parameter graph: A Graph instance.
   - Parameter action: An Action instance.
   - Parameter added property: A String.
   - Parameter with value: Any object.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, action: Action, added property: String, with value: Any, source: GraphSource)
  
  /**
   A delegation method that is executed when an Action updated a property and value.
   - Parameter graph: A Graph instance.
   - Parameter action: An Action instance.
   - Parameter updated property: A String.
   - Parameter with value: Any object.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, action: Action, updated property: String, with value: Any, source: GraphSource)
  
  /**
   A delegation method that is executed when an Action removed a property and value.
   - Parameter graph: A Graph instance.
   - Parameter action: An Action instance.
   - Parameter removed property: A String.
   - Parameter with value: Any object.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, action: Action, removed property: String, with value: Any, source: GraphSource)
  
  /**
   A delegation method that is executed when an Action added a tag.
   - Parameter graph: A Graph instance.
   - Parameter action: An Action instance.
   - Parameter added tag: A String.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, action: Action, added tag: String, source: GraphSource)
  
  /**
   A delegation method that is executed when an Action removed a tag.
   - Parameter graph: A Graph instance.
   - Parameter action: An Action instance.
   - Parameter removed tag: A String.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, action: Action, removed tag: String, source: GraphSource)
  
  /**
   A delegation method that is executed when an Action was added to a group.
   - Parameter graph: A Graph instance.
   - Parameter action: An Action instance.
   - Parameter addedTo group: A String.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, action: Action, addedTo group: String, source: GraphSource)
  
  /**
   A delegation method that is executed when an Action was removed from a group.
   - Parameter graph: A Graph instance.
   - Parameter action: An Action instance.
   - Parameter removedFrom group: A String.
   - Parameter source: A GraphSource value.
   */
  @objc
  optional func graph(_ graph: Graph, action: Action, removedFrom group: String, source: GraphSource)
}

public protocol Watchable {
  /// Element type.
  associatedtype Element: Node
}

internal protocol AnyGraphWatcher: AnyObject {
  func receive(_ envelopes: [GraphWatchEventEnvelope], source: GraphSource)
}

public struct Watcher {
  /// A weak reference to the stored object.
  private weak var object: AnyObject?
  
  /// A reference to the weak Watch<T> instance.
  public var watch: Watch<Node>? {
    return object as? Watch<Node>
  }

  internal var receiver: AnyGraphWatcher? { object as? AnyGraphWatcher }
  internal var isAlive: Bool { object != nil }
  
  /**
   An initializer that takes in an object instance.
   - Parameter watch: A Watch<T> instance.
   */
  public init (object: AnyObject) {
    self.object = object
  }
}

/// Watch.
public class Watch<T: Node>: Watchable, AnyGraphWatcher {
  public typealias Element = T
  
  /// A Graph instance.
  public fileprivate(set) var graph: Graph
  
  /// A reference to a delagte object.
  public weak var delegate: GraphNodeDelegate?
  
  /// A reference to watch predicate.
  internal private(set) var predicate: Predicate!
  
  /**
   A boolean indicating if the Watch instance is
   currently watching.
   */
  public fileprivate(set) var isRunning = false
  
  /// Deinitializer.
  deinit {
    removeFromObservation()
  }
  
  /**
   An initializer that accepts a NodeClass and Graph
   instance.
   - Parameter graph: A Graph instance.
   */
    public init(graph: Graph = Graph(configuration: GraphStoreConfiguration())) {
    self.graph = graph
    prepare()
  }
  
  /**
   Clears the search parameters.
   - Returns: A Watch instance.
   */
  @discardableResult
  public func clear() -> Watch {
    predicate = nil
    return self
  }
  
  @discardableResult
  public func `where`(_ predicate: Predicate) -> Watch {
    self.predicate = self.predicate.map {
      $0 || predicate
      } ?? predicate
    return self
  }
  
  /**
   Resumes the watcher.
   - Returns: A Watch instance.
   */
  @discardableResult
  public func resume() -> Watch {
    guard !isRunning else {
      return self
    }
    
    isRunning = true
    
    addForObservation()
    return self
  }
  
  /**
   Pauses the watcher.
   - Returns: A Watch instance.
   */
  @discardableResult
  public func pause() -> Watch {
    isRunning = false
    
    removeFromObservation()
    return self
  }
  
  /**
   Notifies inserted watchers from local changes.
   - Parameter notification: NSNotification reference.
   */
  @objc
  internal func notifyInsertedWatchers(_ notification: Notification) {
    guard let objects = notification.userInfo?[NSInsertedObjectsKey] as? NSSet else {
      return
    }
    
    delegateToInsertedWatchers(filtered(objects), source: .local)
  }
  
  /**
   Notifies updated watchers from local changes.
   - Parameter notification: NSNotification reference.
   */
  @objc
  internal func notifyUpdatedWatchers(_ notification: Notification) {
    guard let objects = notification.userInfo?[NSUpdatedObjectsKey] as? NSSet else {
      return
    }
    
    delegateToUpdatedWatchers(filtered(objects), source: .local)
  }
  
  /**
   Notifies deleted watchers from local changes.
   - Parameter notification: NSNotification reference.
   */
  @objc
  internal func notifyDeletedWatchers(_ notification: Notification) {
    guard let objects = notification.userInfo?[NSDeletedObjectsKey] as? NSSet else {
      return
    }
    
    delegateToDeletedWatchers(filtered(objects), source: .local)
  }
  
  /**
   Notifies inserted watchers from cloud changes.
   - Parameter notification: NSNotification reference.
   */
    @objc
    internal func notifyInsertedWatchersFromCloud(_ notification: Notification) {
      // Process only notifications posted for this watch's MOC
      guard
        let ctx = graph.managedObjectContext,
        let notifCtx = notification.object as? NSManagedObjectContext,
        notifCtx === ctx
      else { return }
            guard let payload = notification.userInfo?[NSInsertedObjectsKey] as? NSSet else {
        return
      }
      guard let moc = graph.managedObjectContext else { return }

      let objects = NSMutableSet()
      if let ids = payload.allObjects as? [NSManagedObjectID] {
        ids.forEach { objects.add(moc.object(with: $0)) }
      } else if let managed = payload.allObjects as? [NSManagedObject] {
        managed.forEach { objects.add($0) }
      } else {
        return
      }

      delegateToInsertedWatchers(filtered(objects), source: .cloud)
    }
  /**
   Notifies updated watchers from cloud changes.
   - Parameter notification: NSNotification reference.
   */
    @objc
    internal func notifyUpdatedWatchersFromCloud(_ notification: Notification) {
      // Process only notifications posted for this watch's MOC
      guard
        let ctx = graph.managedObjectContext,
        let notifCtx = notification.object as? NSManagedObjectContext,
        notifCtx === ctx
      else { return }
      guard let payload = notification.userInfo?[NSUpdatedObjectsKey] as? NSSet else { return }
      guard let moc = graph.managedObjectContext else { return }

      let objects = NSMutableSet()
      if let ids = payload.allObjects as? [NSManagedObjectID] {
        ids.forEach { objects.add(moc.object(with: $0)) }
      } else if let managed = payload.allObjects as? [NSManagedObject] {
        managed.forEach { objects.add($0) }
      } else {
        return
      }

      delegateToUpdatedWatchers(filtered(objects), source: .cloud)
    }
  
  /**
   Notifies deleted watchers from cloud changes.
   - Parameter notification: NSNotification reference.
   */
    @objc
    internal func notifyDeletedWatchersFromCloud(_ notification: Notification) {
      // Process only notifications posted for this watch's MOC
      guard
        let ctx = graph.managedObjectContext,
        let notifCtx = notification.object as? NSManagedObjectContext,
        notifCtx === ctx
      else { return }
      guard let payload = notification.userInfo?[NSDeletedObjectsKey] as? NSSet else { return }
      guard let moc = graph.managedObjectContext else { return }

      let objects = NSMutableSet()
      if let ids = payload.allObjects as? [NSManagedObjectID] {
        ids.forEach { objects.add(moc.object(with: $0)) }
      } else if let managed = payload.allObjects as? [NSManagedObject] {
        managed.forEach { objects.add($0) }
      } else {
        return
      }

      delegateToDeletedWatchers(filtered(objects), source: .cloud)
    }}

extension Watch {
  /**
   Passes the handle to the inserted notification delegates.
   - Parameter _ set: A Set of AnyHashable objects to pass.
   - Parameter source: A GraphSource value.
   */
  func delegateToInsertedWatchers(_ set: Set<AnyHashable>, source: GraphSource) {
    delegateToEntityInsertedWatchers(set, source: source)
    delegateToRelationshipInsertedWatchers(set, source: source)
    delegateToActionInsertedWatchers(set, source: source)
  }
  
  /**
   Passes the handle to the inserted notification delegates for Entities.
   - Parameter _ set: A Set of AnyHashable objects.
   - Parameter source: A GraphSource value.
   */
  func delegateToEntityInsertedWatchers(_ set: Set<AnyHashable>, source: GraphSource) {
    set.forEach { [unowned self] in
      guard let n = $0 as? ManagedEntity else {
        return
      }
      
      (self.delegate as? GraphEntityDelegate)?.graph?(self.graph, inserted: Entity(managedNode: n), source: source)
    }
    
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedEntityTag else {
        return
      }
      
      guard let n = o.node as? ManagedEntity else {
        return
      }
      
      (self.delegate as? GraphEntityDelegate)?.graph?(self.graph, entity: Entity(managedNode: n), added: o.name, source: source)
    }
    
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedEntityGroup else {
        return
      }
      
      guard let n = o.node as? ManagedEntity else {
        return
      }
      
      (self.delegate as? GraphEntityDelegate)?.graph?(self.graph, entity: Entity(managedNode: n), addedTo: o.name, source: source)
    }
    
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedEntityProperty else {
        return
      }
      
      guard let n = o.node as? ManagedEntity else {
        return
      }
      
      (self.delegate as? GraphEntityDelegate)?.graph?(self.graph, entity: Entity(managedNode: n), added: o.name, with: o.object, source: source)
    }
  }
  
  /**
   Passes the handle to the inserted notification delegates for Relationships.
   - Parameter _ set: A Set of AnyHashable objects.
   - Parameter source: A GraphSource value.
   */
  func delegateToRelationshipInsertedWatchers(_ set: Set<AnyHashable>, source: GraphSource) {
    set.forEach { [unowned self] in
      guard let n = $0 as? ManagedRelationship else {
        return
      }
      
      (self.delegate as? GraphRelationshipDelegate)?.graph?(self.graph, inserted: Relationship(managedNode: n), source: source)
    }
    
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedRelationshipTag else {
        return
      }
      
      guard let n = o.node as? ManagedRelationship else {
        return
      }
      
      (self.delegate as? GraphRelationshipDelegate)?.graph?(self.graph, relationship: Relationship(managedNode: n), added: o.name, source: source)
    }
    
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedRelationshipGroup else {
        return
      }
      
      guard let n = o.node as? ManagedRelationship else {
        return
      }
      
      (self.delegate as? GraphRelationshipDelegate)?.graph?(self.graph, relationship: Relationship(managedNode: n), addedTo: o.name, source: source)
    }
    
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedRelationshipProperty else {
        return
      }
      
      guard let n = o.node as? ManagedRelationship else {
        return
      }
      
      (self.delegate as? GraphRelationshipDelegate)?.graph?(self.graph, relationship: Relationship(managedNode: n), added: o.name, with: o.object, source: source)
    }
  }
  
  /**
   Passes the handle to the inserted notification delegates for Actions.
   - Parameter _ set: A Set of AnyHashable objects.
   - Parameter source: A GraphSource value.
   */
  func delegateToActionInsertedWatchers(_ set: Set<AnyHashable>, source: GraphSource) {
    set.forEach { [unowned self] in
      guard let n = $0 as? ManagedAction else {
        return
      }
      
      (self.delegate as? GraphActionDelegate)?.graph?(self.graph, inserted: Action(managedNode: n), source: source)
    }
    
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedActionTag else {
        return
      }
      
      guard let n = o.node as? ManagedAction else {
        return
      }
      
      (self.delegate as? GraphActionDelegate)?.graph?(self.graph, action: Action(managedNode: n), added: o.name, source: source)
    }
    
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedActionGroup else {
        return
      }
      
      guard let n = o.node as? ManagedAction else {
        return
      }
      
      (self.delegate as? GraphActionDelegate)?.graph?(self.graph, action: Action(managedNode: n), addedTo: o.name, source: source)
    }
    
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedActionProperty else {
        return
      }
      
      guard let n = o.node as? ManagedAction else {
        return
      }
      
      (self.delegate as? GraphActionDelegate)?.graph?(self.graph, action: Action(managedNode: n), added: o.name, with: o.object, source: source)
    }
  }
  
  /**
   Passes the handle to the updated notification delegates.
   - Parameter _ set: A Set of AnyHashable objects.
   - Parameter source: A GraphSource value.
   */
  func delegateToUpdatedWatchers(_ set: Set<AnyHashable>, source: GraphSource) {
    delegateToEntityUpdatedWatchers(set, source: source)
    delegateToRelationshipUpdatedWatchers(set, source: source)
    delegateToActionUpdatedWatchers(set, source: source)
  }
  
  /**
   Passes the handle to the updated notification delegates for Entities.
   - Parameter nodes: An Array of ManagedObjects.
   - Parameter source: A GraphSource value.
   */
  func delegateToEntityUpdatedWatchers(_ set: Set<AnyHashable>, source: GraphSource) {
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedEntityProperty else {
        return
      }
      
      guard let n = o.node as? ManagedEntity else {
        return
      }
      
      (self.delegate as? GraphEntityDelegate)?.graph?(self.graph, entity: Entity(managedNode: n), updated: o.name, with: o.object, source: source)
    }
  }
  
  /**
   Passes the handle to the updated notification delegates for Relationships.
   - Parameter _ set: A Set of AnyHashable objects.
   - Parameter source: A GraphSource value.
   */
  func delegateToRelationshipUpdatedWatchers(_ set: Set<AnyHashable>, source: GraphSource) {
    set.forEach { [unowned self] in
      guard let n = $0 as? ManagedRelationship else {
        return
      }
      
      (self.delegate as? GraphRelationshipDelegate)?.graph?(self.graph, updated: Relationship(managedNode: n), source: source)
    }
    
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedRelationshipProperty else {
        return
      }
      
      guard let n = o.node as? ManagedRelationship else {
        return
      }
      
      (self.delegate as? GraphRelationshipDelegate)?.graph?(self.graph, relationship: Relationship(managedNode: n), updated: o.name, with: o.object, source: source)
    }
  }
  
  /**
   Passes the handle to the updated notification delegates for Actions.
   - Parameter _ set: A Set of AnyHashable objects.
   - Parameter source: A GraphSource value.
   */
  func delegateToActionUpdatedWatchers(_ set: Set<AnyHashable>, source: GraphSource) {
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedActionProperty else {
        return
      }
      
      guard let n = o.node as? ManagedAction else {
        return
      }
      
      (self.delegate as? GraphActionDelegate)?.graph?(self.graph, action: Action(managedNode: n), updated: o.name, with: o.object, source: source)
    }
  }
  
  /**
   Passes the handle to the deleted notification delegates.
   - Parameter _ set: A Set of AnyHashable objects.
   - Parameter source: A GraphSource value.
   */
  func delegateToDeletedWatchers(_ set: Set<AnyHashable>, source: GraphSource) {
    delegateToEntityDeletedWatchers(set, source: source)
    delegateToRelationshipDeletedWatchers(set, source: source)
    delegateToActionDeletedWatchers(set, source: source)
  }
  
  /**
   Passes the handle to the deleted notification delegates for Entities.
   - Parameter _ set: A Set of AnyHashable objects.
   - Parameter source: A GraphSource value.
   */
  func delegateToEntityDeletedWatchers(_ set: Set<AnyHashable>, source: GraphSource) {
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedEntityTag else {
        return
      }
      
      guard let n = (.cloud == source ? o.node : o.changedValuesForCurrentEvent()["node"]) as? ManagedEntity else {
        return
      }
      
      (self.delegate as? GraphEntityDelegate)?.graph?(self.graph, entity: Entity(managedNode: n), removed: o.name, source: source)
    }
    
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedEntityGroup else {
        return
      }
      
      guard let n = (.cloud == source ? o.node : o.changedValuesForCurrentEvent()["node"]) as? ManagedEntity else {
        return
      }
      
      (self.delegate as? GraphEntityDelegate)?.graph?(self.graph, entity: Entity(managedNode: n), removedFrom: o.name, source: source)
    }
    
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedEntityProperty else {
        return
      }
      
      guard let n = (.cloud == source ? o.node : o.changedValuesForCurrentEvent()["node"]) as? ManagedEntity else {
        return
      }
      
      (self.delegate as? GraphEntityDelegate)?.graph?(self.graph, entity: Entity(managedNode: n), removed: o.name, with: o.object, source: source)
    }
    
    set.forEach { [unowned self] in
      guard let n = $0 as? ManagedEntity else {
        return
      }
      
      (self.delegate as? GraphEntityDelegate)?.graph?(self.graph, deleted: Entity(managedNode: n), source: source)
    }
  }
  
  /**
   Passes the handle to the deleted notification delegates for Relationships.
   - Parameter _ set: A Set of AnyHashable objects.
   - Parameter source: A GraphSource value.
   */
  func delegateToRelationshipDeletedWatchers(_ set: Set<AnyHashable>, source: GraphSource) {
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedRelationshipTag else {
        return
      }
      
      guard let n = (.cloud == source ? o.node : o.changedValuesForCurrentEvent()["node"]) as? ManagedRelationship else {
        return
      }
      
      (self.delegate as? GraphRelationshipDelegate)?.graph?(self.graph, relationship: Relationship(managedNode: n), removed: o.name, source: source)
    }
    
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedRelationshipGroup else {
        return
      }
      
      guard let n = (.cloud == source ? o.node : o.changedValuesForCurrentEvent()["node"]) as? ManagedRelationship else {
        return
      }
      
      (self.delegate as? GraphRelationshipDelegate)?.graph?(self.graph, relationship: Relationship(managedNode: n), removedFrom: o.name, source: source)
    }
    
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedRelationshipProperty else {
        return
      }
      
      guard let n = (.cloud == source ? o.node : o.changedValuesForCurrentEvent()["node"]) as? ManagedRelationship else {
        return
      }
      
      (self.delegate as? GraphRelationshipDelegate)?.graph?(self.graph, relationship: Relationship(managedNode: n), removed: o.name, with: o.object, source: source)
    }
    
    set.forEach { [unowned self] in
      guard let n = $0 as? ManagedRelationship else {
        return
      }
      
      (self.delegate as? GraphRelationshipDelegate)?.graph?(self.graph, deleted: Relationship(managedNode: n), source: source)
    }
  }
  
  /**
   Passes the handle to the deleted notification delegates for Actions.
   - Parameter _ set: A Set of AnyHashable objects.
   - Parameter source: A GraphSource value.
   */
  func delegateToActionDeletedWatchers(_ set: Set<AnyHashable>, source: GraphSource) {
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedActionTag else {
        return
      }
      
      guard let n = (.cloud == source ? o.node : o.changedValuesForCurrentEvent()["node"]) as? ManagedAction else {
        return
      }
      
      (self.delegate as? GraphActionDelegate)?.graph?(self.graph, action: Action(managedNode: n), removed: o.name, source: source)
    }
    
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedActionGroup else {
        return
      }
      
      guard let n = (.cloud == source ? o.node : o.changedValuesForCurrentEvent()["node"]) as? ManagedAction else {
        return
      }
      
      (self.delegate as? GraphActionDelegate)?.graph?(self.graph, action: Action(managedNode: n), removedFrom: o.name, source: source)
    }
    
    set.forEach { [unowned self] in
      guard let o = $0 as? ManagedActionProperty else {
        return
      }
      
      guard let n = (.cloud == source ? o.node : o.changedValuesForCurrentEvent()["node"]) as? ManagedAction else {
        return
      }
      
      (self.delegate as? GraphActionDelegate)?.graph?(self.graph, action: Action(managedNode: n), removed: o.name, with: o.object, source: source)
    }
    
    set.forEach { [unowned self] in
      guard let n = $0 as? ManagedAction else {
        return
      }
      
      (self.delegate as? GraphActionDelegate)?.graph?(self.graph, deleted: Action(managedNode: n), source: source)
    }
  }
  
  /// Removes the watcher.
  func removeFromObservation() {
    NotificationCenter.default.removeObserver(self)
      NotificationCenter.default.removeObserver(self, name: .GraphEvoSimulatedRemoteChange, object: nil)
  }
  
  /// Prepares the Watch instance.
    func prepare() {
    prepareGraph()
    resume()
  }
  
  /// Prepares the instance for save notifications.
    func addForObservation() {
      guard let moc = graph.managedObjectContext else {
        return
      }

      let defaultCenter = NotificationCenter.default
      defaultCenter.addObserver(self, selector: #selector(notifyInsertedWatchers), name: .NSManagedObjectContextDidSave, object: moc)
      defaultCenter.addObserver(self, selector: #selector(notifyUpdatedWatchers), name: .NSManagedObjectContextDidSave, object: moc)
      defaultCenter.addObserver(self, selector: #selector(notifyDeletedWatchers), name: .NSManagedObjectContextObjectsDidChange, object: moc)
      defaultCenter.addObserver(self, selector: #selector(notifyInsertedWatchersFromCloud(_:)), name: .GraphEvoSimulatedRemoteChange, object: nil)
      defaultCenter.addObserver(self, selector: #selector(notifyUpdatedWatchersFromCloud(_:)), name: .GraphEvoSimulatedRemoteChange, object: nil)
      defaultCenter.addObserver(self, selector: #selector(notifyDeletedWatchersFromCloud(_:)), name: .GraphEvoSimulatedRemoteChange, object: nil)
    }
  
  /// Prepares graph for watching.
  func prepareGraph() {
    graph.watchers.append(Watcher(object: self))
    removeFromObservation() // evita registrazioni multiple
  }
  
  /**
   Filter node objects in the given NSSet based on the Predicate.
   - Parameter _ objects: An NSSet containing subclasses of ManagedObject.
   - Returns: A Set<AnyHashable>.
   */
  private func filtered(_ objects: NSSet) -> Set<AnyHashable> {
    guard let objects = objects as? Set<ManagedObject> else {
      return []
    }
    
    /**
     Check if both old and new states of the provided node
     passes the predicate.
     - Parameter _ node: A ManagedNode.
     - Returns: A Boolean.
     */
    func passesPredicate(_ node: ManagedNode) -> Bool {
      guard node.nodeClass == NodeClass(nodeType: T.self)?.rawValue else {
        return false
      }
      
      var tagSet = node.tagSet
      var groupSet = node.groupSet
      var propertySet = node.propertySet
      
      let oldNodeValues = node.changedValuesForCurrentEvent()
      
      
      if let oldTagSet = oldNodeValues["tagSet"] as? Set<ManagedTag> {
        tagSet.formUnion(oldTagSet)
      }
      
      if let oldGroupSet = oldNodeValues["groupSet"] as? Set<ManagedGroup> {
        groupSet.formUnion(oldGroupSet)
      }
      
      if let oldPropertySet = oldNodeValues["propertySet"] as? Set<ManagedProperty> {
        propertySet.formUnion(oldPropertySet)
      }
      
      let dictionary: [String: Any] = [
        "type": node.type,
        "tagSet": tagSet,
        "groupSet": groupSet,
        "propertySet": propertySet,
      ]
      
      return predicate.predicate.evaluate(with: dictionary)
    }
    
    let nodesThatPass = objects.filter {
      guard let n = $0 as? ManagedNode else {
        return false
      }
      
      return passesPredicate(n)
    }
    
    return nodesThatPass.union(objects.filter {
      guard let n = $0 as? NamedManagedObject else {
        return false
      }
      
      guard let v = n.node == nil ? (n.changedValuesForCurrentEvent()["node"] as? ManagedNode): n.node else {
        return false
      }
      
      return passesPredicate(v)
    })
  }

  internal func receive(_ envelopes: [GraphWatchEventEnvelope], source: GraphSource) {
    guard isRunning else { return }
    envelopes.forEach { envelope in
      guard matchesPredicate(envelope.owner) else { return }
      envelope.event.deliver(to: delegate, graph: graph, source: source)
    }
  }

  private func matchesPredicate(_ node: ManagedNode) -> Bool {
    guard node.nodeClass == NodeClass(nodeType: T.self)?.rawValue else { return false }
    guard let predicate else { return true }

    var tagSet = node.tagSet
    var groupSet = node.groupSet
    var propertySet = node.propertySet
    let oldNodeValues = node.changedValuesForCurrentEvent()
    if let old = oldNodeValues["tagSet"] as? Set<ManagedTag> { tagSet.formUnion(old) }
    if let old = oldNodeValues["groupSet"] as? Set<ManagedGroup> { groupSet.formUnion(old) }
    if let old = oldNodeValues["propertySet"] as? Set<ManagedProperty> { propertySet.formUnion(old) }

    return predicate.predicate.evaluate(with: [
      "type": node.type,
      "tagSet": tagSet,
      "groupSet": groupSet,
      "propertySet": propertySet,
    ])
  }
}

private extension GraphWatchEvent {
  func deliver(to delegate: GraphNodeDelegate?, graph: Graph, source: GraphSource) {
    switch self {
    case .insertedEntity(let entity):
      (delegate as? GraphEntityDelegate)?.graph?(graph, inserted: entity, source: source)
    case .deletedEntity(let entity):
      (delegate as? GraphEntityDelegate)?.graph?(graph, deleted: entity, source: source)
    case .addedEntityProperty(let entity, let name, let value):
      (delegate as? GraphEntityDelegate)?.graph?(graph, entity: entity, added: name, with: value, source: source)
    case .updatedEntityProperty(let entity, let name, let value):
      (delegate as? GraphEntityDelegate)?.graph?(graph, entity: entity, updated: name, with: value, source: source)
    case .removedEntityProperty(let entity, let name, let value):
      (delegate as? GraphEntityDelegate)?.graph?(graph, entity: entity, removed: name, with: value, source: source)
    case .addedEntityTag(let entity, let name):
      (delegate as? GraphEntityDelegate)?.graph?(graph, entity: entity, added: name, source: source)
    case .removedEntityTag(let entity, let name):
      (delegate as? GraphEntityDelegate)?.graph?(graph, entity: entity, removed: name, source: source)
    case .addedEntityToGroup(let entity, let name):
      (delegate as? GraphEntityDelegate)?.graph?(graph, entity: entity, addedTo: name, source: source)
    case .removedEntityFromGroup(let entity, let name):
      (delegate as? GraphEntityDelegate)?.graph?(graph, entity: entity, removedFrom: name, source: source)

    case .insertedRelationship(let relationship):
      (delegate as? GraphRelationshipDelegate)?.graph?(graph, inserted: relationship, source: source)
    case .updatedRelationship(let relationship):
      (delegate as? GraphRelationshipDelegate)?.graph?(graph, updated: relationship, source: source)
    case .deletedRelationship(let relationship):
      (delegate as? GraphRelationshipDelegate)?.graph?(graph, deleted: relationship, source: source)
    case .addedRelationshipProperty(let relationship, let name, let value):
      (delegate as? GraphRelationshipDelegate)?.graph?(graph, relationship: relationship, added: name, with: value, source: source)
    case .updatedRelationshipProperty(let relationship, let name, let value):
      (delegate as? GraphRelationshipDelegate)?.graph?(graph, relationship: relationship, updated: name, with: value, source: source)
    case .removedRelationshipProperty(let relationship, let name, let value):
      (delegate as? GraphRelationshipDelegate)?.graph?(graph, relationship: relationship, removed: name, with: value, source: source)
    case .addedRelationshipTag(let relationship, let name):
      (delegate as? GraphRelationshipDelegate)?.graph?(graph, relationship: relationship, added: name, source: source)
    case .removedRelationshipTag(let relationship, let name):
      (delegate as? GraphRelationshipDelegate)?.graph?(graph, relationship: relationship, removed: name, source: source)
    case .addedRelationshipToGroup(let relationship, let name):
      (delegate as? GraphRelationshipDelegate)?.graph?(graph, relationship: relationship, addedTo: name, source: source)
    case .removedRelationshipFromGroup(let relationship, let name):
      (delegate as? GraphRelationshipDelegate)?.graph?(graph, relationship: relationship, removedFrom: name, source: source)

    case .insertedAction(let action):
      (delegate as? GraphActionDelegate)?.graph?(graph, inserted: action, source: source)
    case .deletedAction(let action):
      (delegate as? GraphActionDelegate)?.graph?(graph, deleted: action, source: source)
    case .addedActionProperty(let action, let name, let value):
      (delegate as? GraphActionDelegate)?.graph?(graph, action: action, added: name, with: value, source: source)
    case .updatedActionProperty(let action, let name, let value):
      (delegate as? GraphActionDelegate)?.graph?(graph, action: action, updated: name, with: value, source: source)
    case .removedActionProperty(let action, let name, let value):
      (delegate as? GraphActionDelegate)?.graph?(graph, action: action, removed: name, with: value, source: source)
    case .addedActionTag(let action, let name):
      (delegate as? GraphActionDelegate)?.graph?(graph, action: action, added: name, source: source)
    case .removedActionTag(let action, let name):
      (delegate as? GraphActionDelegate)?.graph?(graph, action: action, removed: name, source: source)
    case .addedActionToGroup(let action, let name):
      (delegate as? GraphActionDelegate)?.graph?(graph, action: action, addedTo: name, source: source)
    case .removedActionFromGroup(let action, let name):
      (delegate as? GraphActionDelegate)?.graph?(graph, action: action, removedFrom: name, source: source)
    }
  }
}

//
//  File.swift
//  UDFKit
//
//  Created by Иван Спирин on 05.08.2025.
//

import Foundation
import Combine

@_spi(Internals)
public class CancellablesCollection {
    private var storage: [AnyHashable: Set<AnyCancellable>] = [:]
    private let lock = NSRecursiveLock()
    
    func insert(_ cancellable: AnyCancellable, at id: String) {
        lock.lock()
        defer { lock.unlock() }
        
        self.storage[id, default: []].insert(cancellable)
    }
    
    func remove(_ cancellable: AnyCancellable, at id: String) {
        lock.lock()
        defer { lock.unlock() }
        
        self.storage[id]?.remove(cancellable)
        if storage[id]?.isEmpty == true {
            self.storage[id] = nil
        }
    }
    
    func cancel(id: String) {
        lock.lock()
        defer { lock.unlock() }
        
        self.storage[id]?.forEach { $0.cancel() }
        self.storage[id] = nil
    }
}

//
//  File.swift
//  UDFKit
//
//  Created by Иван Спирин on 06.08.2025.
//

import Foundation

@dynamicMemberLookup
public final class LockIsolated<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSRecursiveLock()

    public init(_ value: @autoclosure @Sendable () -> Value) {
        self._value = value()
    }
    
    public subscript<Subject: Sendable>(dynamicMember keyPath: KeyPath<Value, Subject>) -> Subject {
        lock.lock()
        defer { lock.unlock() }
        return self._value[keyPath: keyPath]
    }

    public func setValue(_ value: @autoclosure @Sendable () -> Value) {
        lock.lock()
        defer { lock.unlock() }
        self._value = value()
    }

    public var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    
    public func withValue<T: Sendable>(_ operation: @Sendable (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        var value = self._value
        defer {
            self._value = value
            lock.unlock()
        }
        return try operation(&value)
    }
}

//
//  File.swift
//  UDFKit
//
//  Created by Иван Спирин on 05.08.2025.
//

import Foundation

final class CancellablesCollection: @unchecked Sendable {
    private var storage: [String: [UUID: @Sendable () -> Void]] = [:]
    private let lock = NSLock()

    func run<T: Sendable>(
        id: String,
        cancelInFlight: Bool,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task { try await operation() }
        let key = UUID()

        register(key, at: id, cancelInFlight: cancelInFlight) { task.cancel() }.forEach { $0() }
        defer { remove(key, at: id) }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func register(
        _ key: UUID,
        at id: String,
        cancelInFlight: Bool,
        cancel: @escaping @Sendable () -> Void
    ) -> [@Sendable () -> Void] {
        lock.lock()
        defer { lock.unlock() }
        let inFlight = cancelInFlight ? storage.removeValue(forKey: id).map { Array($0.values) } ?? [] : []
        storage[id, default: [:]][key] = cancel
        return inFlight
    }

    private func remove(_ key: UUID, at id: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[id]?[key] = nil
        if storage[id]?.isEmpty == true {
            storage[id] = nil
        }
    }
}

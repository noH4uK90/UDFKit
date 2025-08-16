//
//  File.swift
//  UDFKit
//
//  Created by Иван Спирин on 05.08.2025.
//

import Foundation
import Combine

public struct Effect<Action>: Sendable {

    enum Operation: Sendable {
        case none
        case run(@Sendable (_ send: Send<Action>) async throws -> Void)
    }

    let operation: Operation

    public static var none: Self {
        Self(operation: .none)
    }

    public static func run(
        _ operation: @escaping @Sendable (_ send: Send<Action>) async throws -> Void
    ) -> Self {
        Self(
            operation: .run { send in                
                do {
                    try await operation(send)
                } catch is CancellationError {
                    return
                }
            }
        )
    }
}

@_spi(Internals) nonisolated(unsafe) public let _cancellablesCollection = CancellablesCollection()

extension Effect {
    
    public func cancellable(id: String, cancelInFlight: Bool = false) -> Self {
        
        switch self.operation {
            case .none:
                return .none
            case let .run(operation):
                return Self(
                    operation: .run { send in
                        do {
                            try await withTaskCancellation(id: id, cancelInFlight: cancelInFlight) {
                                try await operation(send)
                            }
                        } catch {
                            print("Cancellation Error: \(error)")
                        }
                    }
                )
        }
    }
    
    func withTaskCancellation<T: Sendable>(
        id: String,
        cancelInFlight: Bool = false,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if cancelInFlight {
            _cancellablesCollection.cancel(id: id)
        }
        
        let task = Task { try await operation() }
        let cancellable = AnyCancellable {
            task.cancel()
        }
        
        _cancellablesCollection.insert(cancellable, at: id)
        
        defer {
            _cancellablesCollection.remove(cancellable, at: id)
        }
        
        do {
            return try await task.value
        } catch {
            return try Result<T, any Error>.failure(error).get()
        }
    }
}

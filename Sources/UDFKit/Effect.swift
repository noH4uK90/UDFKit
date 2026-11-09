//
//  File.swift
//  UDFKit
//
//  Created by Иван Спирин on 05.08.2025.
//

import Foundation

public struct Effect<Action>: Sendable {

    struct Context: Sendable {
        let cancellables: CancellablesCollection
    }

    enum Operation: Sendable {
        case none
        case run(@Sendable (_ send: Send<Action>, _ context: Context) async throws -> Void)
    }

    let operation: Operation

    public static var none: Self {
        Self(operation: .none)
    }

    public static func run(
        _ operation: @escaping @Sendable (_ send: Send<Action>) async throws -> Void
    ) -> Self {
        Self(
            operation: .run { send, _ in
                do {
                    try await operation(send)
                } catch is CancellationError {
                    return
                }
            }
        )
    }
}

extension Effect {

    public func cancellable(id: String, cancelInFlight: Bool = false) -> Self {
        switch self.operation {
        case .none:
            return .none
        case let .run(operation):
            return Self(
                operation: .run { send, context in
                    do {
                        try await context.cancellables.run(id: id, cancelInFlight: cancelInFlight) {
                            try await operation(send, context)
                        }
                    } catch is CancellationError {
                        return
                    }
                }
            )
        }
    }
}

//
//  File.swift
//  UDFKit
//
//  Created by Иван Спирин on 05.08.2025.
//

import Foundation

@MainActor
public struct Send<Action>: Sendable {

    let send: @MainActor @Sendable (Action) -> Void

    init(send: @escaping @MainActor @Sendable (Action) -> Void) {
        self.send = send
    }

    public func callAsFunction(_ action: Action) {
        guard !Task.isCancelled else { return }
        self.send(action)
    }
}

//
//  File.swift
//  UDFKit
//
//  Created by Иван Спирин on 05.08.2025.
//

import Foundation
import Combine

@MainActor
public protocol StoreCore<State, Action>: Sendable {
    associatedtype State
    
    associatedtype Action
    
    var state: State { get }
    
    func send(_ action: Action) -> Task<Void, Never>?

    var effectCancellables: [UUID: AnyCancellable] { get }
}

@dynamicMemberLookup
@preconcurrency@MainActor
public final class Store<Root: Reducer>: StoreCore, ObservableObject {
    @Published public var state: Root.State
    
    public var onOutput: (@MainActor (Root.Output) -> Void)?
    
    private var bufferedActions: [Root.Action] = []
    private var isSending = false
    public var effectCancellables: [UUID : AnyCancellable] = [:]
    
    let reducer: Root
    
    public init(state: Root.State, reducer: Root) {
        self.state = state
        self.reducer = reducer
    }
    
    @discardableResult
    public func send(_ action: Root.Action) -> Task<Void, Never>? {
        self.bufferedActions.append(action)
        guard !self.isSending else { return nil }
        
        self.isSending = true
        var currentState = self.state
        let tasks = LockIsolated<[Task<Void, Never>]>([])
        
        defer {
            withExtendedLifetime(self.bufferedActions) {
                self.bufferedActions.removeAll()
            }
            self.state = currentState
            self.isSending = false
            if !self.bufferedActions.isEmpty {
                if let task = self.send(self.bufferedActions.removeLast()) {
                    tasks.withValue { $0.append(task) }
                }
            }
        }
        
        var index = self.bufferedActions.startIndex
        while index < self.bufferedActions.endIndex {
            defer { index += 1 }
            let action = self.bufferedActions[index]
            let result = reducer.reduce(&currentState, action: action)
            let uuid = UUID()
            
            if let output = result.output {
                onOutput?(output)
            }
            
            let effect = result.effect
            
            switch effect.operation {
            case .none:
                break
            case let .run(operation):
                let task = Task { @MainActor [weak self] in
                    do {
                        try await operation(
                            Send { action in
                                self?.send(action)
                            }
                        )
                    } catch {
                        print("Effect error: \(error)")
                    }
                    await MainActor.run {
                        self?.effectCancellables[uuid] = nil
                    }
                }
                tasks.withValue { $0.append(task) }
                self.effectCancellables[uuid] = AnyCancellable { @Sendable in
                    task.cancel()
                }
            }
        }
        
        guard !tasks.isEmpty else { return nil }
        return Task { @MainActor in
            await withTaskCancellationHandler {
                var index = tasks.startIndex
                while index < tasks.endIndex {
                    defer { index += 1 }
                    await tasks[index].value
                }
            } onCancel: {
                var index = tasks.startIndex
                defer { index += 1 }
                tasks[index].cancel()
            }
        }
    }
    
    public subscript<T>(dynamicMember keyPath: KeyPath<Root.State, T>) -> T {
        state[keyPath: keyPath]
    }
}

public typealias StoreOf<R: Reducer> = Store<R>

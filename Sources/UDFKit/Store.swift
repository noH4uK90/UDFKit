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
@preconcurrency @MainActor
public final class Store<Root: Reducer>: StoreCore, ObservableObject {
    @Published public private(set) var state: Root.State
    
    public var onOutput: (@MainActor (Root.Output) -> Void)?
    
    public private(set) var effectCancellables: [UUID : AnyCancellable] = [:]

    private var bufferedActions: [Root.Action] = []
    private var isSending = false
    private let cancellables = CancellablesCollection()
    
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
        var tasks: [Task<Void, Never>] = []

        var index = self.bufferedActions.startIndex
        while index < self.bufferedActions.endIndex {
            let action = self.bufferedActions[index]
            index += 1

            var currentState = self.state
            let result = reducer.reduce(&currentState, action: action)
            self.state = currentState

            if let output = result.output {
                onOutput?(output)
            }

            if let task = start(result.effect) {
                tasks.append(task)
            }
        }

        self.bufferedActions.removeAll()
        self.isSending = false

        guard !tasks.isEmpty else { return nil }
        return Task { [tasks] in
            await withTaskCancellationHandler {
                for task in tasks {
                    await task.value
                }
            } onCancel: {
                tasks.forEach { $0.cancel() }
            }
        }
    }

    private func start(_ effect: Effect<Root.Action>) -> Task<Void, Never>? {
        guard case let .run(operation) = effect.operation else { return nil }

        let uuid = UUID()
        let context = Effect<Root.Action>.Context(cancellables: cancellables)
        let task = Task { [weak self] in
            let children = LockIsolated<[Task<Void, Never>]>([])
            await withTaskCancellationHandler {
                do {
                    try await operation(
                        Send { action in
                            guard let child = self?.send(action) else { return }
                            children.withValue { $0.append(child) }
                            if Task.isCancelled { child.cancel() }
                        },
                        context
                    )
                } catch {
                    print("Effect error: \(error)")
                }

                var index = 0
                while let child = children.withValue({ [index] in index < $0.count ? $0[index] : nil }) {
                    index += 1
                    await child.value
                }
            } onCancel: {
                children.value.forEach { $0.cancel() }
            }
            self?.effectCancellables[uuid] = nil
        }
        self.effectCancellables[uuid] = AnyCancellable { task.cancel() }
        return task
    }
    
    public subscript<T>(dynamicMember keyPath: KeyPath<Root.State, T>) -> T {
        state[keyPath: keyPath]
    }
}

public typealias StoreOf<R: Reducer> = Store<R>

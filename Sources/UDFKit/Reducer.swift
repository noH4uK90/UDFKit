//
//  File.swift
//  UDFKit
//
//  Created by Иван Спирин on 05.08.2025.
//

import Foundation

public protocol Reducer<State, Action> {
    associatedtype State
    associatedtype Action
    associatedtype Output = Never
    
    func reduce(_ state: inout State, action: Action) -> ReducerResult<Action, Output>
}

public struct ReducerResult<Action, Output> {
    public let effect: Effect<Action>
    public let output: Output?
    
    public init(effect: Effect<Action>, output: Output? = nil) {
        self.effect = effect
        self.output = output
    }
}

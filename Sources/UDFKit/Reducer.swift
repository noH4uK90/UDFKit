//
//  File.swift
//  UDFKit
//
//  Created by Иван Спирин on 05.08.2025.
//

import Foundation

public protocol ReducerDependency: Sendable, AnyObject {}

public protocol EmptyReducerDependency: ReducerDependency {}

public protocol Reducer<State, Action> {
    associatedtype State
    
    associatedtype Action
    
    associatedtype Dependency: ReducerDependency = EmptyReducerDependency
    
    func reduce(_ state: inout State, action: Action, dependency: Dependency) -> Effect<Action>
}

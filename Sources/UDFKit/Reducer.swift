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
    associatedtype Dependency
    
    var dependency: Dependency { get }
    
    func reduce(_ state: inout State, action: Action) -> Effect<Action>
}

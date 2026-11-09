import Combine
import Foundation
import Testing
import UDFKit

private struct TwoEffectsReducer: Reducer {
    struct State {}

    enum Action {
        case first
        case second
    }

    enum Output {
        case requestSecond
    }

    let cancelled: CancelLog

    func reduce(_ state: inout State, action: Action) -> ReducerResult<Action, Output> {
        switch action {
        case .first:
            return ReducerResult(effect: sleeping(id: 1), output: .requestSecond)
        case .second:
            return ReducerResult(effect: sleeping(id: 2))
        }
    }

    private func sleeping(id: Int) -> Effect<Action> {
        .run { [cancelled] _ in
            await withTaskCancellationHandler {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            } onCancel: {
                cancelled.insert(id)
            }
        }
    }
}

private final class CancelLog: @unchecked Sendable {
    private var ids: Set<Int> = []
    private let lock = NSLock()

    func insert(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        ids.insert(id)
    }

    var value: Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}

@MainActor
@Test func cancellingReturnedTaskCancelsEveryEffect() async throws {
    let log = CancelLog()
    let store = Store(state: .init(), reducer: TwoEffectsReducer(cancelled: log))
    store.onOutput = { [weak store] _ in store?.send(.second) }

    let task = try #require(store.send(.first))
    task.cancel()
    await task.value

    #expect(log.value == [1, 2])
}

private struct ResendReducer: Reducer {
    struct State {
        var triggered = false
    }

    enum Action {
        case trigger
        case work
    }

    let cancelled: CancelLog

    func reduce(_ state: inout State, action: Action) -> ReducerResult<Action, Never> {
        switch action {
        case .trigger:
            state.triggered = true
            return ReducerResult(effect: .none)
        case .work:
            return ReducerResult(effect: .run { [cancelled] _ in
                await withTaskCancellationHandler {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                } onCancel: {
                    cancelled.insert(3)
                }
            })
        }
    }
}

@MainActor
@Test func actionSentDuringStateWriteIsCoveredByReturnedTask() async throws {
    let log = CancelLog()
    let store = Store(state: .init(), reducer: ResendReducer(cancelled: log))
    var didSend = false
    let subscription = store.$state.sink { [weak store] state in
        MainActor.assumeIsolated {
            guard state.triggered, !didSend else { return }
            didSend = true
            store?.send(.work)
        }
    }
    defer { subscription.cancel() }

    let task = try #require(store.send(.trigger))
    task.cancel()
    await task.value

    #expect(log.value == [3])
}

private struct CancellableReducer: Reducer {
    struct State {
        var finished = false
    }

    enum Action {
        case start(cancelInFlight: Bool)
        case finished
    }

    let cancelled: CancelLog
    var duration: UInt64 = 10_000_000_000

    func reduce(_ state: inout State, action: Action) -> ReducerResult<Action, Never> {
        switch action {
        case let .start(cancelInFlight):
            return ReducerResult(effect: Effect<Action>.run { [cancelled, duration] send in
                await withTaskCancellationHandler {
                    try? await Task.sleep(nanoseconds: duration)
                } onCancel: {
                    cancelled.insert(1)
                }
                await send(.finished)
            }.cancellable(id: "shared", cancelInFlight: cancelInFlight))
        case .finished:
            state.finished = true
            return ReducerResult(effect: .none)
        }
    }
}

@MainActor
@Test func cancellingReturnedTaskCancelsCancellableEffect() async throws {
    let log = CancelLog()
    let store = Store(state: .init(), reducer: CancellableReducer(cancelled: log))

    let task = try #require(store.send(.start(cancelInFlight: false)))
    task.cancel()
    await task.value

    #expect(log.value == [1])
    #expect(!store.finished)
}

@MainActor
@Test func cancelInFlightCancelsPreviousEffectWithSameId() async throws {
    let log = CancelLog()
    let store = Store(state: .init(), reducer: CancellableReducer(cancelled: log, duration: 200_000_000))

    let first = try #require(store.send(.start(cancelInFlight: true)))
    try await Task.sleep(nanoseconds: 20_000_000)
    let second = try #require(store.send(.start(cancelInFlight: true)))
    await first.value
    await second.value

    #expect(log.value == [1])
    #expect(store.finished)
}

@MainActor
@Test func cancellationIdsAreScopedToStore() async throws {
    let logA = CancelLog()
    let logB = CancelLog()
    let storeA = Store(state: .init(), reducer: CancellableReducer(cancelled: logA, duration: 100_000_000))
    let storeB = Store(state: .init(), reducer: CancellableReducer(cancelled: logB, duration: 100_000_000))

    let taskA = try #require(storeA.send(.start(cancelInFlight: true)))
    try await Task.sleep(nanoseconds: 20_000_000)
    let taskB = try #require(storeB.send(.start(cancelInFlight: true)))
    await taskA.value
    await taskB.value

    #expect(logA.value.isEmpty)
    #expect(storeA.finished)
    #expect(storeB.finished)
}

private struct OutputReducer: Reducer {
    struct State {
        var count = 0
    }

    enum Action {
        case increment
    }

    enum Output {
        case incremented
    }

    func reduce(_ state: inout State, action: Action) -> ReducerResult<Action, Output> {
        state.count += 1
        return ReducerResult(effect: .none, output: .incremented)
    }
}

@MainActor
@Test func onOutputObservesCommittedState() {
    let store = Store(state: .init(), reducer: OutputReducer())
    var observed: [Int] = []
    store.onOutput = { [weak store] _ in
        guard let store else { return }
        observed.append(store.count)
        if observed.count < 3 { store.send(.increment) }
    }

    store.send(.increment)

    #expect(observed == [1, 2, 3])
}

private struct ChainReducer: Reducer {
    struct State {
        var log: [String] = []
    }

    enum Action {
        case start
        case next
        case done
    }

    let cancelled: CancelLog
    var duration: UInt64 = 10_000_000_000

    func reduce(_ state: inout State, action: Action) -> ReducerResult<Action, Never> {
        switch action {
        case .start:
            state.log.append("start")
            return ReducerResult(effect: .run { send in await send(.next) })
        case .next:
            state.log.append("next")
            return ReducerResult(effect: .run { [cancelled, duration] send in
                await withTaskCancellationHandler {
                    try? await Task.sleep(nanoseconds: duration)
                } onCancel: {
                    cancelled.insert(4)
                }
                await send(.done)
            })
        case .done:
            state.log.append("done")
            return ReducerResult(effect: .none)
        }
    }
}

@MainActor
@Test func returnedTaskAwaitsActionsSentFromEffects() async {
    let store = Store(state: .init(), reducer: ChainReducer(cancelled: CancelLog(), duration: 10_000_000))

    await store.send(.start)?.value

    #expect(store.log == ["start", "next", "done"])
}

@MainActor
@Test func cancellingReturnedTaskCancelsEffectsOfActionsSentFromEffects() async throws {
    let log = CancelLog()
    let store = Store(state: .init(), reducer: ChainReducer(cancelled: log))

    let task = try #require(store.send(.start))
    while store.log.count < 2 { await Task.yield() }
    task.cancel()
    await task.value

    #expect(log.value == [4])
    #expect(store.log == ["start", "next"])
}

private struct LogReducer: Reducer {
    struct State {
        var log: [String] = []
        var count = 0
    }

    enum Action {
        case trigger
        case a
        case b
        case count
    }

    func reduce(_ state: inout State, action: Action) -> ReducerResult<Action, Never> {
        switch action {
        case .trigger: state.log.append("trigger")
        case .a: state.log.append("a")
        case .b: state.log.append("b")
        case .count: state.count += 1
        }
        return ReducerResult(effect: .none)
    }
}

@MainActor
@Test func actionsSentDuringStateWriteKeepOrder() {
    let store = Store(state: .init(), reducer: LogReducer())
    var didSend = false
    let subscription = store.$state.sink { [weak store] state in
        MainActor.assumeIsolated {
            guard state.log == ["trigger"], !didSend else { return }
            didSend = true
            store?.send(.a)
            store?.send(.b)
        }
    }
    defer { subscription.cancel() }

    store.send(.trigger)

    #expect(store.log == ["trigger", "a", "b"])
}

@MainActor
@Test func longChainOfActionsSentDuringStateWriteDoesNotRecurse() {
    let store = Store(state: .init(), reducer: LogReducer())
    let subscription = store.$state.sink { [weak store] state in
        MainActor.assumeIsolated {
            if state.count > 0, state.count < 100_000 { store?.send(.count) }
        }
    }
    defer { subscription.cancel() }

    store.send(.count)

    #expect(store.count == 100_000)
}

@MainActor
@Test func statePublishesOncePerAction() {
    let store = Store(state: .init(), reducer: OutputReducer())
    var outputs = 0
    store.onOutput = { [weak store] _ in
        outputs += 1
        guard outputs < 3 else { return }
        store?.send(.increment)
    }
    var published: [Int] = []
    let subscription = store.$state.dropFirst().sink { published.append($0.count) }
    defer { subscription.cancel() }

    store.send(.increment)

    #expect(published == [1, 2, 3])
}

private final class StoreBox<R: Reducer>: @unchecked Sendable {
    weak var store: Store<R>?
}

private struct SyncSendReducer: Reducer {
    struct State {
        var count = 0
    }

    enum Action {
        case start
        case increment
    }

    let box: StoreBox<SyncSendReducer>
    let observed: CancelLog

    func reduce(_ state: inout State, action: Action) -> ReducerResult<Action, Never> {
        switch action {
        case .start:
            return ReducerResult(effect: .run { [box, observed] send in
                await MainActor.run {
                    send(.increment)
                    observed.insert(box.store?.count ?? -1)
                }
            })
        case .increment:
            state.count += 1
            return ReducerResult(effect: .none)
        }
    }
}

@MainActor
@Test func actionSentFromEffectIsReducedBeforeSendReturns() async {
    let box = StoreBox<SyncSendReducer>()
    let observed = CancelLog()
    let store = Store(state: .init(), reducer: SyncSendReducer(box: box, observed: observed))
    box.store = store

    await store.send(.start)?.value

    #expect(observed.value == [1])
}

private struct LifecycleReducer: Reducer {
    struct State {}

    enum Action {
        case short
        case long
        case fail
        case noneCancellable
    }

    struct Failure: Error {}

    let cancelled: CancelLog

    func reduce(_ state: inout State, action: Action) -> ReducerResult<Action, Never> {
        switch action {
        case .short:
            return ReducerResult(effect: .run { _ in })
        case .long:
            return ReducerResult(effect: .run { [cancelled] _ in
                await withTaskCancellationHandler {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                } onCancel: {
                    cancelled.insert(5)
                }
            })
        case .fail:
            return ReducerResult(effect: .run { _ in throw Failure() })
        case .noneCancellable:
            return ReducerResult(effect: Effect<Action>.none.cancellable(id: "none", cancelInFlight: true))
        }
    }
}

@MainActor
@Test func finishedEffectIsRemovedFromEffectCancellables() async {
    let store = Store(state: .init(), reducer: LifecycleReducer(cancelled: CancelLog()))

    let task = store.send(.short)
    #expect(store.effectCancellables.count == 1)
    await task?.value

    #expect(store.effectCancellables.isEmpty)
}

@MainActor
@Test func cancellingEffectCancellableCancelsEffect() async throws {
    let log = CancelLog()
    let store = Store(state: .init(), reducer: LifecycleReducer(cancelled: log))

    let task = try #require(store.send(.long))
    let cancellable = try #require(store.effectCancellables.values.first)
    cancellable.cancel()
    await task.value

    #expect(log.value == [5])
    #expect(store.effectCancellables.isEmpty)
}

@MainActor
@Test func deallocatingStoreCancelsEffects() async throws {
    let log = CancelLog()
    var store: Store<LifecycleReducer>? = Store(state: .init(), reducer: LifecycleReducer(cancelled: log))
    weak let weakStore = store

    let task = try #require(store?.send(.long))
    store = nil
    await task.value

    #expect(weakStore == nil)
    #expect(log.value == [5])
}

@MainActor
@Test func failingEffectCompletesAndStoreKeepsWorking() async {
    let store = Store(state: .init(), reducer: LifecycleReducer(cancelled: CancelLog()))

    await store.send(.fail)?.value

    #expect(store.effectCancellables.isEmpty)
    await store.send(.short)?.value
    #expect(store.effectCancellables.isEmpty)
}

@MainActor
@Test func cancellableNoneProducesNoTask() {
    let store = Store(state: .init(), reducer: LifecycleReducer(cancelled: CancelLog()))

    #expect(store.send(.noneCancellable) == nil)
    #expect(store.effectCancellables.isEmpty)
}

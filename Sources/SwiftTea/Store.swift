import Foundation
import Observation

/// A thread-safe, observable state container that manages application state through a unidirectional data flow pattern.
///
/// The `Store` provides an Elm-inspired architecture for managing application state with powerful effect handling capabilities.
/// It ensures all state updates happen on the main thread and provides fine-grained control over side effects including
/// async operations, cancellable tasks, and streaming data.
///
/// ## Overview
///
/// The store follows a unidirectional data flow where actions are dispatched to trigger state updates through pure
/// reducer functions. Side effects are handled separately through the ``Effect`` system, allowing for clean separation
/// of concerns and predictable state management.
///
/// ```swift
/// // Without environment
/// let store = Store(
///     initialState: AppState(),
///     reduce: { state, action in
///         switch action {
///         case .increment:
///             var newState = state
///             newState.counter += 1
///             return (newState, .none)
///         }
///     }
/// )
///
/// // With environment
/// let store = Store(
///     initialState: AppState(),
///     reduce: { state, action, env in
///         switch action {
///         case .loadData:
///             return (state, .task {
///                 let data = try await env.dataService.fetch()
///                 return .dataLoaded(data)
///             })
///         }
///     },
///     environment: AppEnvironment.live
/// )
/// ```
///
/// ## SwiftUI Integration
///
/// The store integrates seamlessly with SwiftUI through the `@Observable` macro:
///
/// ```swift
/// struct ContentView: View {
///     @Environment(Store<AppState, AppAction>.self) private var store
///
///     var body: some View {
///         Text("Count: \(store.state.counter)")
///         Button("Increment") {
///             store.send(.increment)
///         }
///     }
/// }
/// ```
///
/// ## Topics
///
/// ### Creating a Store
/// - ``init(initialState:reduce:)``
/// - ``init(initialState:reduce:environment:)``
///
/// ### Dispatching Actions
/// - ``send(_:)``
///
/// ### Managing Effects
/// - ``cancel(_:)``
///
/// ### State Access
/// - ``state``
@MainActor
@Observable public final class Store<State, Action: Sendable, Environment>: Sendable {
	/// The current state of the store.
	///
	/// This property is observable and will automatically trigger SwiftUI view updates when changed.
	/// All state updates happen on the main thread to ensure UI consistency.
	public private(set) var state: State
	
	/// The reducer function that handles state updates and effect creation.
	private let reduce: ReducerFunction
	
	/// The environment containing dependencies for the reducer.
	private let environment: Environment
	
	/// Dictionary of active cancellable tasks and streams, keyed by their identifier.
	///
	/// Each entry contains both the task and a unique token to handle race conditions safely.
	private var cancellables: [String: (task: Task<Void, Never>, token: UUID)] = [:]
	
	/// Type alias for reducer functions.
	private typealias ReducerFunction = (State, Action, Environment) -> (State, Effect<Action>)
	
	/// Creates a new store with the specified initial state, reducer function, and environment.
	///
	/// Use this initializer when your reducer needs access to external dependencies like
	/// network services, databases, or other side-effect producing systems.
	///
	/// ```swift
	/// let store = Store(
	///     initialState: AppState(),
	///     reduce: { state, action, env in
	///         switch action {
	///         case .loadData:
	///             return (state, .task {
	///                 let data = try await env.apiService.fetch()
	///                 return .dataLoaded(data)
	///             })
	///         }
	///     },
	///     environment: AppEnvironment.live
	/// )
	/// ```
	///
	/// - Parameters:
	///   - initialState: The initial state value for the store
	///   - reduce: A pure function that takes the current state, an action, and environment, returning a new state and effect
	///   - environment: The environment containing dependencies for the reducer
	public init(
		initialState state: State,
		reduce: @escaping (State, Action, Environment) -> (State, Effect<Action>),
		environment: Environment
	) {
		self.state = state
		self.reduce = reduce
		self.environment = environment
	}
	
	/// Dispatches an action to the store, triggering state updates and effect execution.
	///
	/// This method synchronously updates the state based on the reducer function and then
	/// asynchronously handles any returned effects. All state updates are guaranteed to
	/// happen on the main thread.
	///
	/// ```swift
	/// store.send(.increment)
	/// store.send(.loadData)
	/// ```
	///
	/// - Parameter action: The action to dispatch to the store
	public func send(_ action: Action) {
		let (newState, effect) = reduce(state, action, environment)
		state = newState
		
		handleEffect(effect)
	}
	
	/// Handles the execution of effects returned from the reducer.
	///
	/// This method processes different types of effects including one-time tasks,
	/// cancellable operations, streams, cancellation requests, and effect sequences.
	/// It manages the lifecycle of long-running operations and ensures proper cleanup.
	///
	/// - Parameter effect: The effect to execute
	private func handleEffect(_ effect: Effect<Action>) {
		switch effect {
			case .none:
				break
				
			case .sequence(let effects):
				effects.forEach(handleEffect)
				
			case .task(let operation):
				Task {
					do {
						let action = try await operation()
						await MainActor.run { self.send(action) }
					} catch {
						print("Effect error: \(error)")
					}
				}
				
			case .cancellable(let operation, let id):
				
				// Cancel and remove any existing task for this ID
				if let (existingTask, existingToken) = cancellables[id] {
					existingTask.cancel()
					print("Cancelled previous task for id: \(id) with token: \(existingToken)")
				}
				
				let taskToken = UUID() // Generate a unique token for this task instance
				
				let task = Task { [weak self] in
					guard let self = self else { return }
					do {
						let action = try await operation()
						await MainActor.run { self.send(action) }
					} catch is CancellationError {
						print("Cancellable effect \(id) (token: \(taskToken)) was cancelled.")
					} catch {
						print("Cancellable effect \(id) (token: \(taskToken)) error: \(error)")
					}
					
					// Cleanup
					await MainActor.run { [weak self] in
						guard let strongSelf = self else { return }
						if let (_, storedToken) = strongSelf.cancellables[id], storedToken == taskToken {
							strongSelf.cancellables.removeValue(forKey: id)
							print("Cancellable effect task \(id) (token: \(taskToken)) removed itself from cancellables.")
						} else {
							print("Cancellable effect task \(id) (token: \(taskToken)) finished, but was already replaced or removed.")
						}
					}
				}
				cancellables[id] = (task: task, token: taskToken)
				
			case .stream(let actionStream, let id):
				if let (existingTask, existingToken) = cancellables[id] {
					print("[Store.handleEffect] Cancelling EXISTING task for ID: \(id) with token: \(existingToken)")
					existingTask.cancel()
				}
				
				let newConsumeTaskToken = UUID() // If using tokens
				let newConsumeTask = Task { [weak self] in
					var actionsProcessed = 0
					do {
						for await eventFromStream in actionStream { // Consuming the stream
							actionsProcessed += 1
							if Task.isCancelled {
								print("[Store.handleEffect] Consumer Task (ID: \(id), Token: \(newConsumeTaskToken)): Cancellation detected during iteration.")
								break
							}
							await MainActor.run { self?.send(eventFromStream) } // Assuming 'send' dispatches back to your reducer
						}
						print("[Store.handleEffect] Consumer Task (ID: \(id), Token: \(newConsumeTaskToken)): Loop FINISHED NATURALLY after \(actionsProcessed) actions.")
					} catch is CancellationError {
						print("[Store.handleEffect] Consumer Task (ID: \(id), Token: \(newConsumeTaskToken)): Caught CANCELLATION ERROR after \(actionsProcessed) actions.")
					} catch {
						print("[Store.handleEffect] Consumer Task (ID: \(id), Token: \(newConsumeTaskToken)): Caught OTHER ERROR: \(error) after \(actionsProcessed) actions.")
					}
					print("[Store.handleEffect] Consumer Task (ID: \(id), Token: \(newConsumeTaskToken)): IS ENDING.")
				}
				
				cancellables[id] = (task: newConsumeTask, token: newConsumeTaskToken)
				print("[Store.handleEffect] Stored new consumer task for ID: \(id) with token: \(newConsumeTaskToken)")
				
			case .cancel(let id):
				cancel(id)
		}
	}
	
	/// Cancels a running cancellable effect or stream by its identifier.
	///
	/// This method immediately cancels any active task or stream associated with the given ID
	/// and removes it from the store's internal tracking. The cancelled task will receive a
	/// `CancellationError` and should handle cleanup appropriately.
	///
	/// ```swift
	/// // Start a cancellable operation
	/// store.send(.startLongRunningTask)
	///
	/// // Later, cancel it
	/// store.cancel("long-running-task")
	/// ```
	///
	/// - Parameter id: The unique identifier of the effect to cancel
	public func cancel(_ id: String) {
		if let (taskToCancel, token) = cancellables[id] {
			print("Attempting to cancel task for id: \(id) with token: \(token)")
			taskToCancel.cancel()
			cancellables.removeValue(forKey: id)
		} else {
			print("No active cancellable effect or stream found with id: \(id) to cancel.")
		}
	}
}

// MARK: - Convenience Initializer for Environment-less Store

public extension Store {
	/// Creates a new store without an environment dependency.
	///
	/// Use this initializer when your reducer doesn't need access to external dependencies.
	/// The reducer function receives only the current state and action.
	///
	/// ```swift
	/// let store = Store(
	///     initialState: AppState(counter: 0),
	///     reduce: { state, action in
	///         var newState = state
	///         switch action {
	///         case .increment:
	///             newState.counter += 1
	///             return (newState, .none)
	///         case .reset:
	///             newState.counter = 0
	///             return (newState, .none)
	///         }
	///     }
	/// )
	/// ```
	///
	/// - Parameters:
	///   - initialState: The initial state value for the store
	///   - reduce: A pure function that takes the current state and an action, returning a new state and effect
	convenience init(
		initialState state: State,
		reduce: @escaping (State, Action) -> (State, Effect<Action>)
	) where Environment == Void {
		self.init(
			initialState: state,
			reduce: { state, action, _ in reduce(state, action) },
			environment: ()
		)
	}
}

/// Represents different types of side effects that can be executed by the store.
///
/// Effects provide a way to handle side effects in a predictable and composable manner.
/// They are returned from reducer functions alongside state updates and are executed
/// asynchronously by the store.
///
/// ## Overview
///
/// The effect system allows you to handle various types of side effects while keeping
/// your reducer functions pure. Effects can represent one-time operations, cancellable
/// tasks, continuous data streams, or combinations of multiple effects.
///
/// ```swift
/// // No side effect
/// return (newState, .none)
///
/// // Single async task
/// return (newState, .task {
///     let data = try await fetchData()
///     return .dataLoaded(data)
/// })
///
/// // Cancellable operation
/// return (newState, .cancellable({
///     let result = try await longOperation()
///     return .operationComplete(result)
/// }, "operation-id"))
///
/// // Cancel a running effect
/// return (newState, .cancel("operation-id"))
/// ```
///
/// ## Topics
///
/// ### Basic Effects
/// - ``none``
/// - ``task(_:)``
/// - ``sequence(_:)``
///
/// ### Advanced Effects
/// - ``cancellable(_:_:)``
/// - ``stream(_:id:)``
/// - ``cancel(_:)``
///
/// ### Effect Transformation
/// - ``map(_:)``
public enum Effect<Action: Sendable> {
	/// No side effect to execute.
	///
	/// Use this when an action should only update state without triggering any side effects.
	///
	/// ```swift
	/// case .increment:
	///     var newState = state
	///     newState.counter += 1
	///     return (newState, .none)
	/// ```
	case none
	
	/// Execute multiple effects in sequence.
	///
	/// All effects in the array will be executed concurrently, not sequentially.
	/// Use this when you need to trigger multiple side effects from a single action.
	///
	/// ```swift
	/// case .initializeApp:
	///     return (state, .sequence([
	///         .task { .loadUserPreferences },
	///         .task { .checkForUpdates },
	///         .task { .initializeAnalytics }
	///     ]))
	/// ```
	///
	/// - Parameter effects: An array of effects to execute
	case sequence([Effect<Action>])
	
	/// Execute a single async operation that returns an action.
	///
	/// Use this for one-time async operations like network requests or file I/O.
	/// The operation runs on a background thread and dispatches the returned action
	/// back to the store on the main thread.
	///
	/// ```swift
	/// case .loadData:
	///     return (state, .task {
	///         let data = try await networkService.fetchData()
	///         return .dataLoaded(data)
	///     })
	/// ```
	///
	/// - Parameter operation: An async function that returns an action
	case task(() async throws -> Action)
	
	/// Execute a cancellable async operation with a unique identifier.
	///
	/// Use this for long-running operations that users might want to cancel, such as
	/// large file downloads or complex computations. If a new cancellable effect with
	/// the same ID is started, the previous one will be automatically cancelled.
	///
	/// ```swift
	/// case .startSearch(let query):
	///     return (state, .cancellable({
	///         let results = try await searchService.search(query)
	///         return .searchResults(results)
	///     }, "search"))
	/// ```
	///
	/// - Parameters:
	///   - operation: An async function that returns an action
	///   - id: A unique identifier for this cancellable operation
	case cancellable(() async throws -> Action, String)
	
	/// Handle continuous data streams with a unique identifier.
	///
	/// Use this for handling continuous data like location updates, sensor data,
	/// or real-time notifications. The stream will continue until cancelled or
	/// until it naturally completes.
	///
	/// ```swift
	/// case .startLocationUpdates:
	///     let locationStream = AsyncStream<Action> { continuation in
	///         // Set up location manager and yield location updates
	///         continuation.onTermination = { _ in
	///             // Cleanup when stream is cancelled
	///         }
	///     }
	///     return (state, .stream(locationStream, id: "location"))
	/// ```
	///
	/// - Parameters:
	///   - stream: An AsyncStream that yields actions
	///   - id: A unique identifier for this stream
	case stream(AsyncStream<Action>, id: String)
	
	/// Cancel a running cancellable effect or stream by its identifier.
	///
	/// Use this effect to cancel long-running operations from within the reducer.
	/// This is particularly useful when you need to cancel an effect based on state
	/// changes or in response to user actions. The effect will be cancelled immediately
	/// and removed from the store's tracking.
	///
	/// ```swift
	/// case .cancelSearch:
	///     return (state, .cancel("search"))
	///
	/// case .startNewSearch(let query):
	///     var newState = state
	///     newState.searchQuery = query
	///     return (newState, .sequence([
	///         .cancel("previous-search"),
	///         .cancellable({
	///             let results = try await searchService.search(query)
	///             return .searchResults(results)
	///         }, "previous-search")
	///     ]))
	/// ```
	///
	/// - Parameter id: The unique identifier of the effect to cancel
	case cancel(String)
}

public extension Effect {
	/// Transforms an effect from one action type to another.
	///
	/// This method is useful when composing different parts of your application that have
	/// different action types. It allows you to map effects from child features into
	/// parent action types.
	///
	/// ```swift
	/// // Map child effects to parent actions
	/// let childEffect: Effect<ChildAction> = .task { .childActionComplete }
	/// let parentEffect: Effect<ParentAction> = childEffect.map { childAction in
	///     return .child(childAction)
	/// }
	/// ```
	///
	/// - Parameter transform: A function that transforms the original action type to the new action type
	/// - Returns: A new effect with the transformed action type
	func map<OtherAction: Sendable>(_ transform: @Sendable @escaping (Action) -> OtherAction) -> Effect<OtherAction> {
		switch self {
			case .none:
				return .none
			case .sequence(let effects):
				return .sequence(effects.map { $0.map(transform) })
			case .task(let operation):
				return .task {
					let action = try await operation()
					return transform(action)
				}
			case .cancellable(let operation, let id):
				return .cancellable({
					let action = try await operation()
					return transform(action)
				}, id)
			case .stream(let actionStream, let id):
				let mappedStream = AsyncStream<OtherAction> { continuation in
					let task = Task {
						do {
							for try await originalAction in actionStream {
								if Task.isCancelled { continuation.finish(); break }
								continuation.yield(transform(originalAction))
							}
							continuation.finish()
						} catch {
							print("Error in original stream while mapping: \(error) for effect ID \(id)")
							continuation.finish()
						}
					}
					continuation.onTermination = { @Sendable _ in task.cancel() }
				}
				return .stream(mappedStream, id: id)
			case .cancel(let id):
				return .cancel(id)
		}
	}
}

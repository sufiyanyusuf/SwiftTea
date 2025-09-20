# Swift Tea - State Management with Effects

[![Swift](https://img.shields.io/badge/Swift-6.2+-orange.svg)](https://swift.org)

[![Platforms](https://img.shields.io/badge/Platforms-iOS%2017+%20|%20macOS%2014+%20|%20watchOS%2010+%20|%20tvOS%2017+-blue.svg)](https://developer.apple.com)
[![Swift Package Manager](https://img.shields.io/badge/Swift_Package_Manager-compatible-orange?style=flat-square)](https://img.shields.io/badge/Swift_Package_Manager-compatible-orange?style=flat-square)
[![License](https://img.shields.io/github/license/sufiyanyusuf/SwiftTea?refresh=1)](https://github.com/sufiyanyusuf/SwiftTea/blob/main/LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/sufiyanyusuf/SwiftTea?refresh=1)](https://github.com/sufiyanyusuf/SwiftTea/stargazers)
[![GitHub Issues](https://img.shields.io/github/issues/sufiyanyusuf/SwiftTea)](https://github.com/sufiyanyusuf/SwiftTea/issues)
[![GitHub Release](https://img.shields.io/github/v/release/sufiyanyusuf/SwiftTea)](https://github.com/sufiyanyusuf/SwiftTea/releases)
[![Documentation](https://img.shields.io/badge/Documentation-Available-brightgreen)](https://sufiyanyusuf.github.io/SwiftTea)

An Elm-inspired state management library for Swift that provides predictable state updates with powerful effect handling capabilities, including support for async operations, cancellable tasks, and streaming data.

## Overview

The Swift Tea library consists of two main components:
- **Store**: A generic state container that manages state updates and side effects
- **Effect**: An enumeration that represents different types of side effects that can be executed

## Core Components

### Store<State, Action>

A thread-safe, observable state container that manages application state through a unidirectional data flow pattern.

#### Key Features

- **Observable**: Automatically notifies SwiftUI views of state changes using the `@Observable` macro
- **MainActor Isolation**: Ensures all state updates happen on the main thread
- **Effect Management**: Handles various types of side effects including async tasks, cancellable operations, and data streams
- **Task Cancellation**: Provides fine-grained control over long-running operations

#### Initialization

```swift
let store = Store(
    initialState: MyState(),
    reduce: { state, action in
        // Return new state and any effects to execute
        return (newState, effect)
    }
)
```

**Parameters:**
- `initialState`: The initial state value
- `reduce`: A pure function that takes the current state and an action, returning a new state and an effect

#### Methods

##### `send(_ action: Action)`

Dispatches an action to the store, triggering state updates and effect execution.

```swift
store.send(.userTappedButton)
```

##### `cancel(_ id: String)`

Cancels a running cancellable effect or stream by its identifier.

```swift
store.cancel("network-request")
```

#### Implementation Details

The store maintains a dictionary of active cancellable tasks, each identified by a string ID and tracked with a unique token to handle race conditions safely. When effects are executed, the store:

1. Updates the state synchronously
2. Handles the returned effect asynchronously
3. Manages task lifecycle including cancellation and cleanup

### Effect<Action>

Represents different types of side effects that can be executed by the store.

#### Cases

##### `.none`
No side effect to execute.

```swift
return (newState, .none)
```

##### `.sequence([Effect<Action>])`
Executes multiple effects in sequence.

```swift
return (newState, .sequence([
    .task { await fetchUser() },
    .task { await updateUI() }
]))
```

##### `.task(() async throws -> Action)`
Executes a single async operation that returns an action.

```swift
return (newState, .task {
    let data = try await networkService.fetchData()
    return .dataReceived(data)
})
```

##### `.cancellable(() async throws -> Action, String)`
Executes a cancellable async operation with a unique identifier.

```swift
return (newState, .cancellable({
    let result = try await longRunningOperation()
    return .operationCompleted(result)
}, "long-operation"))
```

##### `.stream(AsyncStream<Action>, id: String)`
Handles continuous data streams with a unique identifier.

```swift
return (newState, .stream(
    AsyncStream { continuation in
        // Stream implementation
    },
    id: "data-stream"
))
```

#### Methods

##### `map<OtherAction>(_ transform: @escaping (Action) -> OtherAction) -> Effect<OtherAction>`

Transforms an effect from one action type to another, useful for composing different parts of your application.

```swift
let mappedEffect = originalEffect.map { originalAction in
    return .parentAction(originalAction)
}
```

## Usage Examples

### Basic State Management

```swift
struct AppState {
    var counter = 0
    var isLoading = false
}

enum AppAction: Sendable {
    case increment
    case decrement
    case startLoading
    case finishLoading
}

let store = Store(
    initialState: AppState(),
    reduce: { state, action in
        var newState = state
        
        switch action {
        case .increment:
            newState.counter += 1
            return (newState, .none)
            
        case .decrement:
            newState.counter -= 1
            return (newState, .none)
            
        case .startLoading:
            newState.isLoading = true
            return (newState, .task {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return .finishLoading
            })
            
        case .finishLoading:
            newState.isLoading = false
            return (newState, .none)
        }
    }
)
```

### SwiftUI Integration

```swift
@main
struct MyApp: App {
    let store = Store(initialState: AppState(), reduce: reducer)
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}

struct ContentView: View {
    @Environment(Store<AppState, AppAction>.self) private var store
    
    var body: some View {
        VStack {
            Text("Counter: \(store.state.counter)")
            
            Button("Increment") {
                store.send(.increment)
            }
            
            if store.state.isLoading {
                ProgressView()
            } else {
                Button("Start Loading") {
                    store.send(.startLoading)
                }
            }
        }
    }
}
```

### Cancellable Operations

```swift
enum NetworkAction: Sendable {
    case searchUsers(String)
    case cancelSearch
    case usersReceived([User])
}

func reduce(state: AppState, action: NetworkAction) -> (AppState, Effect<NetworkAction>) {
    switch action {
    case .searchUsers(let query):
        return (state, .cancellable({
            let users = try await userService.search(query)
            return .usersReceived(users)
        }, "user-search"))
        
    case .cancelSearch:
        // The store will automatically cancel the task with ID "user-search"
        return (state, .none)
        
    case .usersReceived(let users):
        var newState = state
        newState.users = users
        return (newState, .none)
    }
}

// To cancel the search
store.send(.cancelSearch)
// or directly
store.cancel("user-search")
```

### Streaming Data

```swift
enum StreamAction: Sendable {
    case startListening
    case stopListening
    case messageReceived(String)
}

func reduce(state: AppState, action: StreamAction) -> (AppState, Effect<StreamAction>) {
    switch action {
    case .startListening:
        let messageStream = AsyncStream<StreamAction> { continuation in
            let websocket = WebSocketConnection()
            
            websocket.onMessage = { message in
                continuation.yield(.messageReceived(message))
            }
            
            websocket.connect()
            
            continuation.onTermination = { _ in
                websocket.disconnect()
            }
        }
        
        return (state, .stream(messageStream, id: "websocket"))
        
    case .stopListening:
        // This will cancel the stream and clean up the websocket
        return (state, .none)
        
    case .messageReceived(let message):
        var newState = state
        newState.messages.append(message)
        return (newState, .none)
    }
}

// To stop listening
store.cancel("websocket")
```

## Best Practices

### 1. Keep Reducers Pure
Reducers should be pure functions with no side effects. All side effects should be represented as `Effect` values.

```swift
// ✅ Good - pure reducer
func reduce(state: State, action: Action) -> (State, Effect<Action>) {
    var newState = state
    newState.counter += 1
    return (newState, .task { await fetchData() })
}

// ❌ Bad - side effect in reducer
func reduce(state: State, action: Action) -> (State, Effect<Action>) {
    var newState = state
    newState.counter += 1
    Task { await fetchData() } // Side effect!
    return (newState, .none)
}
```

### 2. Use Meaningful Effect IDs
Choose descriptive IDs for cancellable effects and streams to make debugging easier.

```swift
// ✅ Good
.cancellable({ ... }, "user-profile-fetch")
.stream(locationStream, id: "gps-location-updates")

// ❌ Less clear
.cancellable({ ... }, "task1")
.stream(stream, id: "stream")
```

### 3. Handle Errors Gracefully
Always handle potential errors in your effects, especially for network operations.

```swift
.task {
    do {
        let data = try await networkCall()
        return .success(data)
    } catch {
        return .failure(error)
    }
}
```

### 4. Cancel Long-Running Operations
Remember to cancel operations when they're no longer needed to prevent memory leaks and unnecessary work.

```swift
// Cancel when view disappears
.onDisappear {
    store.cancel("background-sync")
}
```

## Thread Safety

The store is designed to be thread-safe:
- All state updates occur on the `MainActor`
- Effects can run on background threads but dispatch actions back to the main thread
- The cancellation mechanism uses tokens to prevent race conditions

## Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 5.9+
- Xcode 15.0+

The library uses modern Swift concurrency features including `async/await`, `AsyncStream`, and the `@Observable` macro for SwiftUI integration.

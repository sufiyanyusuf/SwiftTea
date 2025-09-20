# Getting Started with SwiftTea

Learn how to integrate SwiftTea into your Swift application for predictable state management.

## Overview

SwiftTea follows a unidirectional data flow pattern where actions trigger state updates through pure reducer functions, while side effects are handled separately through the Effect system.

## Creating Your First Store

### 1. Define Your State

Start by defining a struct that represents your application's state:

```swift
struct AppState {
var counter = 0
var isLoading = false
var users: [User] = []
}
```

### 2. Define Your Actions

Create an enum that represents all possible actions in your application:

```swift
enum AppAction: Sendable {
case increment
case decrement
case startLoading
case finishLoading
case loadUsers
case usersLoaded([User])
}
```

> Important: Actions must conform to `Sendable` to work with Swift concurrency.

### 3. Create a Reducer

Write a pure function that takes the current state and an action, returning a new state and any effects to execute:

```swift
func appReducer(state: AppState, action: AppAction) -> (AppState, Effect<AppAction>) {
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

case .loadUsers:
newState.isLoading = true
return (newState, .task {
let users = try await UserService.fetchUsers()
return .usersLoaded(users)
})

case .usersLoaded(let users):
newState.users = users
newState.isLoading = false
return (newState, .none)
}
}
```

### 4. Initialize the Store

Create your store with an initial state and the reducer:

```swift
let store = Store(
initialState: AppState(),
reduce: appReducer
)
```

## SwiftUI Integration

### 1. Provide the Store

Use SwiftUI's environment system to make the store available throughout your app:

```swift
@main
struct MyApp: App {
let store = Store(initialState: AppState(), reduce: appReducer)

var body: some Scene {
WindowGroup {
ContentView()
.environment(store)
}
}
}
```

### 2. Use the Store in Views

Access the store using the `@Environment` property wrapper:

```swift
struct ContentView: View {
@Environment(Store<AppState, AppAction>.self) private var store

var body: some View {
VStack(spacing: 20) {
Text("Counter: \(store.state.counter)")
.font(.headline)

HStack {
Button("Decrement") {
store.send(.decrement)
}

Button("Increment") {
store.send(.increment)
}
}

if store.state.isLoading {
ProgressView("Loading...")
} else {
Button("Start Loading") {
store.send(.startLoading)
}
}

Button("Load Users") {
store.send(.loadUsers)
}

List(store.state.users, id: \.id) { user in
Text(user.name)
}
}
.padding()
}
}
```

## Key Concepts

### Actions
Actions are plain values that describe what happened. They should be:
- Descriptive of the event, not the state change
- Serializable and equatable when possible
- Conform to `Sendable` for thread safety

### Reducers
Reducers are pure functions that:
- Take the current state and an action
- Return a new state and an effect
- Should have no side effects
- Should be predictable and testable

### Effects
Effects represent side effects that should happen as a result of an action:
- **`.none`**: No side effect
- **`.task`**: One-time async operation
- **`.cancellable`**: Cancellable async operation
- **`.stream`**: Continuous data stream
- **`.sequence`**: Multiple effects in order

## Next Steps

- Learn about <doc:Advanced> patterns
- Explore effect handling for complex async operations
- Implement cancellation for long-running tasks
- Handle streaming data with AsyncStreams

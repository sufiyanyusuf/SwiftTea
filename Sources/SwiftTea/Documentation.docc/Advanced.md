# Advanced SwiftTea Patterns

Master advanced techniques for building complex applications with SwiftTea.

## Overview

This guide covers advanced patterns including effect composition, cancellation strategies, streaming data, and architecture best practices for large applications.

## Effect Patterns

### Cancellable Operations

Use cancellable effects for operations that users might want to interrupt. You can cancel effects either imperatively using `store.cancel()` or declaratively from within the reducer using `.cancel()`:

```swift
enum SearchAction: Sendable {
case search(String)
case cancelSearch
case searchResults([SearchResult])
}

func searchReducer(state: SearchState, action: SearchAction) -> (SearchState, Effect<SearchAction>) {
switch action {
case .search(let query):
var newState = state
newState.isSearching = true

return (newState, .cancellable({
let results = try await SearchService.search(query)
return .searchResults(results)
}, "search"))

case .cancelSearch:
var newState = state
newState.isSearching = false
// Cancel the effect declaratively from the reducer
return (newState, .cancel("search"))

case .searchResults(let results):
var newState = state
newState.results = results
newState.isSearching = false
return (newState, .none)
}
}
```

### Automatic Cancellation with Replacement

When you start a new cancellable effect with the same ID, SwiftTea automatically cancels the previous one:

```swift
case .search(let newQuery):
var newState = state
newState.query = newQuery
newState.isSearching = true

// Starting a new search automatically cancels any existing "search" effect
return (newState, .cancellable({
let results = try await SearchService.search(newQuery)
return .searchResults(results)
}, "search"))
```

### Cancellation with Effect Sequences

Combine cancellation with other effects using `.sequence()`:

```swift
case .startNewSearch(let query):
var newState = state
newState.searchQuery = query
newState.isSearching = true

return (newState, .sequence([
.cancel("previous-search"),
.cancellable({
let results = try await SearchService.search(query)
return .searchResults(results)
}, "previous-search")
]))
```

### Streaming Data

Handle continuous data with AsyncStreams:

```swift
enum LocationAction: Sendable {
case startLocationUpdates
case stopLocationUpdates
case locationUpdate(CLLocation)
}

func locationReducer(state: LocationState, action: LocationAction) -> (LocationState, Effect<LocationAction>) {
switch action {
case .startLocationUpdates:
let locationStream = AsyncStream<LocationAction> { continuation in
let locationManager = CLLocationManager()
let delegate = LocationDelegate { location in
continuation.yield(.locationUpdate(location))
}

locationManager.delegate = delegate
locationManager.startUpdatingLocation()

continuation.onTermination = { _ in
locationManager.stopUpdatingLocation()
}
}

return (state, .stream(locationStream, id: "location-updates"))

case .stopLocationUpdates:
// Cancel the stream declaratively from the reducer
return (state, .cancel("location-updates"))

case .locationUpdate(let location):
var newState = state
newState.currentLocation = location
return (newState, .none)
}
}
```

### Effect Composition

Combine multiple effects using sequence:

```swift
case .initializeApp:
return (state, .sequence([
.task { .loadUserPreferences },
.task { .checkForUpdates },
.task { .initializeAnalytics }
]))
```

### Conditional Cancellation

Cancel effects based on state conditions:

```swift
case .userLoggedOut:
var newState = state
newState.isAuthenticated = false

// Cancel all user-related background operations
return (newState, .sequence([
.cancel("user-data-sync"),
.cancel("notification-stream"),
.cancel("analytics-upload")
]))
```

## Architecture Patterns

### Using Environments for Dependency Injection

SwiftTea's Store supports an environment parameter for dependency injection, making your reducers testable and flexible:

```swift
// Define your environment with all dependencies
struct AppEnvironment {
let apiService: APIServiceProtocol
let dataStore: DataStoreProtocol
let analytics: AnalyticsProtocol

// Live implementation for production
static let live = AppEnvironment(
apiService: LiveAPIService(),
dataStore: UserDefaultsDataStore(),
analytics: FirebaseAnalytics()
)

// Mock implementation for testing
static let mock = AppEnvironment(
apiService: MockAPIService(),
dataStore: InMemoryDataStore(),
analytics: MockAnalytics()
)
}

// Reducer with environment access
func appReducer(
state: AppState,
action: AppAction,
environment: AppEnvironment
) -> (AppState, Effect<AppAction>) {
switch action {
case .loadData:
return (state, .task {
let data = try await environment.apiService.fetch()
return .dataLoaded(data)
})
}
}

// Create store with environment
let store = Store(
initialState: AppState(),
reduce: appReducer,
environment: .live
)
```

For simple reducers without dependencies, use the convenience initializer that doesn't require an environment:

```swift
let simpleStore = Store(
initialState: CounterState(value: 0),
reduce: { state, action in
var newState = state
switch action {
case .increment:
newState.value += 1
return (newState, .none)
}
}
)
```

### Feature-Based Organization

Structure large apps by organizing state and reducers by feature:

```swift
// UserFeature.swift
struct UserState {
var currentUser: User?
var isLoggedIn = false
}

enum UserAction: Sendable {
case login(String, String)
case logout
case userLoaded(User)
}

func userReducer(state: UserState, action: UserAction) -> (UserState, Effect<UserAction>) {
// Handle user-related actions
}

// AppState combines all features
struct AppState {
var user = UserState()
var posts = PostState()
var settings = SettingsState()
}
```

### Action Composition

Map actions between different parts of your app:

```swift
enum AppAction: Sendable {
case user(UserAction)
case posts(PostAction)
case settings(SettingsAction)
}

func appReducer(state: AppState, action: AppAction) -> (AppState, Effect<AppAction>) {
switch action {
case .user(let userAction):
let (newUserState, userEffect) = userReducer(state: state.user, action: userAction)
var newState = state
newState.user = newUserState

return (newState, userEffect.map(AppAction.user))

case .posts(let postAction):
let (newPostState, postEffect) = postReducer(state: state.posts, action: postAction)
var newState = state
newState.posts = newPostState

return (newState, postEffect.map(AppAction.posts))

case .settings(let settingsAction):
let (newSettingsState, settingsEffect) = settingsReducer(state: state.settings, action: settingsAction)
var newState = state
newState.settings = newSettingsState

return (newState, settingsEffect.map(AppAction.settings))
}
}
```

## Error Handling Strategies

### Result-Based Actions

Handle errors explicitly through actions:

```swift
enum NetworkAction: Sendable {
case fetchData
case dataFetched(Result<Data, Error>)
}

func networkReducer(state: NetworkState, action: NetworkAction) -> (NetworkState, Effect<NetworkAction>) {
switch action {
case .fetchData:
var newState = state
newState.isLoading = true
newState.error = nil

return (newState, .task {
do {
let data = try await NetworkService.fetchData()
return .dataFetched(.success(data))
} catch {
return .dataFetched(.failure(error))
}
})

case .dataFetched(.success(let data)):
var newState = state
newState.data = data
newState.isLoading = false
return (newState, .none)

case .dataFetched(.failure(let error)):
var newState = state
newState.error = error
newState.isLoading = false
return (newState, .none)
}
}
```

### Retry Logic

Implement retry mechanisms for failed operations:

```swift
struct RetryableRequest<T> {
let operation: () async throws -> T
let maxRetries: Int
let delay: TimeInterval
}

extension Effect {
static func retryable<T>(
_ request: RetryableRequest<T>,
transform: @escaping (T) -> Action
) -> Effect<Action> {
.task {
var lastError: Error?

for attempt in 0...request.maxRetries {
do {
let result = try await request.operation()
return transform(result)
} catch {
lastError = error
if attempt < request.maxRetries {
try await Task.sleep(nanoseconds: UInt64(request.delay * 1_000_000_000))
}
}
}

throw lastError!
}
}
}
```

## Testing Strategies

### Testing Reducers

Reducers are pure functions, making them easy to test:

```swift
func testCounterIncrement() {
let initialState = AppState(counter: 0)
let (newState, effect) = appReducer(state: initialState, action: .increment)

XCTAssertEqual(newState.counter, 1)

switch effect {
case .none:
XCTAssert(true) // Expected no effect
default:
XCTFail("Expected no effect")
}
}
```

### Testing Cancellation

Test that cancellation effects are returned correctly:

```swift
func testSearchCancellation() {
let initialState = SearchState(isSearching: true)
let (newState, effect) = searchReducer(state: initialState, action: .cancelSearch)

XCTAssertFalse(newState.isSearching)

switch effect {
case .cancel(let id):
XCTAssertEqual(id, "search")
default:
XCTFail("Expected cancel effect")
}
}
```

### Testing Effects

Create test helpers for effect validation:

```swift
extension Effect {
var isNone: Bool {
switch self {
case .none: return true
default: return false
}
}

var isTask: Bool {
switch self {
case .task: return true
default: return false
}
}

var cancelID: String? {
switch self {
case .cancel(let id): return id
default: return nil
}
}
}
```

### Mock Dependencies

Use the Store's environment parameter to inject dependencies and make effects testable:

```swift
struct AppEnvironment {
let networkService: NetworkServiceProtocol
let locationService: LocationServiceProtocol

static let live = AppEnvironment(
networkService: LiveNetworkService(),
locationService: LiveLocationService()
)

static let test = AppEnvironment(
networkService: MockNetworkService(),
locationService: MockLocationService()
)
}

// In your reducer
func appReducer(
state: AppState, 
action: AppAction,
environment: AppEnvironment
) -> (AppState, Effect<AppAction>) {
switch action {
case .fetchData:
return (state, .task {
// Use environment.networkService instead of direct service calls
let data = try await environment.networkService.fetchData()
return .dataLoaded(data)
})
}
}

// Create store with live dependencies
let store = Store(
initialState: AppState(),
reduce: appReducer,
environment: .live
)

// In tests, create store with test dependencies
let testStore = Store(
initialState: AppState(),
reduce: appReducer,
environment: .test
)
```

## Performance Considerations

### State Normalization

Normalize complex state structures to avoid unnecessary view updates:

```swift
// Instead of nested arrays
struct AppState {
var posts: [Post] // Contains user data inline
}

// Use normalized structure
struct AppState {
var posts: [Post.ID: Post]
var users: [User.ID: User]
var postIDs: [Post.ID]
}
```

### Selective Subscriptions

Use computed properties to expose only necessary state to views:

```swift
extension AppState {
var visiblePosts: [Post] {
postIDs.compactMap { posts[$0] }
}
}
```

### Effect Debouncing

Implement debouncing for frequent operations:

```swift
actor Debouncer {
private var task: Task<Void, Never>?

func debounce(for duration: TimeInterval, operation: @escaping () async -> Void) {
task?.cancel()
task = Task {
try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
if !Task.isCancelled {
await operation()
}
}
}
}
```

## Best Practices Summary

1. **Keep reducers pure** - No side effects in reducer functions
2. **Use meaningful IDs** - Choose descriptive identifiers for cancellable effects
3. **Cancel declaratively** - Use `.cancel()` effects within reducers for better testability
4. **Handle errors explicitly** - Use Result types or error-specific actions
5. **Normalize state** - Avoid deeply nested state structures
6. **Test reducers thoroughly** - Take advantage of their pure nature
7. **Inject dependencies** - Make effects testable through dependency injection
8. **Clean up on exit** - Cancel long-running operations when features are dismissed or users log out

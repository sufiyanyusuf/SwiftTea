# ``SwiftTea``

An Elm-inspired state management library for Swift with powerful effect handling.

## Overview

SwiftTea provides a predictable state management solution for Swift applications, featuring:

- **Unidirectional Data Flow**: Actions trigger state updates through pure reducer functions
- **Effect System**: Handle side effects including async operations, cancellable tasks, and data streams
- **SwiftUI Integration**: Built-in `@Observable` support for reactive UI updates
- **Thread Safety**: All state updates happen on the main thread with proper concurrency handling

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Advanced>

### Core Types

- ``Store``
- ``Effect``

### State Management

- ``Store/init(initialState:reduce:)``
- ``Store/send(_:)``
- ``Store/state``

### Effect Handling

- ``Store/cancel(_:)``
- ``Effect/none``
- ``Effect/task(_:)``
- ``Effect/cancellable(_:_:)``
- ``Effect/stream(_:id:)``
- ``Effect/cancel(_:)``
- ``Effect/sequence(_:)``

### Effect Transformation

- ``Effect/map(_:)``

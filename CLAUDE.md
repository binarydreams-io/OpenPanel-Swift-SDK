# OpenPanel Swift SDK

Zero-dependency Swift SDK for OpenPanel analytics. Talks to `POST /track` on
`api.openpanel.dev`.

## Commands

```bash
swift build
swift test                      # Swift Testing (not XCTest); requires Swift 6 / Xcode 16
swift package clean
```

No `.xcodeproj` — SwiftPM only. CI builds on iOS / macOS / tvOS.

## Public API shape

`OpenPanel` is a shared singleton accessed via `public static var shared`.
The actor instance is held in a lock-protected slot (`OpenPanel._shared`,
an `OSAllocatedUnfairLock<OpenPanel?>`) so `initialize` can swap it in
synchronously. Callers interact through the static facade:

```swift
OpenPanel.initialize(…)          // truly synchronous — when it returns, the SDK is ready
OpenPanel.track("e", …)         // all other methods — fire-and-forget
```

`initialize(_:disabled:)` constructs a fresh `OpenPanel` actor on the
calling thread and stores it under the lock — no `Task`, no `await`.
Calling it a second time replaces the singleton with a brand-new actor;
the previous instance (and any in-flight tasks holding a reference to it)
is discarded. Every other static method is fire-and-forget: it spawns a
`Task` that hops onto the actor; network I/O, retries, and error handling
happen in the background. Errors are logged when `debug: true`. The two
public **read-only properties** `OpenPanel.deviceId` / `OpenPanel.sessionId`
are `async` (they read state from the actor).

Calling any property or method on `OpenPanel.shared` before `initialize`
is a **fatal error** (`fatalError`) — the trap lives in the `shared`
getter, so misuse surfaces synchronously at the call site.

Instance methods on the actor are `async` (actor isolation) — the static
facade wraps them in `Task`. When adding a new public method, add both the
instance method and the static wrapper. `config` and `transport` are `let`
on each actor instance — to change them at runtime, call `initialize`
again.

## Architecture

- `Sources/OpenPanel.swift` — public `actor OpenPanel`, the entry point. Holds the lock-protected `_shared` slot, the synchronous `shared` getter (traps if uninitialized), and per-instance state.
- `Sources/OpenPanel+Config.swift`, `OpenPanel+Error.swift` — public nested types
- `Sources/OpenPanel+API.swift` — public instance methods + the static facade (synchronous `initialize`, fire-and-forget for everything else)
- `Sources/OpenPanel+Helpers.swift` — internal `send`/`drainQueue`/`log` plus the test-only static `initialize(_:session:)` and `resetForTesting()` helpers
- `Sources/OpenPanel+Transport.swift` — internal `Transport` struct (HTTP, retries, 401 silent-drop)
- `Sources/Models/` — payload types. **Public:** `OpenPanelEvent` (discriminated envelope), `TrackPayload`, `IdentifyPayload`, `GroupPayload`, `AssignGroupPayload`, `IncrementPayload`, `DecrementPayload`, `AliasPayload`, `ProfileId`. **Internal:** `TrackResponse` (server response shape, not part of the public surface).
- `Sources/OpenPanel+DeviceInfo.swift` — internal `enum DeviceInfo` + `WiFiMonitor`; resolves device metadata stamped onto `track` events.

When adding a type, decide public vs. internal first. Public payloads go in `Sources/Models/`; internal helpers/transport types go next to their callsite (`Sources/OpenPanel+*.swift`). `TrackResponse` lives in `Models/` for historical reasons but is `internal` — keep new internal-only types alongside their consumer instead.

## Conventions

- Public nested types live in `OpenPanel+<Name>.swift` extensions, not inside `OpenPanel.swift`.
- Properties are plain `[String: String]` — no type-erasure wrappers.
- `swiftformat` is authoritative: 2-space indent, `--wraparguments before-first`, `--self init-only`. Run before committing.

## Gotchas

- **Tests share `MockURLProtocol.registry`.** Suites that use `MockURLProtocol` must be nested inside `MockBackedSuite` (which is `@Suite(.serialized)`). Pure-logic suites (e.g. `EncodingTests`) may live at the top level. A top-level `@Suite` that touches the registry will run in parallel and clobber it.
- **401 is a silent drop, no retry.** This is intentional — do not "fix" it by throwing.
- **`"Duplicate event"` plain-text body on 200 = success with no body.** Transport sniffs the prefix; don't tighten the decoder.
- **`identify` with only a `profileId` does not hit the network** — it just sets local state and attempts to drain the queue (no-op while `disabled` is `true`). Extras (`email`, `firstName`, `properties`, …) are required to trigger a request.
- **`revenue` is a `track` event** named `"revenue"` with reserved `__revenue` / `__deviceId` properties, not a separate endpoint.
- **Reserved keys (prefix `__`) supplied by callers are stripped** in `track`, `revenue`, `identify`, and `setGlobalProperties` (via `stripReserved` in `OpenPanel+Helpers.swift`). The SDK then writes its own: device metadata on every track event, `__timestamp` on queued tracks, `__revenue`/`__deviceId` for revenue. User input cannot override these.
- **Every `track` event is stamped with device metadata** via `stampDeviceMetadata(into:)` in `OpenPanel+Helpers.swift`. Keys: `__brand` (constant `"Apple"`), `__os` (e.g. `"iOS"`, `"macOS"`, `"tvOS"`), `__osVersion`, `__device` (`"mobile"` / `"tablet"` / `"desktop"` / `"tv"` / `"wearable"` / `"headset"` / `"automotive"`), `__model`, `__version` (`CFBundleShortVersionString`), `__buildNumber` (`CFBundleVersion`), `__screenWidth`/`__screenHeight`/`__screenDpi`, `__wifi`. Sources: `UIDevice`/`WKInterfaceDevice`/`ProcessInfo` (OS version + idiom), `sysctlbyname("hw.machine"|"hw.model")` (model), `UIScreen`/`NSScreen`/`WKInterfaceDevice` (screen), `NWPathMonitor` (wifi snapshot). `__os`/`__device` exist because the OpenPanel server derives those from `User-Agent`, and `URLSession`'s default UA carries no Apple platform marker — without our overrides events fall back to `desktop`. Track-only — `identify`/`group`/`alias`/etc. don't get device metadata.
- **Intentionally NOT ported from the Kotlin SDK:** `__carrier` (deprecated `CTCarrier` returns dummy values on iOS 16+), `__hasNfc`/`__hasTelephone` (not directly available on iOS), `__bluetoothEnabled`/`__bluetoothVersion` (would force `NSBluetoothAlwaysUsageDescription` and trigger a permission prompt on every host app).
- **Queued `track` events are stamped with `__timestamp`** so the server sees the original time, not the flush time. Other event types are not stamped. Preserve this when touching `send`/`flush`.
- **Queue is in-memory only** — lost on app restart. Don't add persistence without discussion.
- **`URLSession` is NOT part of `Config`.** Production code always uses `.shared`. Tests inject mock sessions via the internal `initialize(_:session:)` overload.
- **`waitForProfile` is independent of `disabled`** — both flags queue events, but they have separate auto-clear semantics. `disabled` clears via `ready()`, `waitingForProfile` clears via `identify(_:)`. Both must be `false` for events to leave the process. `clear()` re-arms `waitingForProfile` when `config.waitForProfile == true`, so a logout returns the SDK to its pre-login queueing state.
- **`alias` is not a `track` event** — it's a separate envelope variant (`type: "alias"`) carrying `profileId` (canonical) and `alias` (the id being merged in). Use it for anon → logged-in profile merging.
- **`setGroup`/`setGroups` require a `profileId`** — they accumulate groups locally but only send `assign_group` to the server when a profileId is set (via `identify`). Without one, the call logs a warning and skips the network request.
- **`clear()` does NOT reset global properties** — it only clears identity state (profileId, groups, deviceId, sessionId). Use `initialize` for a full reset.
- **`CancellationError` propagates immediately** in the transport retry loop — it is not retried.
- **Public API is fire-and-forget.** Static methods are synchronous, non-throwing. Errors are logged internally. Do not add `throws` to static facade methods.

## Testing

- Framework: Swift Testing (`import Testing`, `@Test`, `#expect`).
- Network is stubbed via `MockURLProtocol` + `URLSessionConfiguration.ephemeral` — tests never hit the real network.
- New suite → `extension MockBackedSuite { @Suite("Name") struct MyTests { … } }`.
- `MockURLProtocol.install { req in .success(.ok()) }` at the top of each test; `.reset()` is not needed because `install` resets captured state.
- Tests call instance methods (`await OpenPanel.shared.track(…)`) directly, NOT the static facade — static methods are fire-and-forget and return before the work completes.
- Singleton state persists across tests. Each test must call `OpenPanel.initialize(…, session:)` (internal static overload, injects mock session and replaces the singleton) before exercising the API. Both that overload and `OpenPanel.resetForTesting()` are `internal` and reachable only via `@testable import OpenPanel`. `resetForTesting()` clears the `_shared` slot — call it to assert pre-init (uninitialized) behaviour.

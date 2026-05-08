//
//  OpenPanel.swift
//  OpenPanel
//
//  Created by Leonid Frolov on 30.04.2026.
//

import Foundation
import os

/// OpenPanel analytics client.
///
/// Usage is via the shared singleton: call `OpenPanel.initialize(_:)` once at
/// app start, then use the static fire-and-forget API (`OpenPanel.track`,
/// `OpenPanel.identify`, …). `initialize` is fully synchronous — when it
/// returns, the SDK is configured and ready. All other static methods are
/// fire-and-forget: they spawn an internal `Task` that hops onto the actor.
/// Errors are logged internally when `debug: true`.
///
/// Behaviour:
/// - Events are sent immediately via `POST /track`.
/// - When `disabled` is `true`, events are queued in memory until ``ready()`` is called.
/// - The server returns `deviceId` and `sessionId`, which the client caches and reuses.
/// - Global properties are merged into every `track` event.
/// - A `filter` closure can drop events before they leave the process.
///
/// Queue is in-memory only: it does NOT persist across app restarts.
public actor OpenPanel {
  // MARK: - Singleton

  /// Backing storage for ``shared``. Lock-guarded so ``initialize(_:disabled:)``
  /// can swap the instance in synchronously from any thread.
  static let _shared = OSAllocatedUnfairLock<OpenPanel?>(initialState: nil)

  /// The shared SDK instance. Calling any property or method on `shared`
  /// before ``initialize(_:disabled:)`` is an intentional **fatal error**:
  /// analytics from the very first launch (`app_launch`, etc.) are critical,
  /// and a silent no-op would let the bug ship to production.
  public static var shared: OpenPanel {
    guard let instance = _shared.withLock(\.self) else {
      fatalError("[OpenPanel] SDK not initialized. Call OpenPanel.initialize(_:) first.")
    }
    return instance
  }

  // MARK: - State

  static let apiLog = Logger(subsystem: "dev.openpanel", category: "API")
  static let queueLog = Logger(subsystem: "dev.openpanel", category: "Queue")
  static let transportLog = Logger(subsystem: "dev.openpanel", category: "Transport")

  let config: Config
  let transport: Transport

  var profileId: ProfileId?
  var groups: Set<String> = []
  var global: [String: String] = [:]
  var queue: [OpenPanelEvent] = []
  /// When `true`, events are queued in memory until ``ready()`` is called.
  var disabled: Bool
  /// Set from `Config.waitForProfile`. While `true`, events queue locally
  /// until ``identify(_:)`` supplies a profileId. Independent of ``disabled``;
  /// both must be `false` for events to leave the process.
  var waitingForProfile: Bool
  /// `true` while ``drainQueue()`` is in flight. Concurrent ``send(_:)``
  /// calls route through the queue while this is set, so live events can't
  /// jump ahead of queued ones on the wire.
  var draining: Bool = false

  /// Server-issued device identifier. `nil` until the first successful response.
  public internal(set) var deviceId: String?
  /// Server-issued session identifier. `nil` until the first successful response;
  /// may be rotated by the server when the session expires.
  public internal(set) var sessionId: String?

  init(config: Config, transport: Transport, disabled: Bool = false) {
    self.config = config
    self.transport = transport
    self.disabled = disabled
    self.waitingForProfile = config.waitForProfile
  }
}

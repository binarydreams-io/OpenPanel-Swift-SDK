//
//  OpenPanel+Helpers.swift
//  OpenPanel
//
//  Created by Leonid Frolov on 30.04.2026.
//

import Foundation
import os

extension OpenPanel {
  /// Test-only static initializer that injects a custom `URLSession`
  /// (used with `MockURLProtocol`). Replaces the singleton synchronously.
  static func initialize(_ config: Config, session: URLSession, disabled: Bool = false) {
    let instance = OpenPanel(
      config: config,
      transport: Transport(config: config, session: session),
      disabled: disabled
    )
    _shared.withLock { $0 = instance }
  }

  /// Fully un-configures the singleton. Only for tests — `@testable import OpenPanel`
  /// is required to reach it. Not part of the public API.
  static func resetForTesting() {
    _shared.withLock { $0 = nil }
  }

  /// Builds a `TrackPayload` from caller-supplied data plus SDK-managed
  /// reserved keys (device metadata + any extra reserved keys passed by
  /// internal callers like `revenue`). Last-write wins on key collision:
  /// global → user → device metadata → caller-supplied reserved.
  func buildTrackPayload(
    name: String,
    userProperties: [String: String]?,
    reserved: [String: String],
    profileId: ProfileId?,
    extraGroups: [String]?
  ) -> TrackPayload {
    // `global` is already stripped at write-time by `setGlobalProperties`.
    var mergedProperties = global
    if let userProperties {
      mergedProperties.merge(stripReserved(userProperties)) { _, new in new }
    }
    mergedProperties.merge(DeviceInfo.metadata) { _, new in new }
    mergedProperties.merge(reserved) { _, new in new }
    return TrackPayload(
      name: name,
      properties: mergedProperties,
      profileId: profileId,
      groups: effectiveGroups(extra: extraGroups)
    )
  }

  /// Union of actor-stored groups with caller-supplied extras. Returns `nil`
  /// when empty so encoding omits the field rather than emitting `[]`.
  func effectiveGroups(extra: [String]?) -> [String]? {
    let combinedGroups = groups.union(extra ?? [])
    return combinedGroups.isEmpty ? nil : Array(combinedGroups)
  }

  /// Drops reserved keys (prefix `__`) from caller-supplied properties.
  /// Reserved keys are SDK-managed (`__brand`, `__os`, `__osVersion`,
  /// `__device`, `__model`, `__timestamp`, `__revenue`, `__deviceId`) —
  /// accepting them from the caller would let user input clobber server-side
  /// semantics.
  func stripReserved(_ properties: [String: String]) -> [String: String] {
    var filteredProperties: [String: String] = [:]
    filteredProperties.reserveCapacity(properties.count)
    for (key, value) in properties {
      if key.hasPrefix("__") {
        log("Ignored reserved property '\(key)' — keys starting with '__' are SDK-managed")
        continue
      }
      filteredProperties[key] = value
    }
    return filteredProperties
  }

  func log(_ message: @autoclosure () -> String, to logger: Logger = OpenPanel.apiLog) {
    guard config.debug else { return }
    let formattedMessage = message()
    logger.debug("\(formattedMessage)")
  }

  @discardableResult
  func send(_ envelope: OpenPanelEvent) async -> Bool {
    if let filter = config.filter, !filter(envelope) {
      log("Filtered event: \(envelope)")
      return true
    }

    // `draining` keeps live events behind the in-flight drain so the server
    // sees them in submission order.
    if disabled || waitingForProfile || draining {
      queue.append(stampTimestamp(envelope))
      if queue.count > config.maxQueueSize {
        let droppedEvent = queue.removeFirst()
        log("Queue full (max=\(config.maxQueueSize)) — dropped oldest: \(droppedEvent)", to: OpenPanel.queueLog)
      }
      log("Queued event: \(envelope)", to: OpenPanel.queueLog)
      return true
    }

    return await sendDirect(envelope)
  }

  /// Bypasses the queue/filter gate and goes straight to the transport.
  /// Only ``drainQueue()`` should call this — every other write path must
  /// go through ``send(_:)`` so the queue/filter checks apply.
  @discardableResult
  func sendDirect(_ envelope: OpenPanelEvent) async -> Bool {
    log("Sending event: \(envelope)", to: OpenPanel.transportLog)
    do {
      let response: TrackResponse? = try await transport.post(path: "/track", body: envelope)
      if let response {
        deviceId = response.deviceId
        sessionId = response.sessionId
      }
      return true
    } catch is CancellationError {
      return false
    } catch {
      log("Send failed: \(error)", to: OpenPanel.transportLog)
      return false
    }
  }

  /// Stamps queued `track` events with `__timestamp` so the server records
  /// the original event time rather than the flush time.
  private func stampTimestamp(_ envelope: OpenPanelEvent) -> OpenPanelEvent {
    guard case var .track(payload) = envelope else { return envelope }
    var properties = payload.properties ?? [:]
    if properties["__timestamp"] == nil {
      properties["__timestamp"] = Date.now.ISO8601Format(.iso8601WithTimeZone(includingFractionalSeconds: true))
    }
    payload.properties = properties
    return .track(payload)
  }

  /// Backfills `profileId` on `track` events that were queued before `identify`.
  /// Other event types either carry an explicit profileId or don't need one.
  private func enriched(_ envelope: OpenPanelEvent) -> OpenPanelEvent {
    guard case var .track(payload) = envelope, payload.profileId == nil, let profileId else {
      return envelope
    }
    payload.profileId = profileId
    return .track(payload)
  }

  /// Drains the queue head-first, one event per iteration. The `draining`
  /// flag forces concurrent ``send(_:)`` calls to enqueue rather than race
  /// past us, so wire order matches submission order. Re-entrant calls are
  /// no-ops.
  func drainQueue() async {
    guard !disabled, !waitingForProfile, !draining else { return }
    draining = true
    defer { draining = false }

    while let envelope = queue.first {
      queue.removeFirst()
      if await !sendDirect(enriched(envelope)) {
        // Network failure — put it back at the head and stop. Anything
        // appended via `send()` while we were suspended is already behind
        // it, so order is preserved.
        queue.insert(envelope, at: 0)
        return
      }
    }
  }
}

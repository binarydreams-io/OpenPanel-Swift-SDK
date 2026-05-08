//
//  OpenPanel+API.swift
//  OpenPanel
//
//  Created by Leonid Frolov on 30.04.2026.
//

import Foundation

// MARK: - Public instance API

public extension OpenPanel {
  /// Unblock queued events. Pair with `initialize(_:, disabled: true)` for deferred startup.
  func ready() async {
    disabled = false
    await drainQueue()
  }

  /// Reset cached identity (profile, groups, device, session).
  func clear() {
    profileId = nil
    groups.removeAll()
    deviceId = nil
    sessionId = nil
    if config.waitForProfile {
      waitingForProfile = true
    }
  }

  func setGlobalProperties(_ properties: [String: String]) {
    global.merge(stripReserved(properties)) { _, new in new }
  }

  func track(
    _ name: String,
    properties: [String: String]? = nil,
    profileId: ProfileId? = nil,
    groups: [String]? = nil
  ) async {
    let payload = buildTrackPayload(
      name: name,
      userProperties: properties,
      reserved: [:],
      profileId: profileId ?? self.profileId,
      extraGroups: groups
    )
    await send(.track(payload))
  }

  /// Merge `alias` (often the anonymous profile id assigned before login) into
  /// `profileId` (the canonical, post-login id) server-side.
  func alias(profileId: String, alias: String) async {
    await send(.alias(AliasPayload(profileId: profileId, alias: alias)))
  }

  func identify(_ payload: IdentifyPayload) async {
    profileId = payload.profileId
    waitingForProfile = false

    // Attempt to flush queued events. No-op while `disabled` is still `true`.
    await drainQueue()

    // Only hit the API if caller supplied more than just the ID.
    let hasExtras = payload.firstName != nil || payload.lastName != nil
      || payload.email != nil || payload.avatar != nil
      || (payload.properties?.isEmpty == false)

    guard hasExtras else { return }

    var enrichedPayload = payload
    if let userProperties = payload.properties {
      var mergedProperties = global
      mergedProperties.merge(stripReserved(userProperties)) { _, new in new }
      enrichedPayload.properties = mergedProperties
    } else if !global.isEmpty {
      enrichedPayload.properties = global
    }

    await send(.identify(enrichedPayload))
  }

  func upsertGroup(_ payload: GroupPayload) async {
    await send(.group(payload))
  }

  func setGroup(_ groupId: String) async {
    guard !groups.contains(groupId) else { return }
    groups.insert(groupId)
    guard let profileId else {
      log("Ignored setGroup('\(groupId)') — no profileId set")
      return
    }
    await send(.assignGroup(AssignGroupPayload(groupIds: [groupId], profileId: profileId)))
  }

  func setGroups(_ groupIds: [String]) async {
    let newGroups = groupIds.filter { !groups.contains($0) }
    guard !newGroups.isEmpty else { return }
    groups.formUnion(newGroups)
    guard let profileId else {
      log("Ignored setGroups(\(newGroups)) — no profileId set")
      return
    }
    await send(.assignGroup(AssignGroupPayload(groupIds: newGroups, profileId: profileId)))
  }

  func increment(property: String, value: Double? = nil, profileId: ProfileId? = nil) async {
    guard let resolvedProfileId = profileId ?? self.profileId else {
      log("Ignored increment('\(property)') — no profileId set")
      return
    }
    await send(.increment(IncrementPayload(profileId: resolvedProfileId, property: property, value: value)))
  }

  func decrement(property: String, value: Double? = nil, profileId: ProfileId? = nil) async {
    guard let resolvedProfileId = profileId ?? self.profileId else {
      log("Ignored decrement('\(property)') — no profileId set")
      return
    }
    await send(.decrement(DecrementPayload(profileId: resolvedProfileId, property: property, value: value)))
  }

  /// Revenue is a regular `track` event named `"revenue"` with a reserved `__revenue` property.
  /// The server requires a client secret for revenue unless the project allows unsafe revenue.
  func revenue(_ amount: Double, properties: [String: String]? = nil, deviceId: String? = nil) async {
    var reservedProperties = ["__revenue": String(amount)]
    if let deviceId { reservedProperties["__deviceId"] = deviceId }
    let payload = buildTrackPayload(
      name: "revenue",
      userProperties: properties,
      reserved: reservedProperties,
      profileId: profileId,
      extraGroups: nil
    )
    await send(.track(payload))
  }

  func flush() async {
    await drainQueue()
  }
}

// MARK: - Static facade

/// Synchronous, non-throwing entry points for callers that don't want to
/// `await`. ``initialize(_:disabled:)`` does its work synchronously: when it
/// returns, the SDK is ready. Every other static method is fire-and-forget —
/// it spawns an unstructured `Task` that hops onto the actor and returns
/// immediately. Errors are caught and logged inside the actor.
///
/// Ordering caveat: the Swift runtime does not guarantee that two
/// back-to-back `Task {}` invocations will reach the actor in submission
/// order, so `OpenPanel.track("a"); OpenPanel.track("b")` may arrive at
/// the server in either order. Tests and code paths that need a specific
/// ordering must use the instance API (`await OpenPanel.shared.track(…)`)
/// instead.
public extension OpenPanel {
  /// Configure the singleton synchronously. Must be called before any other
  /// public API. Calling a second time replaces the singleton with a fresh
  /// actor — all cached state (profile, groups, queue, device/session ids)
  /// is reset. Pass `disabled: true` to queue events until ``ready()`` is
  /// called.
  static func initialize(_ config: Config, disabled: Bool = false) {
    let instance = OpenPanel(config: config, transport: Transport(config: config), disabled: disabled)
    _shared.withLock { $0 = instance }
  }

  /// Unblock queued events. See instance ``ready()``.
  static func ready() {
    let instance = shared
    Task(name: "OpenPanel.ready") { await instance.ready() }
  }

  /// Reset cached identity (profile, groups, device, session).
  /// Does NOT clear global properties. See instance ``clear()``.
  static func clear() {
    let instance = shared
    Task(name: "OpenPanel.clear") { await instance.clear() }
  }

  /// Merge into the global property map. Reserved (`__`-prefixed) keys
  /// are stripped. See instance ``setGlobalProperties(_:)``.
  static func setGlobalProperties(_ properties: [String: String]) {
    let instance = shared
    Task(name: "OpenPanel.setGlobalProperties") { await instance.setGlobalProperties(properties) }
  }

  /// Send a track event. Stamped with device metadata, merged with global
  /// properties, then sent or queued. See instance ``track(_:properties:profileId:groups:)``.
  static func track(
    _ name: String,
    properties: [String: String]? = nil,
    profileId: ProfileId? = nil,
    groups: [String]? = nil
  ) {
    let instance = shared
    Task(name: "OpenPanel.track") {
      await instance.track(name, properties: properties, profileId: profileId, groups: groups)
    }
  }

  /// Set the active profile and optionally update profile attributes.
  /// See instance ``identify(_:)``.
  static func identify(_ payload: IdentifyPayload) {
    let instance = shared
    Task(name: "OpenPanel.identify") { await instance.identify(payload) }
  }

  /// Create or update a group record. See instance ``upsertGroup(_:)``.
  static func upsertGroup(_ payload: GroupPayload) {
    let instance = shared
    Task(name: "OpenPanel.upsertGroup") { await instance.upsertGroup(payload) }
  }

  /// Attach the current profile to a group. Requires a `profileId` to have
  /// been set via ``identify(_:)``; otherwise it logs and skips the network
  /// request. See instance ``setGroup(_:)``.
  static func setGroup(_ groupId: String) {
    let instance = shared
    Task(name: "OpenPanel.setGroup") { await instance.setGroup(groupId) }
  }

  /// Attach the current profile to multiple groups at once.
  /// See instance ``setGroups(_:)``.
  static func setGroups(_ groupIds: [String]) {
    let instance = shared
    Task(name: "OpenPanel.setGroups") { await instance.setGroups(groupIds) }
  }

  /// Increment a numeric profile property. Requires a `profileId`.
  /// See instance ``increment(property:value:profileId:)``.
  static func increment(property: String, value: Double? = nil, profileId: ProfileId? = nil) {
    let instance = shared
    Task(name: "OpenPanel.increment") {
      await instance.increment(property: property, value: value, profileId: profileId)
    }
  }

  /// Decrement a numeric profile property. Requires a `profileId`.
  /// See instance ``decrement(property:value:profileId:)``.
  static func decrement(property: String, value: Double? = nil, profileId: ProfileId? = nil) {
    let instance = shared
    Task(name: "OpenPanel.decrement") {
      await instance.decrement(property: property, value: value, profileId: profileId)
    }
  }

  /// Send a `revenue` track event. Reserved keys `__revenue` and
  /// `__deviceId` are added by the SDK.
  /// See instance ``revenue(_:properties:deviceId:)``.
  static func revenue(_ amount: Double, properties: [String: String]? = nil, deviceId: String? = nil) {
    let instance = shared
    Task(name: "OpenPanel.revenue") { await instance.revenue(amount, properties: properties, deviceId: deviceId) }
  }

  /// Merge `alias` into `profileId` server-side. See instance
  /// ``alias(profileId:alias:)``.
  static func alias(profileId: String, alias: String) {
    let instance = shared
    Task(name: "OpenPanel.alias") { await instance.alias(profileId: profileId, alias: alias) }
  }

  /// Drain the in-memory queue. No-op while `disabled` or
  /// `waitingForProfile` is set. See instance ``flush()``.
  static func flush() {
    let instance = shared
    Task(name: "OpenPanel.flush") { await instance.flush() }
  }

  /// Server-issued device identifier, or `nil` until the first successful
  /// response. `async` because reads must hop onto the actor.
  static var deviceId: String? {
    get async { await shared.deviceId }
  }

  /// Server-issued session identifier, or `nil` until the first successful
  /// response. `async` because reads must hop onto the actor.
  static var sessionId: String? {
    get async { await shared.sessionId }
  }
}

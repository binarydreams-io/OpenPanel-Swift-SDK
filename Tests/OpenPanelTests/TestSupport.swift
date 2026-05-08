//
//  TestSupport.swift
//  OpenPanel
//
//  Created by Leonid Frolov on 30.04.2026.
//

import Foundation
@testable import OpenPanel
import Testing

// MARK: - Configured-OpenPanel scope trait

/// Test scope that resets the `OpenPanel.shared` singleton with a mock-backed session
/// before each test/case and installs a default `200 OK` response. Removes the
/// `await configure()` boilerplate that every legacy test used to repeat.
struct ConfiguredOpenPanel: TestTrait, TestScoping {
  let disabled: Bool
  let waitForProfile: Bool
  let clientSecret: String
  let filter: (@Sendable (OpenPanelEvent) -> Bool)?
  let response: MockURLProtocol.Response?

  func provideScope(
    for _: Test,
    testCase _: Test.Case?,
    performing function: () async throws -> Void
  ) async throws {
    if let response {
      await MockURLProtocol.install { _ in .success(response) }
    }
    let config = OpenPanel.Config(
      clientId: "00000000-0000-0000-0000-000000000000",
      clientSecret: clientSecret,
      apiURL: URL(string: "https://api.example.test")!,
      initialRetryDelay: .milliseconds(1),
      waitForProfile: waitForProfile,
      filter: filter
    )
    OpenPanel.initialize(config, session: MockURLProtocol.makeSession(), disabled: disabled)
    try await function()
  }
}

extension Trait where Self == ConfiguredOpenPanel {
  /// Reset SDK with default `200 OK` mock response.
  static var configured: Self {
    ConfiguredOpenPanel(disabled: false, waitForProfile: false, clientSecret: "test-secret", filter: nil, response: .ok())
  }

  static func configured(
    disabled: Bool = false,
    waitForProfile: Bool = false,
    clientSecret: String = "test-secret",
    filter: (@Sendable (OpenPanelEvent) -> Bool)? = nil,
    response: MockURLProtocol.Response? = .ok()
  ) -> Self {
    ConfiguredOpenPanel(
      disabled: disabled,
      waitForProfile: waitForProfile,
      clientSecret: clientSecret,
      filter: filter,
      response: response
    )
  }
}

// MARK: - Envelope decoding helpers

extension MockURLProtocol.Registry {
  /// Decode all captured request bodies into `OpenPanelEvent` envelopes.
  func envelopes() throws -> [OpenPanelEvent] {
    let capturedBodies = bodies
    let decoder = JSONDecoder()
    return try capturedBodies.map { rawBody in
      do {
        return try decoder.decode(OpenPanelEvent.self, from: rawBody)
      } catch {
        Attachment.record(rawBody, named: "raw-body")
        throw error
      }
    }
  }

  func firstEnvelope(sourceLocation: SourceLocation = #_sourceLocation) throws -> OpenPanelEvent {
    let capturedBodies = bodies
    let rawBody = try #require(capturedBodies.first, sourceLocation: sourceLocation)
    return try JSONDecoder().decode(OpenPanelEvent.self, from: rawBody)
  }

  func lastEnvelope(sourceLocation: SourceLocation = #_sourceLocation) throws -> OpenPanelEvent {
    let capturedBodies = bodies
    let rawBody = try #require(capturedBodies.last, sourceLocation: sourceLocation)
    return try JSONDecoder().decode(OpenPanelEvent.self, from: rawBody)
  }
}

// MARK: - OpenPanelEvent payload extractors (test-only convenience)

extension OpenPanelEvent {
  var trackPayload: TrackPayload? {
    if case let .track(payload) = self { payload } else { nil }
  }

  var identifyPayload: IdentifyPayload? {
    if case let .identify(payload) = self { payload } else { nil }
  }

  var groupPayload: GroupPayload? {
    if case let .group(payload) = self { payload } else { nil }
  }

  var assignGroupPayload: AssignGroupPayload? {
    if case let .assignGroup(payload) = self { payload } else { nil }
  }

  var incrementPayload: IncrementPayload? {
    if case let .increment(payload) = self { payload } else { nil }
  }

  var decrementPayload: DecrementPayload? {
    if case let .decrement(payload) = self { payload } else { nil }
  }

  var aliasPayload: AliasPayload? {
    if case let .alias(payload) = self { payload } else { nil }
  }
}

// MARK: - CustomTestStringConvertible (test target only)

extension OpenPanelEvent: CustomTestStringConvertible {
  public var testDescription: String {
    switch self {
    case let .track(payload): "track(\"\(payload.name)\")"
    case let .identify(payload): "identify(\(payload.profileId.testDescription))"
    case let .group(payload): "group(\"\(payload.id)\", type: \(payload.type))"
    case let .assignGroup(payload): "assignGroup(\(payload.groupIds))"
    case let .increment(payload): "increment(\(payload.property))"
    case let .decrement(payload): "decrement(\(payload.property))"
    case let .alias(payload): "alias(\"\(payload.profileId)\" <- \"\(payload.alias)\")"
    }
  }
}

extension ProfileId: CustomTestStringConvertible {
  public var testDescription: String {
    switch self {
    case let .string(stringValue): "\"\(stringValue)\""
    case let .int(intValue): "\(intValue)"
    case let .double(doubleValue): "\(doubleValue)"
    }
  }
}

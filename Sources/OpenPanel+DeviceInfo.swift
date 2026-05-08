//
//  OpenPanel+DeviceInfo.swift
//  OpenPanel
//
//  Created by Leonid Frolov on 30.04.2026.
//

import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(WatchKit)
import WatchKit
#endif
#if canImport(Network)
import Network
#endif

extension OpenPanel {
  /// Reserved-key device metadata stamped onto every `track` event:
  /// `__brand`, `__os`, `__osVersion`, `__device`, `__model`, `__version`,
  /// `__buildNumber`, `__screenWidth`/`__screenHeight`/`__screenDpi`, `__wifi`.
  /// Static values are resolved once per process; only `__wifi` is dynamic
  /// (latest snapshot from `NWPathMonitor`).
  enum DeviceInfo {
    /// Ready-to-merge dictionary of reserved device-metadata keys.
    /// Keys absent on the current platform are simply omitted.
    static var metadata: [String: String] {
      var combinedMetadata = staticMetadata
      if let isWiFi = wifiMonitor.isWiFi {
        combinedMetadata["__wifi"] = isWiFi ? "true" : "false"
      }
      return combinedMetadata
    }

    private static let wifiMonitor = WiFiMonitor()

    private static let staticMetadata: [String: String] = {
      var metadata: [String: String] = [
        "__brand": "Apple",
        "__osVersion": osVersion,
        "__model": model
      ]
      // Server parses User-Agent to fill `__os`/`__device`; URLSession's default UA doesn't
      // carry an Apple platform marker, so without these overrides events fall back to "desktop".
      if let osName { metadata["__os"] = osName }
      if let device { metadata["__device"] = device }
      if let bundleVersion = bundleString("CFBundleShortVersionString") { metadata["__version"] = bundleVersion }
      if let bundleBuildNumber = bundleString("CFBundleVersion") { metadata["__buildNumber"] = bundleBuildNumber }
      if let screen = currentScreen() {
        metadata["__screenWidth"] = String(screen.width)
        metadata["__screenHeight"] = String(screen.height)
        metadata["__screenDpi"] = String(screen.dpi)
      }
      return metadata
    }()

    private static let osName: String? = {
      #if targetEnvironment(macCatalyst)
      return "macOS"
      #elseif os(iOS)
      return "iOS"
      #elseif os(macOS)
      return "macOS"
      #elseif os(tvOS)
      return "tvOS"
      #elseif os(watchOS)
      return "watchOS"
      #elseif os(visionOS)
      return "visionOS"
      #else
      return nil
      #endif
    }()

    private static let device: String? = {
      // Derived per-OS rather than from `UIDevice.userInterfaceIdiom` because the latter is
      // `@MainActor`-isolated in recent SDKs and can't be read from this nonisolated init.
      // For iOS we split mobile vs. tablet by the sysctl-resolved model prefix.
      #if targetEnvironment(macCatalyst) || os(macOS)
      return "desktop"
      #elseif os(watchOS)
      return "wearable"
      #elseif os(visionOS)
      return "headset"
      #elseif os(tvOS)
      return "tv"
      #elseif os(iOS)
      if model.hasPrefix("iPad") { return "tablet" }
      if model.hasPrefix("iPhone") || model.hasPrefix("iPod") { return "mobile" }
      return nil
      #else
      return nil
      #endif
    }()

    private static let osVersion: String = {
      let version = ProcessInfo.processInfo.operatingSystemVersion
      return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }()

    private static let model: String = {
      #if os(macOS)
      return sysctlString("hw.model") ?? "Mac"
      #else
      if let simulatorModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
        return simulatorModel
      }
      return sysctlString("hw.machine") ?? "Unknown"
      #endif
    }()

    private static func bundleString(_ key: String) -> String? {
      let bundleValue = Bundle.main.infoDictionary?[key] as? String
      return (bundleValue?.isEmpty == false) ? bundleValue : nil
    }

    private static func currentScreen() -> (width: Int, height: Int, dpi: Int)? {
      #if os(iOS) || os(tvOS) || os(visionOS)
      let mainScreen = UIScreen.main
      let screenBounds = mainScreen.bounds
      let screenScale = mainScreen.scale
      return (Int(screenBounds.width), Int(screenBounds.height), Int(160 * screenScale))
      #elseif os(watchOS)
      let interfaceDevice = WKInterfaceDevice.current()
      let screenBounds = interfaceDevice.screenBounds
      let screenScale = interfaceDevice.screenScale
      return (Int(screenBounds.width), Int(screenBounds.height), Int(160 * screenScale))
      #elseif os(macOS)
      guard let mainScreen = NSScreen.main else { return nil }
      let screenFrame = mainScreen.frame
      let screenDpi = mainScreen.deviceDescription[NSDeviceDescriptionKey("NSDeviceResolution")]
        .flatMap { ($0 as? NSValue)?.sizeValue.width } ?? 72
      return (Int(screenFrame.width), Int(screenFrame.height), Int(screenDpi))
      #else
      return nil
      #endif
    }

    private static func sysctlString(_ name: String) -> String? {
      var bufferSize = 0
      guard sysctlbyname(name, nil, &bufferSize, nil, 0) == 0, bufferSize > 0 else { return nil }
      var buffer = [UInt8](repeating: 0, count: bufferSize)
      guard sysctlbyname(name, &buffer, &bufferSize, nil, 0) == 0 else { return nil }
      let nullTerminatedBytes = buffer.prefix(while: { $0 != 0 })
      return String(decoding: nullTerminatedBytes, as: UTF8.self)
    }
  }

  /// Snapshot of the current WiFi-reachability state from `NWPathMonitor`.
  /// `nil` until the first path update arrives, or on platforms without
  /// the `Network` framework.
  final class WiFiMonitor: Sendable {
    private let lockedState = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    #if canImport(Network)
    /// `NWPathMonitor` does not self-retain — it must be held strongly for
    /// `pathUpdateHandler` to keep firing past the end of `init`.
    private let pathMonitor: NWPathMonitor
    #endif

    var isWiFi: Bool? {
      lockedState.withLock { state in state }
    }

    init() {
      #if canImport(Network)
      let pathMonitor = NWPathMonitor()
      pathMonitor.pathUpdateHandler = { [lockedState] path in
        lockedState.withLock { state in state = path.usesInterfaceType(.wifi) }
      }
      pathMonitor.start(queue: DispatchQueue(label: "dev.openpanel.wifi"))
      self.pathMonitor = pathMonitor
      #endif
    }
  }
}

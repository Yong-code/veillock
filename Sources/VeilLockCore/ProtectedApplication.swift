import Foundation

public struct ProtectedApplication: Codable, Hashable, Identifiable, Sendable {
  public let bundleIdentifier: String
  public var displayName: String

  public var id: String { bundleIdentifier }

  public init(bundleIdentifier: String, displayName: String) {
    self.bundleIdentifier = bundleIdentifier
    self.displayName = displayName
  }
}

public enum ProtectionPolicy {
  public static let blockedBundleIdentifiers: Set<String> = [
    "com.apple.Terminal",
    "com.apple.finder",
    "com.apple.ActivityMonitor",
    "com.apple.SystemSettings",
    "com.apple.systempreferences",
    "com.apple.loginwindow",
    "org.veillock.app",
  ]

  public static func canProtect(bundleIdentifier: String) -> Bool {
    !bundleIdentifier.isEmpty && !blockedBundleIdentifiers.contains(bundleIdentifier)
  }
}

public enum ProtectedApplicationError: LocalizedError, Equatable {
  case invalidApplication
  case missingBundleIdentifier
  case protectedSystemApplication
  case duplicateApplication

  public var errorDescription: String? {
    switch self {
    case .invalidApplication:
      return "Choose a macOS application bundle."
    case .missingBundleIdentifier:
      return "This application does not provide a bundle identifier."
    case .protectedSystemApplication:
      return "VeilLock does not allow locking this system application."
    case .duplicateApplication:
      return "This application is already protected."
    }
  }
}

import CommonCrypto
import Foundation

public enum PasswordDigestError: LocalizedError, Equatable {
  case passwordTooShort
  case invalidSalt
  case derivationFailed(Int32)

  public var errorDescription: String? {
    switch self {
    case .passwordTooShort:
      return "Use at least 12 characters for the configuration password."
    case .invalidSalt:
      return "The configuration password record is invalid."
    case .derivationFailed:
      return "VeilLock could not securely process the configuration password."
    }
  }
}

public struct PasswordDigest: Codable, Equatable, Sendable {
  public static let minimumPasswordLength = 12
  public static let requiredSaltLength = 32
  public static let recommendedIterations: UInt32 = 600_000

  public let salt: Data
  public let hash: Data
  public let iterations: UInt32

  public init(
    password: String,
    salt: Data,
    iterations: UInt32 = PasswordDigest.recommendedIterations
  ) throws {
    guard password.count >= Self.minimumPasswordLength else {
      throw PasswordDigestError.passwordTooShort
    }
    guard salt.count == Self.requiredSaltLength else {
      throw PasswordDigestError.invalidSalt
    }

    self.salt = salt
    self.iterations = iterations
    hash = try Self.derive(password: password, salt: salt, iterations: iterations)
  }

  public func verifies(_ password: String) -> Bool {
    guard let candidate = try? Self.derive(password: password, salt: salt, iterations: iterations)
    else { return false }
    return Self.constantTimeEqual(candidate, hash)
  }

  private static func derive(password: String, salt: Data, iterations: UInt32) throws -> Data {
    guard salt.count == requiredSaltLength, iterations > 0 else {
      throw PasswordDigestError.invalidSalt
    }

    let passwordBytes = Array(password.utf8)
    let derivedKeyLength = 32
    var derivedKey = [UInt8](repeating: 0, count: derivedKeyLength)
    let status = derivedKey.withUnsafeMutableBytes { derivedKeyBuffer in
      passwordBytes.withUnsafeBytes { passwordBuffer in
        salt.withUnsafeBytes { saltBuffer in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
            passwordBytes.count,
            saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
            salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            iterations,
            derivedKeyBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
            derivedKeyLength
          )
        }
      }
    }

    guard status == kCCSuccess else {
      throw PasswordDigestError.derivationFailed(status)
    }
    return Data(derivedKey)
  }

  private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}

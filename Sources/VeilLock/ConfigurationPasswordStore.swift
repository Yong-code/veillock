import Foundation
import Security
import VeilLockCore

enum ConfigurationPasswordStoreError: LocalizedError {
  case keychain(OSStatus)
  case randomSalt(OSStatus)
  case malformedRecord

  var errorDescription: String? {
    switch self {
    case .keychain:
      return "VeilLock could not update the configuration password in your login keychain."
    case .randomSalt:
      return "VeilLock could not securely create a configuration password."
    case .malformedRecord:
      return "The saved configuration password record is invalid. Remove it and set a new one."
    }
  }
}

enum ConfigurationPasswordStore {
  private static let service = "org.veillock.app.configuration-password"
  private static let account = "primary"

  static var isConfigured: Bool {
    (try? load()) != nil
  }

  static func save(_ password: String) throws {
    let digest = try PasswordDigest(password: password, salt: try makeSalt())
    let data = try JSONEncoder().encode(digest)

    let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
    guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
      throw ConfigurationPasswordStoreError.keychain(deleteStatus)
    }

    var query = baseQuery
    query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    query[kSecValueData] = data
    let addStatus = SecItemAdd(query as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw ConfigurationPasswordStoreError.keychain(addStatus)
    }
  }

  static func verify(_ password: String) throws -> Bool {
    guard let digest = try load() else { return false }
    return digest.verifies(password)
  }

  static func remove() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ConfigurationPasswordStoreError.keychain(status)
    }
  }

  private static var baseQuery: [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
  }

  private static func load() throws -> PasswordDigest? {
    var query = baseQuery
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecItemNotFound:
      return nil
    case errSecSuccess:
      guard let data = item as? Data,
        let digest = try? JSONDecoder().decode(PasswordDigest.self, from: data)
      else { throw ConfigurationPasswordStoreError.malformedRecord }
      return digest
    default:
      throw ConfigurationPasswordStoreError.keychain(status)
    }
  }

  private static func makeSalt() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: PasswordDigest.requiredSaltLength)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw ConfigurationPasswordStoreError.randomSalt(status)
    }
    return Data(bytes)
  }
}

import XCTest

@testable import VeilLockCore

final class ProtectedApplicationTests: XCTestCase {
  func testIdentifierIsStableIdentifier() {
    let app = ProtectedApplication(bundleIdentifier: "com.tencent.xinWeChat", displayName: "WeChat")
    XCTAssertEqual(app.id, "com.tencent.xinWeChat")
  }

  func testRoundTripEncodingPreservesValues() throws {
    let input = [
      ProtectedApplication(bundleIdentifier: "com.tencent.xinWeChat", displayName: "WeChat"),
      ProtectedApplication(bundleIdentifier: "com.apple.Notes", displayName: "Notes"),
    ]
    let data = try JSONEncoder().encode(input)
    XCTAssertEqual(try JSONDecoder().decode([ProtectedApplication].self, from: data), input)
  }

  func testCriticalSystemAppsCannotBeProtected() {
    XCTAssertFalse(ProtectionPolicy.canProtect(bundleIdentifier: "com.apple.Terminal"))
    XCTAssertFalse(ProtectionPolicy.canProtect(bundleIdentifier: "com.apple.finder"))
    XCTAssertFalse(ProtectionPolicy.canProtect(bundleIdentifier: "org.veillock.app"))
  }

  func testOrdinaryBundleCanBeProtected() {
    XCTAssertTrue(ProtectionPolicy.canProtect(bundleIdentifier: "com.tencent.xinWeChat"))
  }

  func testPasswordDigestVerifiesOnlyTheOriginalPassword() throws {
    let salt = Data(repeating: 0x5A, count: PasswordDigest.requiredSaltLength)
    let digest = try PasswordDigest(
      password: "correct-horse-battery", salt: salt, iterations: 1_000)

    XCTAssertTrue(digest.verifies("correct-horse-battery"))
    XCTAssertFalse(digest.verifies("wrong-horse-battery"))
  }

  func testPasswordDigestRejectsShortPasswords() {
    let salt = Data(repeating: 0x5A, count: PasswordDigest.requiredSaltLength)

    XCTAssertThrowsError(try PasswordDigest(password: "too-short", salt: salt, iterations: 1_000)) {
      XCTAssertEqual($0 as? PasswordDigestError, .passwordTooShort)
    }
  }
}

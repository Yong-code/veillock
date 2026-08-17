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
}

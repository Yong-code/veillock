import AppKit
import Combine
import LocalAuthentication
import VeilLockCore

@MainActor
final class LockCoordinator: ObservableObject {
  @Published private(set) var lockedApplication: ProtectedApplication?
  @Published private(set) var authenticationStatus = ""
  @Published private(set) var isAuthenticating = false

  private var unlockedBundleIdentifiers: Set<String> = []
  private var lockedRunningApplication: NSRunningApplication?
  private var authenticator: TouchIDAuthenticator?
  private var pendingHiddenApplicationIdentifier: String?
  var onApplicationUnlocked: ((String) -> Void)?

  func isUnlocked(_ bundleIdentifier: String) -> Bool {
    unlockedBundleIdentifiers.contains(bundleIdentifier)
  }

  func lock(_ application: ProtectedApplication, runningApplication: NSRunningApplication) {
    guard !isUnlocked(application.bundleIdentifier) else { return }

    if let lockedApplication {
      guard lockedApplication.bundleIdentifier == application.bundleIdentifier else {
        // A system Touch ID request can authenticate only one app at a time.
        // Keep every other protected app hidden until the current request ends.
        runningApplication.hide()
        return
      }
      lockedRunningApplication = runningApplication
      guard !isAuthenticating else {
        runningApplication.hide()
        return
      }
      hideThenRequestAuthentication(for: application, runningApplication: runningApplication)
      return
    }

    lockedApplication = application
    lockedRunningApplication = runningApplication
    authenticationStatus = "Touch ID is required to continue."

    hideThenRequestAuthentication(for: application, runningApplication: runningApplication)
  }

  func applicationDidHide(bundleIdentifier: String) {
    requestAuthenticationIfApplicationIsHidden(bundleIdentifier: bundleIdentifier)
  }

  func requestAuthentication() {
    guard let application = lockedApplication, !isAuthenticating else { return }
    isAuthenticating = true
    authenticationStatus = "Waiting for Touch ID…"

    let authenticator = TouchIDAuthenticator()
    self.authenticator = authenticator
    authenticator.authenticate(reason: "Unlock \(application.displayName)") { [weak self] result in
      guard let self else { return }
      guard self.authenticator === authenticator else { return }
      self.isAuthenticating = false
      switch result {
      case .success:
        self.unlockCurrentApplication()
      case .failure(let error):
        self.authenticationStatus = error.localizedDescription
      }
    }
  }

  func keepCurrentApplicationLocked() {
    pendingHiddenApplicationIdentifier = nil
    cancelAuthentication(status: "The app remains protected.")
  }

  func cancelAuthenticationForSpaceChange() {
    pendingHiddenApplicationIdentifier = nil
    guard isAuthenticating else {
      authenticationStatus = "The app remains protected."
      return
    }
    cancelAuthentication(status: "The app remains protected.")
  }

  func clearSession(for bundleIdentifier: String) {
    unlockedBundleIdentifiers.remove(bundleIdentifier)
  }

  func clearSessions() {
    unlockedBundleIdentifiers.removeAll()
    if lockedApplication != nil {
      keepCurrentApplicationLocked()
    }
  }

  private func unlockCurrentApplication() {
    guard let application = lockedApplication else { return }
    let runningApplication = lockedRunningApplication
    unlockedBundleIdentifiers.insert(application.bundleIdentifier)
    lockedApplication = nil
    lockedRunningApplication = nil
    pendingHiddenApplicationIdentifier = nil
    authenticator = nil
    authenticationStatus = ""

    onApplicationUnlocked?(application.bundleIdentifier)
    runningApplication?.unhide()
    runningApplication?.activate(options: [.activateIgnoringOtherApps])
  }

  private func hideThenRequestAuthentication(
    for application: ProtectedApplication, runningApplication: NSRunningApplication
  ) {
    pendingHiddenApplicationIdentifier = application.bundleIdentifier

    // The protected app must be hidden before the macOS authentication prompt
    // is allowed to appear. This does not use screen capture or an overlay.
    runningApplication.hide()

    // `didHideApplicationNotification` is the normal completion path. A
    // short guarded retry covers the case where the notification arrives
    // before `isHidden` reflects the completed transition.
    scheduleHiddenStateCheck(for: application.bundleIdentifier)
  }

  private func scheduleHiddenStateCheck(for bundleIdentifier: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      guard let self,
        self.pendingHiddenApplicationIdentifier == bundleIdentifier,
        self.lockedApplication?.bundleIdentifier == bundleIdentifier,
        !self.isAuthenticating
      else { return }

      if self.lockedRunningApplication?.isHidden == true {
        self.requestAuthenticationIfApplicationIsHidden(bundleIdentifier: bundleIdentifier)
      } else {
        self.lockedRunningApplication?.hide()
        self.scheduleHiddenStateCheck(for: bundleIdentifier)
      }
    }
  }

  private func requestAuthenticationIfApplicationIsHidden(bundleIdentifier: String) {
    guard pendingHiddenApplicationIdentifier == bundleIdentifier,
      lockedApplication?.bundleIdentifier == bundleIdentifier,
      lockedRunningApplication?.isHidden == true,
      !isAuthenticating
    else { return }

    pendingHiddenApplicationIdentifier = nil
    requestAuthentication()
  }

  private func cancelAuthentication(status: String) {
    authenticator?.cancel()
    authenticator = nil
    isAuthenticating = false
    authenticationStatus = status
  }
}

final class TouchIDAuthenticator {
  enum AuthenticationError: LocalizedError {
    case unavailable
    case cancelled
    case failed
    case lockedOut

    var errorDescription: String? {
      switch self {
      case .unavailable:
        return "Touch ID is unavailable. The application remains locked."
      case .cancelled:
        return "Touch ID was cancelled. The application remains locked."
      case .failed:
        return "Touch ID did not verify. Try again to unlock the application."
      case .lockedOut:
        return "Touch ID is temporarily locked. The application remains locked."
      }
    }
  }

  private var context: LAContext?

  func authenticate(
    reason: String, completion: @escaping (Result<Void, AuthenticationError>) -> Void
  ) {
    let context = LAContext()
    context.localizedCancelTitle = "Keep Locked"
    context.localizedFallbackTitle = ""

    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
      completion(.failure(.unavailable))
      return
    }

    self.context = context
    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) {
      success, error in
      DispatchQueue.main.async {
        if success {
          completion(.success(()))
          return
        }
        let code = (error as? LAError)?.code
        switch code {
        case .userCancel, .systemCancel, .appCancel:
          completion(.failure(.cancelled))
        case .biometryLockout:
          completion(.failure(.lockedOut))
        default:
          completion(.failure(.failed))
        }
      }
    }
  }

  func cancel() {
    context?.invalidate()
    context = nil
  }
}

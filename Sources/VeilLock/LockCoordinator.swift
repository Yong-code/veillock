import AppKit
import Combine
import LocalAuthentication
import VeilLockCore

@MainActor
final class LockCoordinator: ObservableObject {
  @Published private(set) var authenticationStatus = ""
  @Published private(set) var isAuthenticating = false

  private var unlockedBundleIdentifiers: Set<String> = []
  private var pendingApplication: ProtectedApplication?
  private var pendingRunningApplication: NSRunningApplication?
  private var authenticatingApplication: ProtectedApplication?
  private var authenticator: TouchIDAuthenticator?
  var onApplicationUnlocked: ((String) -> Void)?

  func isUnlocked(_ bundleIdentifier: String) -> Bool {
    unlockedBundleIdentifiers.contains(bundleIdentifier)
  }

  func lock(_ application: ProtectedApplication, runningApplication: NSRunningApplication) {
    guard !isUnlocked(application.bundleIdentifier) else { return }

    // macOS permits one LocalAuthentication request at a time. Every other
    // protected app remains hidden until the active request ends.
    guard !isAuthenticating else {
      runningApplication.hide()
      return
    }

    if let pendingApplication {
      guard pendingApplication.bundleIdentifier == application.bundleIdentifier else {
        runningApplication.hide()
        return
      }
      pendingRunningApplication = runningApplication
      runningApplication.hide()
      scheduleHiddenStateCheck(for: application.bundleIdentifier)
      return
    }

    authenticationStatus = "Touch ID is required to continue."
    hideThenRequestAuthentication(for: application, runningApplication: runningApplication)
  }

  func applicationDidHide(bundleIdentifier: String) {
    requestAuthenticationIfApplicationIsHidden(bundleIdentifier: bundleIdentifier)
  }

  private func requestAuthentication() {
    guard let application = pendingApplication,
      let runningApplication = pendingRunningApplication,
      !isAuthenticating
    else { return }

    pendingApplication = nil
    pendingRunningApplication = nil
    authenticatingApplication = application
    isAuthenticating = true
    authenticationStatus = "Waiting for Touch ID…"

    let authenticator = TouchIDAuthenticator()
    self.authenticator = authenticator
    authenticator.authenticate(reason: "Unlock \(application.displayName)") { [weak self] result in
      guard let self else { return }
      guard self.authenticator === authenticator else { return }
      self.authenticator = nil
      switch result {
      case .success:
        self.unlock(application: application, runningApplication: runningApplication)
      case .failure(let error):
        self.finishActiveRequest(status: error.localizedDescription)
      }
    }
  }

  func keepCurrentApplicationLocked() {
    cancelCurrentRequest(status: "The app remains protected.")
  }

  func cancelAuthenticationForSpaceChange() {
    cancelCurrentRequest(status: "The app remains protected.")
  }

  func clearSession(for bundleIdentifier: String) {
    unlockedBundleIdentifiers.remove(bundleIdentifier)
    guard requestIncludes(bundleIdentifier) else { return }
    cancelCurrentRequest(status: "The app remains protected.")
  }

  func clearSessions() {
    unlockedBundleIdentifiers.removeAll()
    cancelCurrentRequest(status: "The app remains protected.")
  }

  private func unlock(application: ProtectedApplication, runningApplication: NSRunningApplication) {
    unlockedBundleIdentifiers.insert(application.bundleIdentifier)
    finishActiveRequest(status: "")

    onApplicationUnlocked?(application.bundleIdentifier)
    runningApplication.unhide()
    runningApplication.activate(options: [.activateIgnoringOtherApps])
  }

  private func hideThenRequestAuthentication(
    for application: ProtectedApplication, runningApplication: NSRunningApplication
  ) {
    pendingApplication = application
    pendingRunningApplication = runningApplication

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
        self.pendingApplication?.bundleIdentifier == bundleIdentifier,
        !self.isAuthenticating
      else { return }

      if self.pendingRunningApplication?.isHidden == true {
        self.requestAuthenticationIfApplicationIsHidden(bundleIdentifier: bundleIdentifier)
      } else {
        self.pendingRunningApplication?.hide()
        self.scheduleHiddenStateCheck(for: bundleIdentifier)
      }
    }
  }

  private func requestAuthenticationIfApplicationIsHidden(bundleIdentifier: String) {
    guard pendingApplication?.bundleIdentifier == bundleIdentifier,
      pendingRunningApplication?.isHidden == true,
      !isAuthenticating
    else { return }

    requestAuthentication()
  }

  private func requestIncludes(_ bundleIdentifier: String) -> Bool {
    pendingApplication?.bundleIdentifier == bundleIdentifier
      || authenticatingApplication?.bundleIdentifier == bundleIdentifier
  }

  private func cancelCurrentRequest(status: String) {
    authenticator?.cancel()
    authenticator = nil
    pendingApplication = nil
    pendingRunningApplication = nil
    finishActiveRequest(status: status)
  }

  private func finishActiveRequest(status: String) {
    isAuthenticating = false
    authenticatingApplication = nil
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

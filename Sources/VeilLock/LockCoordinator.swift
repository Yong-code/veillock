import AppKit
import Combine
import LocalAuthentication
import VeilLockCore

@MainActor
final class LockCoordinator: ObservableObject {
  @Published private(set) var authenticationStatus = ""
  @Published private(set) var isAuthenticating = false

  private var unlockedBundleIdentifiers: Set<String> = []
  private var restoringBundleIdentifiers: Set<String> = []
  private var pendingApplication: ProtectedApplication?
  private var pendingRunningApplication: NSRunningApplication?
  private var authenticatingApplication: ProtectedApplication?
  private var authenticator: TouchIDAuthenticator?
  var onApplicationUnlocked: ((String) -> Void)?

  func isUnlocked(_ bundleIdentifier: String) -> Bool {
    unlockedBundleIdentifiers.contains(bundleIdentifier)
  }

  func isRestoring(_ bundleIdentifier: String) -> Bool {
    restoringBundleIdentifiers.contains(bundleIdentifier)
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
    restoringBundleIdentifiers.remove(bundleIdentifier)
    guard requestIncludes(bundleIdentifier) else { return }
    cancelCurrentRequest(status: "The app remains protected.")
  }

  func clearSessions() {
    unlockedBundleIdentifiers.removeAll()
    restoringBundleIdentifiers.removeAll()
    cancelCurrentRequest(status: "The app remains protected.")
  }

  private func unlock(application: ProtectedApplication, runningApplication: NSRunningApplication) {
    unlockedBundleIdentifiers.insert(application.bundleIdentifier)
    restoringBundleIdentifiers.insert(application.bundleIdentifier)
    finishActiveRequest(status: "")

    // Let the system-owned LocalAuthentication sheet finish dismissing before
    // attempting to hand activation back to the protected application.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      self?.restoreAfterAuthentication(
        runningApplication: runningApplication,
        bundleIdentifier: application.bundleIdentifier,
        attemptsRemaining: 40
      )
    }
  }

  private func restoreAfterAuthentication(
    runningApplication: NSRunningApplication,
    bundleIdentifier: String,
    attemptsRemaining: Int
  ) {
    guard isUnlocked(bundleIdentifier) else { return }
    guard let application = currentRunningApplication(
      for: bundleIdentifier, fallback: runningApplication
    ) else {
      restoreWithWorkspace(
        fallbackRunningApplication: runningApplication,
        bundleIdentifier: bundleIdentifier
      )
      return
    }

    // Most regular apps report this promptly. Apple documents that some apps
    // never do, so after one second we fall back to repeated restore attempts.
    if !application.isFinishedLaunching, attemptsRemaining > 20 {
      scheduleRestore(
        runningApplication: application,
        bundleIdentifier: bundleIdentifier,
        attemptsRemaining: attemptsRemaining - 1
      )
      return
    }

    _ = application.unhide()
    _ = activate(application)
    if isRestored(application) {
      finishSuccessfulRestore(for: bundleIdentifier)
      return
    }

    guard attemptsRemaining > 0 else {
      restoreWithWorkspace(
        fallbackRunningApplication: application,
        bundleIdentifier: bundleIdentifier
      )
      return
    }

    scheduleRestore(
      runningApplication: application,
      bundleIdentifier: bundleIdentifier,
      attemptsRemaining: attemptsRemaining - 1
    )
  }

  private func scheduleRestore(
    runningApplication: NSRunningApplication,
    bundleIdentifier: String,
    attemptsRemaining: Int
  ) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      self?.restoreAfterAuthentication(
        runningApplication: runningApplication,
        bundleIdentifier: bundleIdentifier,
        attemptsRemaining: attemptsRemaining
      )
    }
  }

  private func activate(_ runningApplication: NSRunningApplication) -> Bool {
    if #available(macOS 14.0, *) {
      return runningApplication.activate(
        from: .current,
        options: [.activateAllWindows]
      )
    }
    return runningApplication.activate(options: [.activateAllWindows])
  }

  private func currentRunningApplication(
    for bundleIdentifier: String,
    fallback: NSRunningApplication
  ) -> NSRunningApplication? {
    if !fallback.isTerminated { return fallback }
    return NSWorkspace.shared.runningApplications.first {
      $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
    }
  }

  private func isRestored(_ application: NSRunningApplication) -> Bool {
    !application.isHidden
      && application.isActive
      && WindowFrameResolver.primaryVisibleFrame(for: application) != nil
  }

  private func restoreWithWorkspace(
    fallbackRunningApplication: NSRunningApplication,
    bundleIdentifier: String
  ) {
    guard isUnlocked(bundleIdentifier),
      let applicationURL = currentRunningApplication(
        for: bundleIdentifier, fallback: fallbackRunningApplication
      )?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    else {
      finishUnsuccessfulRestore(for: bundleIdentifier)
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.hides = false
    configuration.allowsRunningApplicationSubstitution = true
    // Ask Launch Services to deliver the standard reopen event when the app is
    // already running but has no visible window (for example, after its red
    // close button was used). This is a system launch request, not scripting.
    configuration.appleEvent = NSAppleEventDescriptor(
      eventClass: AEEventClass(0x6165_7674),  // 'aevt'
      eventID: AEEventID(0x7261_7070),  // 'rapp'
      targetDescriptor: nil,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) {
      [weak self] restoredApplication, error in
      Task { @MainActor [weak self] in
        guard let self, self.isUnlocked(bundleIdentifier) else { return }
        guard error == nil else {
          self.finishUnsuccessfulRestore(for: bundleIdentifier)
          return
        }

        guard let applicationToRestore = restoredApplication ?? self.currentRunningApplication(
          for: bundleIdentifier, fallback: fallbackRunningApplication
        ) else {
          self.finishUnsuccessfulRestore(for: bundleIdentifier)
          return
        }
        self.confirmWorkspaceRestore(
          runningApplication: applicationToRestore,
          bundleIdentifier: bundleIdentifier,
          attemptsRemaining: 20
        )
      }
    }
  }

  private func confirmWorkspaceRestore(
    runningApplication: NSRunningApplication,
    bundleIdentifier: String,
    attemptsRemaining: Int
  ) {
    guard isUnlocked(bundleIdentifier), !runningApplication.isTerminated else {
      finishUnsuccessfulRestore(for: bundleIdentifier)
      return
    }

    _ = runningApplication.unhide()
    _ = activate(runningApplication)
    if isRestored(runningApplication) {
      finishSuccessfulRestore(for: bundleIdentifier)
      return
    }

    guard attemptsRemaining > 0 else {
      finishUnsuccessfulRestore(for: bundleIdentifier)
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.confirmWorkspaceRestore(
        runningApplication: runningApplication,
        bundleIdentifier: bundleIdentifier,
        attemptsRemaining: attemptsRemaining - 1
      )
    }
  }

  private func finishUnsuccessfulRestore(for bundleIdentifier: String) {
    unlockedBundleIdentifiers.remove(bundleIdentifier)
    restoringBundleIdentifiers.remove(bundleIdentifier)
    authenticationStatus = "Could not restore the application. It remains protected."
  }

  private func finishSuccessfulRestore(for bundleIdentifier: String) {
    guard isUnlocked(bundleIdentifier), restoringBundleIdentifiers.remove(bundleIdentifier) != nil else {
      return
    }
    onApplicationUnlocked?(bundleIdentifier)
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

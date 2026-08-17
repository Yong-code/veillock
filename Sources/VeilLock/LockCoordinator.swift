import AppKit
import LocalAuthentication
import SwiftUI
import VeilLockCore

@MainActor
final class LockCoordinator: ObservableObject {
  @Published private(set) var lockedApplication: ProtectedApplication?
  @Published private(set) var authenticationStatus = ""
  @Published private(set) var isAuthenticating = false

  private var unlockedBundleIdentifiers: Set<String> = []
  private var lockedRunningApplication: NSRunningApplication?
  private var panels: [LockPanel] = []
  private var authenticator: TouchIDAuthenticator?
  var onApplicationUnlocked: ((String) -> Void)?

  func isUnlocked(_ bundleIdentifier: String) -> Bool {
    unlockedBundleIdentifiers.contains(bundleIdentifier)
  }

  func lock(_ application: ProtectedApplication, runningApplication: NSRunningApplication) {
    guard lockedApplication == nil, !isUnlocked(application.bundleIdentifier) else { return }
    lockedApplication = application
    lockedRunningApplication = runningApplication
    authenticationStatus = "Touch ID is required to continue."
    let windowFrame = WindowFrameResolver.foremostVisibleFrame(for: runningApplication)

    // Hiding the protected app is deliberate: an overlay alone can be exposed
    // briefly by a Spaces transition. The panel uses the last public window
    // geometry only; it does not take a screenshot or inspect app content.
    runningApplication.hide()
    showPanel(for: application, frame: windowFrame)

    DispatchQueue.main.async { [weak self] in
      self?.requestAuthentication()
    }
  }

  func requestAuthentication() {
    guard let application = lockedApplication, !isAuthenticating else { return }
    isAuthenticating = true
    updatePanelInteractivity()
    authenticationStatus = "Waiting for Touch ID…"

    let authenticator = TouchIDAuthenticator()
    self.authenticator = authenticator
    authenticator.authenticate(reason: "Unlock \(application.displayName)") { [weak self] result in
      guard let self else { return }
      self.isAuthenticating = false
      self.updatePanelInteractivity()
      switch result {
      case .success:
        self.unlockCurrentApplication()
      case .failure(let error):
        self.authenticationStatus = error.localizedDescription
      }
    }
  }

  func keepCurrentApplicationLocked() {
    authenticator?.cancel()
    authenticator = nil
    isAuthenticating = false
    updatePanelInteractivity()
    authenticationStatus = "The app remains protected."
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
    authenticator = nil
    authenticationStatus = ""
    dismissPanels()

    onApplicationUnlocked?(application.bundleIdentifier)
    runningApplication?.unhide()
    runningApplication?.activate(options: [.activateIgnoringOtherApps])
  }

  private func showPanel(for application: ProtectedApplication, frame: CGRect?) {
    dismissPanels()
    let targetFrame = frame ?? NSScreen.main?.frame ?? NSScreen.screens.first?.frame
    guard let targetFrame else { return }

    let panel = LockPanel(frame: targetFrame, coordinator: self, application: application)
    panel.setAuthenticationActive(isAuthenticating)
    panel.orderFrontRegardless()
    panels.append(panel)
  }

  private func updatePanelInteractivity() {
    for panel in panels {
      panel.setAuthenticationActive(isAuthenticating)
    }
  }

  private func dismissPanels() {
    for panel in panels {
      panel.orderOut(nil)
    }
    panels.removeAll()
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

final class LockPanel: NSPanel {
  init(frame: CGRect, coordinator: LockCoordinator, application: ProtectedApplication) {
    super.init(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    setFrame(frame, display: false)
    isOpaque = false
    backgroundColor = .clear
    level = .screenSaver
    // Keep the veil in the protected app's current desktop space. It must not
    // follow the user into a different app's independent full-screen space.
    collectionBehavior = [.stationary, .ignoresCycle]
    hasShadow = false
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    contentView = LockHostingView(
      rootView: LockScreen(coordinator: coordinator, application: application))
  }

  func setAuthenticationActive(_ isActive: Bool) {
    ignoresMouseEvents = isActive
  }

  // While LocalAuthentication owns the system prompt, this panel must not take
  // keyboard focus. Otherwise a click on the veil can deactivate the prompt.
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

final class LockHostingView: NSHostingView<LockScreen> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct LockScreen: View {
  @ObservedObject var coordinator: LockCoordinator
  let application: ProtectedApplication
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        if reduceTransparency {
          Color.black.opacity(0.94)
        } else {
          FrostedBackdrop()
          Color.black.opacity(0.42)
        }

        lockCard
          .frame(maxWidth: min(390, max(240, proxy.size.width - 40)))
          .position(x: proxy.size.width / 2, y: cardCenter(in: proxy.size))
      }
      .allowsHitTesting(!coordinator.isAuthenticating)
    }
    .ignoresSafeArea()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      coordinator.isAuthenticating
        ? "\(application.displayName) is protected. Use the macOS Touch ID prompt above."
        : "\(application.displayName) is protected. Touch ID is required to unlock it.")
  }

  @ViewBuilder
  private var lockCard: some View {
    VStack(spacing: coordinator.isAuthenticating ? 10 : 16) {
      Image(systemName: "lock.fill")
        .font(.system(size: coordinator.isAuthenticating ? 23 : 36, weight: .semibold))
        .foregroundStyle(.white)
        .padding(coordinator.isAuthenticating ? 12 : 16)
        .background(.white.opacity(0.12), in: Circle())

      Text("\(application.displayName) is protected")
        .font(.system(size: coordinator.isAuthenticating ? 19 : 25, weight: .semibold))
        .foregroundStyle(.white)

      Text(
        coordinator.isAuthenticating
          ? "Use the macOS Touch ID prompt above."
          : coordinator.authenticationStatus)
        .font(.callout)
        .foregroundStyle(.white.opacity(0.72))
        .multilineTextAlignment(.center)

      if !coordinator.isAuthenticating {
        Button {
          coordinator.requestAuthentication()
        } label: {
          Label("Try Touch ID Again", systemImage: "touchid")
        }
        .buttonStyle(.borderedProminent)
        .tint(.indigo)
      }
    }
    .padding(coordinator.isAuthenticating ? 20 : 30)
    .background(.black.opacity(reduceTransparency ? 0.20 : 0.32))
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(.white.opacity(0.12))
    }
    .shadow(color: .black.opacity(0.32), radius: 28, y: 12)
  }

  private func cardCenter(in size: CGSize) -> CGFloat {
    let cardHeight: CGFloat = coordinator.isAuthenticating ? 150 : 250
    if coordinator.isAuthenticating {
      // Keep the compact VeilLock status card below the system-owned Touch ID
      // prompt, while centering both elements horizontally in the app window.
      return min(size.height - cardHeight / 2 - 24, max(cardHeight / 2 + 24, size.height * 0.74))
    }
    return size.height / 2
  }
}

struct FrostedBackdrop: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

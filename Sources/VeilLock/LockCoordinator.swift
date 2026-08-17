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

  func isUnlocked(_ bundleIdentifier: String) -> Bool {
    unlockedBundleIdentifiers.contains(bundleIdentifier)
  }

  func lock(_ application: ProtectedApplication, runningApplication: NSRunningApplication) {
    guard lockedApplication == nil, !isUnlocked(application.bundleIdentifier) else { return }
    lockedApplication = application
    lockedRunningApplication = runningApplication
    authenticationStatus = "Touch ID is required to continue."
    showPanels(for: application, frames: WindowFrameResolver.visibleFrames(for: runningApplication))

    DispatchQueue.main.async { [weak self] in
      self?.requestAuthentication()
    }
  }

  func requestAuthentication() {
    guard let application = lockedApplication, !isAuthenticating else { return }
    isAuthenticating = true
    authenticationStatus = "Waiting for Touch ID…"

    let authenticator = TouchIDAuthenticator()
    self.authenticator = authenticator
    authenticator.authenticate(reason: "Unlock \(application.displayName)") { [weak self] result in
      guard let self else { return }
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
    authenticator?.cancel()
    authenticator = nil
    isAuthenticating = false
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

    runningApplication?.unhide()
    runningApplication?.activate(options: [.activateIgnoringOtherApps])
  }

  private func showPanels(for application: ProtectedApplication, frames: [CGRect]) {
    dismissPanels()
    let panelFrames = frames.isEmpty ? NSScreen.screens.map(\.frame) : frames
    for frame in panelFrames {
      let panel = LockPanel(frame: frame, coordinator: self, application: application)
      panel.orderFrontRegardless()
      panels.append(panel)
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
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    hasShadow = false
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    contentView = NSHostingView(
      rootView: LockScreen(coordinator: coordinator, application: application))
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

struct LockScreen: View {
  @ObservedObject var coordinator: LockCoordinator
  let application: ProtectedApplication
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    ZStack {
      if reduceTransparency {
        Color.black.opacity(0.94)
      } else {
        FrostedBackdrop()
        Color.black.opacity(0.42)
      }

      VStack(spacing: 18) {
        Image(systemName: "lock.fill")
          .font(.system(size: 42, weight: .semibold))
          .foregroundStyle(.white)
          .padding(18)
          .background(.white.opacity(0.12), in: Circle())

        Text("\(application.displayName) is protected")
          .font(.system(size: 26, weight: .semibold))
          .foregroundStyle(.white)

        Text(coordinator.authenticationStatus)
          .font(.callout)
          .foregroundStyle(.white.opacity(0.72))
          .multilineTextAlignment(.center)
          .frame(maxWidth: 360)

        HStack(spacing: 12) {
          Button("Keep Locked") {
            coordinator.keepCurrentApplicationLocked()
          }
          .buttonStyle(.bordered)
          .tint(.white.opacity(0.18))

          Button {
            coordinator.requestAuthentication()
          } label: {
            Label("Unlock with Touch ID", systemImage: "touchid")
          }
          .buttonStyle(.borderedProminent)
          .tint(.indigo)
          .disabled(coordinator.isAuthenticating)
        }
      }
      .padding(34)
      .frame(maxWidth: 430)
      .background(.black.opacity(reduceTransparency ? 0.20 : 0.32))
      .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .stroke(.white.opacity(0.12))
      }
      .shadow(color: .black.opacity(0.32), radius: 28, y: 12)
    }
    .ignoresSafeArea()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      "\(application.displayName) is protected. Touch ID is required to unlock it.")
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

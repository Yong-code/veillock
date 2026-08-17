import AppKit
import Combine
import Foundation
import VeilLockCore

@MainActor
final class ApplicationMonitor {
  private let protectedApps: ProtectedAppsStore
  private let settings: GuardSettings
  private let lockCoordinator: LockCoordinator
  private var observers: [NSObjectProtocol] = []
  private var isMonitoring = false
  private var deactivationRelockWorkItems: [String: DispatchWorkItem] = [:]
  private var windowClosureRelockWorkItems: [String: DispatchWorkItem] = [:]
  private var activeReauthenticationWorkItems: [String: DispatchWorkItem] = [:]
  private var trackedUnlockedBundleIdentifiers: Set<String> = []
  private var windowVisibilityTimer: Timer?
  private var lockedApplicationVisibilityTimer: Timer?

  init(protectedApps: ProtectedAppsStore, settings: GuardSettings, lockCoordinator: LockCoordinator)
  {
    self.protectedApps = protectedApps
    self.settings = settings
    self.lockCoordinator = lockCoordinator
  }

  func start() {
    guard !isMonitoring else { return }
    let center = NSWorkspace.shared.notificationCenter

    observers.append(
      center.addObserver(
        forName: NSWorkspace.willLaunchApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        Task { @MainActor [weak self] in
          self?.hideBeforeLaunch(notification)
        }
      })

    observers.append(
      center.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        Task { @MainActor [weak self] in
          self?.handle(notification)
        }
      })

    observers.append(
      center.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        Task { @MainActor [weak self] in
          self?.handle(notification)
        }
      })

    observers.append(
      center.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.handleActiveSpaceChange()
        }
      })

    observers.append(
      center.addObserver(
        forName: NSWorkspace.didHideApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard
          let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
          let bundleIdentifier = application.bundleIdentifier
        else { return }
        Task { @MainActor [weak self] in
          self?.lockCoordinator.applicationDidHide(bundleIdentifier: bundleIdentifier)
        }
      })

    observers.append(
      center.addObserver(
        forName: NSWorkspace.didUnhideApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        Task { @MainActor [weak self] in
          self?.handleUnhide(notification)
        }
      })

    observers.append(
      center.addObserver(
        forName: NSWorkspace.didDeactivateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard
          let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
          let bundleIdentifier = application.bundleIdentifier
        else { return }
        Task { @MainActor [weak self] in
          self?.handleDeactivation(bundleIdentifier: bundleIdentifier)
        }
      })

    observers.append(
      center.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard
          let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
          let bundleIdentifier = application.bundleIdentifier
        else { return }
        Task { @MainActor [weak self] in
          self?.handleTermination(bundleIdentifier: bundleIdentifier)
        }
      })

    isMonitoring = true
    startLockedApplicationVisibilityMonitoring()
  }

  deinit {
    for observer in observers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    windowVisibilityTimer?.invalidate()
    lockedApplicationVisibilityTimer?.invalidate()
    for item in deactivationRelockWorkItems.values { item.cancel() }
    for item in windowClosureRelockWorkItems.values { item.cancel() }
    for item in activeReauthenticationWorkItems.values { item.cancel() }
  }

  func enforceExistingApplications() {
    guard settings.protectionEnabled else { return }
    let running = NSWorkspace.shared.runningApplications
    for application in running {
      guard let bundleIdentifier = application.bundleIdentifier,
        protectedApps.contains(bundleIdentifier: bundleIdentifier),
        !lockCoordinator.isUnlocked(bundleIdentifier)
      else { continue }
      application.hide()
    }

    if let frontmost = NSWorkspace.shared.frontmostApplication,
      let bundleIdentifier = frontmost.bundleIdentifier,
      let protectedApp = protectedApps.applications.first(where: {
        $0.bundleIdentifier == bundleIdentifier
      }),
      !lockCoordinator.isUnlocked(bundleIdentifier)
    {
      lockCoordinator.lock(protectedApp, runningApplication: frontmost)
    }
  }

  func hideProtectedRunningApplications() {
    for application in NSWorkspace.shared.runningApplications {
      guard let bundleIdentifier = application.bundleIdentifier,
        protectedApps.contains(bundleIdentifier: bundleIdentifier)
      else { continue }
      application.hide()
    }
  }

  func stopTrackingUnlockedApplications() {
    for bundleIdentifier in trackedUnlockedBundleIdentifiers {
      cancelAutomaticRelocking(for: bundleIdentifier)
    }
    trackedUnlockedBundleIdentifiers.removeAll()
    windowVisibilityTimer?.invalidate()
    windowVisibilityTimer = nil
  }

  func removeProtection(for bundleIdentifier: String) {
    cancelAutomaticRelocking(for: bundleIdentifier)
    endTrackingUnlockedApplication(bundleIdentifier)
  }

  func didUnlockApplication(bundleIdentifier: String) {
    guard lockCoordinator.isUnlocked(bundleIdentifier) else { return }
    beginTrackingUnlockedApplication(bundleIdentifier)
    if let runningApplication = runningApplication(for: bundleIdentifier), runningApplication.isActive {
      scheduleActiveReauthentication(for: bundleIdentifier)
    }
  }

  func refreshAutomaticRelocking() {
    for item in deactivationRelockWorkItems.values { item.cancel() }
    for item in windowClosureRelockWorkItems.values { item.cancel() }
    for item in activeReauthenticationWorkItems.values { item.cancel() }
    deactivationRelockWorkItems.removeAll()
    windowClosureRelockWorkItems.removeAll()
    activeReauthenticationWorkItems.removeAll()

    for bundleIdentifier in trackedUnlockedBundleIdentifiers
      where lockCoordinator.isUnlocked(bundleIdentifier)
    {
      if runningApplication(for: bundleIdentifier)?.isActive == true {
        scheduleActiveReauthentication(for: bundleIdentifier)
      } else {
        scheduleDeactivationRelock(for: bundleIdentifier)
      }
    }
  }

  private func handle(_ notification: Notification) {
    guard settings.protectionEnabled,
      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication,
      let bundleIdentifier = application.bundleIdentifier,
      let protectedApp = protectedApps.applications.first(where: {
        $0.bundleIdentifier == bundleIdentifier
      })
    else { return }

    cancelDeactivationRelock(for: bundleIdentifier)
    if lockCoordinator.isUnlocked(bundleIdentifier) {
      // Authentication succeeded, but the target window is still being
      // restored. Starting automatic re-lock timing now could immediately
      // relock a slow-to-reopen app before its window appears.
      guard !lockCoordinator.isRestoring(bundleIdentifier) else { return }
      beginTrackingUnlockedApplication(bundleIdentifier)
      if application.isActive {
        scheduleActiveReauthentication(for: bundleIdentifier)
      }
      return
    }

    lockCoordinator.lock(protectedApp, runningApplication: application)
  }

  private func hideBeforeLaunch(_ notification: Notification) {
    guard settings.protectionEnabled,
      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication,
      let bundleIdentifier = application.bundleIdentifier,
      protectedApps.contains(bundleIdentifier: bundleIdentifier),
      !lockCoordinator.isUnlocked(bundleIdentifier)
    else { return }

    // This is only an early hide request. Starting Touch ID here is too early:
    // some apps cannot reliably unhide until the did-launch lifecycle event.
    application.hide()
  }

  private func handleActiveSpaceChange() {
    lockCoordinator.cancelAuthenticationForSpaceChange()
    hideLockedProtectedRunningApplications()
    DispatchQueue.main.async { [weak self] in
      self?.hideLockedProtectedRunningApplications()
    }
  }

  private func handleUnhide(_ notification: Notification) {
    guard settings.protectionEnabled,
      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication,
      let bundleIdentifier = application.bundleIdentifier,
      protectedApps.contains(bundleIdentifier: bundleIdentifier),
      !lockCoordinator.isUnlocked(bundleIdentifier)
    else { return }

    // A Space transition can make a hidden app visible without an activation
    // event. Re-hide it here; the next explicit launch or activation starts
    // the Touch ID request.
    application.hide()
  }

  private func handleDeactivation(bundleIdentifier: String) {
    cancelActiveReauthentication(for: bundleIdentifier)
    guard lockCoordinator.isUnlocked(bundleIdentifier), !lockCoordinator.isRestoring(bundleIdentifier)
    else { return }
    beginTrackingUnlockedApplication(bundleIdentifier)
    scheduleDeactivationRelock(for: bundleIdentifier)
  }

  private func handleTermination(bundleIdentifier: String) {
    cancelAutomaticRelocking(for: bundleIdentifier)
    lockCoordinator.clearSession(for: bundleIdentifier)
    endTrackingUnlockedApplication(bundleIdentifier)
  }

  private func beginTrackingUnlockedApplication(_ bundleIdentifier: String) {
    trackedUnlockedBundleIdentifiers.insert(bundleIdentifier)
    guard windowVisibilityTimer == nil else { return }
    windowVisibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.checkTrackedWindowVisibility()
      }
    }
  }

  private func startLockedApplicationVisibilityMonitoring() {
    guard lockedApplicationVisibilityTimer == nil else { return }
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.hideLockedProtectedRunningApplications()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    lockedApplicationVisibilityTimer = timer
  }

  private func hideLockedProtectedRunningApplications() {
    guard settings.protectionEnabled else { return }
    for application in NSWorkspace.shared.runningApplications {
      guard let bundleIdentifier = application.bundleIdentifier,
        protectedApps.contains(bundleIdentifier: bundleIdentifier),
        !lockCoordinator.isUnlocked(bundleIdentifier),
        !application.isHidden
      else { continue }
      application.hide()
    }
  }

  private func endTrackingUnlockedApplication(_ bundleIdentifier: String) {
    trackedUnlockedBundleIdentifiers.remove(bundleIdentifier)
    guard trackedUnlockedBundleIdentifiers.isEmpty else { return }
    windowVisibilityTimer?.invalidate()
    windowVisibilityTimer = nil
  }

  private func checkTrackedWindowVisibility() {
    for bundleIdentifier in Array(trackedUnlockedBundleIdentifiers) {
      guard let runningApplication = runningApplication(for: bundleIdentifier) else {
        handleTermination(bundleIdentifier: bundleIdentifier)
        continue
      }

      let hasVisibleWindow = WindowFrameResolver.primaryVisibleFrame(for: runningApplication) != nil
      if lockCoordinator.isRestoring(bundleIdentifier) {
        continue
      }
      if !lockCoordinator.isUnlocked(bundleIdentifier) {
        if runningApplication.isActive,
          hasVisibleWindow,
          let protectedApp = protectedApplication(for: bundleIdentifier)
        {
          lockCoordinator.lock(protectedApp, runningApplication: runningApplication)
        }
        continue
      }

      if hasVisibleWindow {
        cancelWindowClosureRelock(for: bundleIdentifier)
      } else {
        scheduleWindowClosureRelock(for: bundleIdentifier)
      }
    }
  }

  private func scheduleDeactivationRelock(for bundleIdentifier: String) {
    guard deactivationRelockWorkItems[bundleIdentifier] == nil else { return }
    scheduleRelock(
      for: bundleIdentifier,
      afterMinutes: settings.relockAfterWindowClosesOrLeavesMinutes,
      storage: &deactivationRelockWorkItems
    )
  }

  private func scheduleWindowClosureRelock(for bundleIdentifier: String) {
    guard windowClosureRelockWorkItems[bundleIdentifier] == nil else { return }
    scheduleRelock(
      for: bundleIdentifier,
      afterMinutes: settings.relockAfterWindowClosesOrLeavesMinutes,
      storage: &windowClosureRelockWorkItems
    )
  }

  private func scheduleRelock(
    for bundleIdentifier: String,
    afterMinutes: Double,
    storage: inout [String: DispatchWorkItem]
  ) {
    let item = DispatchWorkItem { [weak self] in
      Task { @MainActor [weak self] in
        self?.expireSession(for: bundleIdentifier)
      }
    }
    storage[bundleIdentifier] = item
    DispatchQueue.main.asyncAfter(
      deadline: .now() + (afterMinutes * 60), execute: item)
  }

  private func scheduleActiveReauthentication(for bundleIdentifier: String) {
    cancelActiveReauthentication(for: bundleIdentifier)
    guard settings.activeReauthenticationMinutes > 0 else { return }
    let item = DispatchWorkItem { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.runningApplication(for: bundleIdentifier)?.isActive == true else { return }
        self.expireSession(for: bundleIdentifier)
      }
    }
    activeReauthenticationWorkItems[bundleIdentifier] = item
    DispatchQueue.main.asyncAfter(
      deadline: .now() + (settings.activeReauthenticationMinutes * 60), execute: item)
  }

  private func expireSession(for bundleIdentifier: String) {
    cancelAutomaticRelocking(for: bundleIdentifier)
    endTrackingUnlockedApplication(bundleIdentifier)
    lockCoordinator.clearSession(for: bundleIdentifier)

    guard settings.protectionEnabled,
      let runningApplication = runningApplication(for: bundleIdentifier),
      runningApplication.isActive,
      WindowFrameResolver.primaryVisibleFrame(for: runningApplication) != nil,
      let protectedApp = protectedApplication(for: bundleIdentifier)
    else { return }
    lockCoordinator.lock(protectedApp, runningApplication: runningApplication)
  }

  private func cancelAutomaticRelocking(for bundleIdentifier: String) {
    cancelDeactivationRelock(for: bundleIdentifier)
    cancelWindowClosureRelock(for: bundleIdentifier)
    cancelActiveReauthentication(for: bundleIdentifier)
  }

  private func cancelDeactivationRelock(for bundleIdentifier: String) {
    deactivationRelockWorkItems.removeValue(forKey: bundleIdentifier)?.cancel()
  }

  private func cancelWindowClosureRelock(for bundleIdentifier: String) {
    windowClosureRelockWorkItems.removeValue(forKey: bundleIdentifier)?.cancel()
  }

  private func cancelActiveReauthentication(for bundleIdentifier: String) {
    activeReauthenticationWorkItems.removeValue(forKey: bundleIdentifier)?.cancel()
  }

  private func protectedApplication(for bundleIdentifier: String) -> ProtectedApplication? {
    protectedApps.applications.first { $0.bundleIdentifier == bundleIdentifier }
  }

  private func runningApplication(for bundleIdentifier: String) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleIdentifier }
  }
}

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
          self?.lockCoordinator.clearSession(for: bundleIdentifier)
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
          self?.lockCoordinator.clearSession(for: bundleIdentifier)
        }
      })

    isMonitoring = true
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

  private func handle(_ notification: Notification) {
    guard settings.protectionEnabled,
      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication,
      let bundleIdentifier = application.bundleIdentifier,
      let protectedApp = protectedApps.applications.first(where: {
        $0.bundleIdentifier == bundleIdentifier
      }),
      !lockCoordinator.isUnlocked(bundleIdentifier)
    else { return }

    lockCoordinator.lock(protectedApp, runningApplication: application)
  }
}

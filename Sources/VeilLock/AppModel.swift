import AppKit
import Combine
import LocalAuthentication
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import VeilLockCore

@MainActor
final class AppModel: ObservableObject {
  let protectedApps = ProtectedAppsStore()
  let settings = GuardSettings()
  let lockCoordinator = LockCoordinator()

  @Published var alert: AppAlert?
  @Published var configurationPasswordPrompt: ConfigurationPasswordPrompt?
  @Published var configurationPasswordSetup: ConfigurationPasswordSetup?
  @Published private(set) var monitorIsRunning = false

  private lazy var monitor = ApplicationMonitor(
    protectedApps: protectedApps,
    settings: settings,
    lockCoordinator: lockCoordinator
  )
  private var sleepObserver: NSObjectProtocol?
  private var wakeObserver: NSObjectProtocol?
  private var resignActiveObserver: NSObjectProtocol?
  private var configurationAuthenticator: TouchIDAuthenticator?
  private var pendingConfigurationAction: (reason: String, success: () -> Void)?

  init() {
    lockCoordinator.onApplicationUnlocked = { [weak self] bundleIdentifier in
      self?.monitor.didUnlockApplication(bundleIdentifier: bundleIdentifier)
    }
    installSessionObservers()
    DispatchQueue.main.async { [weak self] in
      self?.startProtection()
    }
  }

  deinit {
    if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    if let resignActiveObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(resignActiveObserver)
    }
  }

  var menuBarSymbol: String {
    settings.protectionEnabled ? "lock.shield.fill" : "lock.open"
  }

  func startProtection() {
    guard settings.protectionEnabled else { return }
    monitor.start()
    monitor.enforceExistingApplications()
    monitorIsRunning = true
  }

  func lockAllNow() {
    lockCoordinator.clearSessions()
    monitor.hideProtectedRunningApplications()
  }

  func chooseApplications() {
    authenticateForConfiguration(reason: "Authorize changes to protected applications") {
      [weak self] in
      self?.presentApplicationPicker()
    }
  }

  func remove(_ application: ProtectedApplication) {
    authenticateForConfiguration(reason: "Authorize removing a protected application") {
      [weak self] in
      self?.protectedApps.remove(application)
      self?.lockCoordinator.clearSession(for: application.bundleIdentifier)
      self?.monitor.removeProtection(for: application.bundleIdentifier)
    }
  }

  func updateLaunchAtLogin(_ enabled: Bool) {
    authenticateForConfiguration(reason: "Authorize changing launch at login") { [weak self] in
      guard let self else { return }
      do {
        try self.settings.setLaunchAtLogin(enabled)
      } catch {
        self.alert = AppAlert(
          title: "Could Not Update Login Item", message: error.localizedDescription)
      }
    }
  }

  func updateAutomaticRelocking(
    afterWindowClosesOrLeavesMinutes: Double,
    activeReauthenticationMinutes: Double
  ) {
    authenticateForConfiguration(reason: "Authorize changing automatic re-locking") {
      [weak self] in
      guard let self else { return }
      self.settings.setAutomaticRelocking(
        afterWindowClosesOrLeavesMinutes: afterWindowClosesOrLeavesMinutes,
        activeReauthenticationMinutes: activeReauthenticationMinutes
      )
      self.monitor.refreshAutomaticRelocking()
    }
  }

  func authenticateForConfiguration(reason: String, success: @escaping () -> Void) {
    authenticateWithTouchID(reason: reason, success: success)
  }

  func verifyConfigurationPassword(_ password: String) -> String? {
    guard let action = pendingConfigurationAction else { return nil }

    do {
      guard try ConfigurationPasswordStore.verify(password) else {
        return "That password is incorrect."
      }
      pendingConfigurationAction = nil
      configurationPasswordPrompt = nil
      action.success()
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  func cancelConfigurationPasswordPrompt() {
    pendingConfigurationAction = nil
    configurationPasswordPrompt = nil
  }

  func beginConfigurationPasswordSetup() {
    authenticateForConfiguration(reason: "Authorize setting a configuration password") {
      [weak self] in
      self?.configurationPasswordSetup = .set
    }
  }

  func saveConfigurationPassword(_ password: String, confirmation: String) -> String? {
    guard password == confirmation else { return "The passwords do not match." }
    do {
      try ConfigurationPasswordStore.save(password)
      settings.refreshConfigurationPasswordState()
      configurationPasswordSetup = nil
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  func cancelConfigurationPasswordSetup() {
    configurationPasswordSetup = nil
  }

  func removeConfigurationPassword() {
    authenticateForConfiguration(reason: "Authorize removing the configuration password") {
      [weak self] in
      guard let self else { return }
      do {
        try ConfigurationPasswordStore.remove()
        settings.refreshConfigurationPasswordState()
      } catch {
        alert = AppAlert(title: "Could Not Remove Password", message: error.localizedDescription)
      }
    }
  }

  private func authenticateWithTouchID(reason: String, success: @escaping () -> Void) {
    let authenticator = TouchIDAuthenticator()
    configurationAuthenticator = authenticator
    authenticator.authenticate(reason: reason) { [weak self] result in
      self?.configurationAuthenticator = nil
      switch result {
      case .success:
        success()
      case .failure(let error):
        if case .cancelled = error { return }
        if self?.settings.configurationPasswordIsSet == true {
          self?.pendingConfigurationAction = (reason, success)
          self?.configurationPasswordPrompt = ConfigurationPasswordPrompt(reason: reason)
          return
        }
        self?.alert = AppAlert(title: "Touch ID Required", message: error.localizedDescription)
      }
    }
  }

  private func presentApplicationPicker() {
    let panel = NSOpenPanel()
    panel.title = "Choose Applications to Protect"
    panel.message = "VeilLock will require Touch ID whenever a selected application becomes active."
    panel.prompt = "Add Applications"
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true

    panel.begin { [weak self] response in
      guard response == .OK, let self else { return }
      for url in panel.urls {
        do {
          try self.protectedApps.add(url: url)
        } catch {
          self.alert = AppAlert(
            title: "Could Not Add Application", message: error.localizedDescription)
          return
        }
      }
      self.monitor.enforceExistingApplications()
    }
  }

  private func installSessionObservers() {
    let center = NSWorkspace.shared.notificationCenter
    sleepObserver = center.addObserver(
      forName: NSWorkspace.screensDidSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.lockAllNow()
      }
    }
    wakeObserver = center.addObserver(
      forName: NSWorkspace.screensDidWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.lockAllNow()
      }
    }
    resignActiveObserver = center.addObserver(
      forName: NSWorkspace.sessionDidResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.lockAllNow()
      }
    }
  }
}

struct AppAlert: Identifiable {
  let title: String
  let message: String
  let id = UUID()
}

struct ConfigurationPasswordPrompt: Identifiable {
  let reason: String
  let id = UUID()
}

enum ConfigurationPasswordSetup: Identifiable {
  case set

  var id: String { "set" }
}

@MainActor
final class ProtectedAppsStore: ObservableObject {
  @Published private(set) var applications: [ProtectedApplication] = []

  private let defaultsKey = "VeilLock.protectedApplications"

  init() {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey),
      let stored = try? JSONDecoder().decode([ProtectedApplication].self, from: data)
    else {
      return
    }
    applications = stored.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  func contains(bundleIdentifier: String) -> Bool {
    applications.contains { $0.bundleIdentifier == bundleIdentifier }
  }

  func add(url: URL) throws {
    guard url.pathExtension.lowercased() == "app" else {
      throw ProtectedApplicationError.invalidApplication
    }
    guard let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier else {
      throw ProtectedApplicationError.missingBundleIdentifier
    }
    guard ProtectionPolicy.canProtect(bundleIdentifier: bundleIdentifier) else {
      throw ProtectedApplicationError.protectedSystemApplication
    }
    guard !contains(bundleIdentifier: bundleIdentifier) else {
      throw ProtectedApplicationError.duplicateApplication
    }

    let name =
      (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? url.deletingPathExtension().lastPathComponent
    applications.append(ProtectedApplication(bundleIdentifier: bundleIdentifier, displayName: name))
    applications.sort {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
    persist()
  }

  func remove(_ application: ProtectedApplication) {
    applications.removeAll { $0.bundleIdentifier == application.bundleIdentifier }
    persist()
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(applications) else { return }
    UserDefaults.standard.set(data, forKey: defaultsKey)
  }
}

@MainActor
final class GuardSettings: ObservableObject {
  @Published private(set) var protectionEnabled: Bool
  @Published private(set) var launchAtLogin: Bool
  @Published private(set) var configurationPasswordIsSet: Bool
  @Published private(set) var relockAfterWindowClosesOrLeavesMinutes: Double
  @Published private(set) var activeReauthenticationMinutes: Double

  private let protectionKey = "VeilLock.protectionEnabled"
  private let relockAfterWindowClosesOrLeavesKey = "VeilLock.relockAfterWindowClosesOrLeavesMinutes"
  private let activeReauthenticationKey = "VeilLock.activeReauthenticationMinutes"

  init() {
    if UserDefaults.standard.object(forKey: protectionKey) == nil {
      UserDefaults.standard.set(true, forKey: protectionKey)
    }
    protectionEnabled = UserDefaults.standard.bool(forKey: protectionKey)
    launchAtLogin = SMAppService.mainApp.status == .enabled
    configurationPasswordIsSet = ConfigurationPasswordStore.isConfigured
    relockAfterWindowClosesOrLeavesMinutes = Self.normalizedMinutes(
      UserDefaults.standard.double(forKey: relockAfterWindowClosesOrLeavesKey))
    activeReauthenticationMinutes = Self.normalizedMinutes(
      UserDefaults.standard.double(forKey: activeReauthenticationKey))
  }

  func setLaunchAtLogin(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
    launchAtLogin = SMAppService.mainApp.status == .enabled
  }

  func refreshConfigurationPasswordState() {
    configurationPasswordIsSet = ConfigurationPasswordStore.isConfigured
  }

  func setAutomaticRelocking(
    afterWindowClosesOrLeavesMinutes: Double,
    activeReauthenticationMinutes: Double
  ) {
    let relockDelay = Self.normalizedMinutes(afterWindowClosesOrLeavesMinutes)
    let activeInterval = Self.normalizedMinutes(activeReauthenticationMinutes)
    UserDefaults.standard.set(relockDelay, forKey: relockAfterWindowClosesOrLeavesKey)
    UserDefaults.standard.set(activeInterval, forKey: activeReauthenticationKey)
    relockAfterWindowClosesOrLeavesMinutes = relockDelay
    self.activeReauthenticationMinutes = activeInterval
  }

  private static func normalizedMinutes(_ value: Double) -> Double {
    min(max(value.rounded(), 0), 120)
  }
}

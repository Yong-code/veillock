import AppKit
import ServiceManagement
import SwiftUI
import VeilLockCore

private enum SidebarDestination: Hashable {
  case protectedApps
  case privacy
}

struct ContentView: View {
  @EnvironmentObject private var model: AppModel
  @State private var selection: SidebarDestination? = .protectedApps

  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        Section {
          NavigationLink(value: SidebarDestination.protectedApps) {
            Label("Protected Apps", systemImage: "lock.app.fill")
          }
          NavigationLink(value: SidebarDestination.privacy) {
            Label("Privacy & Safety", systemImage: "hand.raised.fill")
          }
        }

        Section("Protection") {
          Label(
            model.settings.protectionEnabled ? "Active" : "Paused",
            systemImage: model.settings.protectionEnabled ? "checkmark.seal.fill" : "pause.circle"
          )
          .foregroundStyle(model.settings.protectionEnabled ? .green : .secondary)
        }
      }
      .navigationTitle("VeilLock")
    } detail: {
      Group {
        switch selection ?? .protectedApps {
        case .protectedApps:
          ProtectedAppsView()
        case .privacy:
          PrivacySafetyView()
        }
      }
    }
    .alert(item: $model.alert) { alert in
      Alert(
        title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
    }
  }
}

struct ProtectedAppsView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 16) {
        Image(systemName: "lock.shield.fill")
          .font(.system(size: 32, weight: .semibold))
          .foregroundStyle(.indigo)
          .frame(width: 56, height: 56)
          .background(
            .indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

        VStack(alignment: .leading, spacing: 4) {
          Text("Protected Apps")
            .font(.system(size: 28, weight: .bold, design: .rounded))
          Text("Selected apps are hidden until Touch ID verifies you.")
            .foregroundStyle(.secondary)
        }

        Spacer()
      }
      .padding(.horizontal, 32)
      .padding(.top, 30)
      .padding(.bottom, 22)

      Divider()

      if model.protectedApps.applications.isEmpty {
        VStack(spacing: 14) {
          Image(systemName: "lock.open")
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(.secondary)
          Text("No Apps Protected")
            .font(.title3.weight(.semibold))
          Text("Add an app to require Touch ID whenever it becomes active.")
            .foregroundStyle(.secondary)
          Button("Add Application") {
            model.chooseApplications()
          }
          .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          Section {
            ForEach(model.protectedApps.applications) { application in
              ProtectedAppRow(application: application)
            }
          } header: {
            Text("\(model.protectedApps.applications.count) protected")
          } footer: {
            Text(
              "VeilLock relocks an app every time it leaves the foreground, after sleep, and after your Mac locks."
            )
          }
        }
        .listStyle(.inset)
      }

      Divider()

      HStack(spacing: 12) {
        Button {
          model.lockAllNow()
        } label: {
          Label("Lock All Now", systemImage: "lock.fill")
        }
        .buttonStyle(.bordered)

        Spacer()

        Button {
          model.chooseApplications()
        } label: {
          Label("Add Application", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
      }
      .padding(20)
    }
    .navigationTitle("Protected Apps")
  }
}

struct ProtectedAppRow: View {
  @EnvironmentObject private var model: AppModel
  let application: ProtectedApplication

  var body: some View {
    HStack(spacing: 12) {
      ApplicationIcon(bundleIdentifier: application.bundleIdentifier)
        .frame(width: 36, height: 36)

      VStack(alignment: .leading, spacing: 3) {
        Text(application.displayName)
          .font(.headline)
        Text(application.bundleIdentifier)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Label("Touch ID", systemImage: "touchid")
        .font(.caption)
        .foregroundStyle(.secondary)

      Button(role: .destructive) {
        model.remove(application)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Remove \(application.displayName) from protected apps")
    }
    .padding(.vertical, 4)
  }
}

struct ApplicationIcon: View {
  let bundleIdentifier: String

  var body: some View {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        .resizable()
        .interpolation(.high)
        .scaledToFit()
    } else {
      Image(systemName: "app.dashed")
        .foregroundStyle(.secondary)
    }
  }
}

struct PrivacySafetyView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        VStack(alignment: .leading, spacing: 7) {
          Text("Privacy & Safety")
            .font(.system(size: 28, weight: .bold, design: .rounded))
          Text("Built to reduce casual physical access without requesting unnecessary permissions.")
            .foregroundStyle(.secondary)
        }

        SafetyCard(
          title: "What VeilLock Uses",
          symbol: "checkmark.shield.fill",
          tint: .green,
          lines: [
            "Touch ID authentication through macOS LocalAuthentication.",
            "A local list of application bundle identifiers you choose.",
            "macOS launch and activation notifications.",
          ]
        )

        SafetyCard(
          title: "What VeilLock Does Not Use",
          symbol: "hand.raised.fill",
          tint: .indigo,
          lines: [
            "No network access, telemetry, accounts, or analytics.",
            "No administrator password, Accessibility access, Screen Recording, camera, or microphone.",
            "No inspection, upload, or indexing of app content.",
          ]
        )

        VStack(alignment: .leading, spacing: 14) {
          Text("Launch at Login")
            .font(.headline)
          Text("Start VeilLock when you sign in so selected apps are protected after a restart.")
            .foregroundStyle(.secondary)
          Toggle(
            "Launch VeilLock at login",
            isOn: Binding(
              get: { model.settings.launchAtLogin },
              set: { model.updateLaunchAtLogin($0) }
            ))
        }
        .padding(20)
        .background(
          Color(nsColor: .underPageBackgroundColor),
          in: RoundedRectangle(cornerRadius: 16, style: .continuous))

        VStack(alignment: .leading, spacing: 8) {
          Label("Important Limit", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.headline)
          Text(
            "macOS does not offer a public, system-level API for locking arbitrary apps. VeilLock hides a selected app and covers the screen after it launches or becomes active. It is a privacy layer for casual access, not a defense against an administrator or someone with control of your signed-in macOS account."
          )
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(
          .orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      }
      .padding(32)
    }
    .navigationTitle("Privacy & Safety")
  }
}

struct SafetyCard: View {
  let title: String
  let symbol: String
  let tint: Color
  let lines: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      Label(title, systemImage: symbol)
        .font(.headline)
        .foregroundStyle(tint)
      ForEach(lines, id: \.self) { line in
        Label(line, systemImage: "checkmark")
          .foregroundStyle(.secondary)
      }
    }
    .padding(20)
    .background(
      Color(nsColor: .underPageBackgroundColor),
      in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

struct MenuBarView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Protection Active", systemImage: "lock.shield.fill")
        .font(.headline)
        .foregroundStyle(.indigo)
      Text(
        "\(model.protectedApps.applications.count) app\(model.protectedApps.applications.count == 1 ? "" : "s") protected"
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Divider()

      Button("Lock All Now") {
        model.lockAllNow()
      }

      Button("Open VeilLock") {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
      }

      Divider()

      Button("Quit VeilLock") {
        NSApp.terminate(nil)
      }
    }
    .padding(12)
    .frame(width: 220)
  }
}

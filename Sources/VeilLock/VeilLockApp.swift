import AppKit
import SwiftUI

@main
struct VeilLockApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(model)
    }
    .defaultSize(width: 920, height: 640)
    .commands {
      CommandGroup(replacing: .newItem) {}
    }

    MenuBarExtra("VeilLock", systemImage: model.menuBarSymbol) {
      MenuBarView()
        .environmentObject(model)
    }
  }
}

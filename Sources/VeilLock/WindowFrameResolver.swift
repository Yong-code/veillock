import AppKit
import CoreGraphics

enum WindowFrameResolver {
  /// Returns the largest visible application window owned by the target process.
  /// This reads geometry only; it never captures or inspects window content.
  static func primaryVisibleFrame(for application: NSRunningApplication) -> CGRect? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    else { return nil }

    let candidates = windowList.compactMap { info -> CGRect? in
      guard
        let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        ownerPID == application.processIdentifier,
        (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        frame.width > 100,
        frame.height > 100
      else { return nil }

      let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
      return alpha > 0 ? frame : nil
    }

    // Some apps expose small child windows ahead of their main window. Ignore
    // screen-sized background windows when a regular app window is available,
    // then select the largest remaining window as the lock target.
    let regularCandidates = candidates.filter { !approximatelyCoversScreen($0) }
    let eligibleCandidates = regularCandidates.isEmpty ? candidates : regularCandidates
    return eligibleCandidates.max { area(of: $0) < area(of: $1) }
  }

  private static func area(of frame: CGRect) -> CGFloat {
    frame.width * frame.height
  }

  private static func approximatelyCoversScreen(_ frame: CGRect) -> Bool {
    NSScreen.screens.contains { screen in
      let screenArea = area(of: screen.frame)
      guard screenArea > 0 else { return false }
      let overlap = frame.intersection(screen.frame)
      return area(of: overlap) / screenArea >= 0.98
        && area(of: frame) / screenArea >= 0.98
    }
  }
}

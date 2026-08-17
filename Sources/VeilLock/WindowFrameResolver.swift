import AppKit
import CoreGraphics

enum WindowFrameResolver {
  /// Returns the frontmost visible window owned by the target process.
  /// This reads geometry only; it never captures or inspects window content.
  static func foremostVisibleFrame(for application: NSRunningApplication) -> CGRect? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    else { return nil }

    // CGWindowList is ordered from front to back. Taking only the first matching
    // window avoids treating helper or background windows from the same app as
    // additional lock targets.
    for info in windowList {
      guard
        let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        ownerPID == application.processIdentifier,
        (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        frame.width > 1,
        frame.height > 1
      else { continue }

      let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
      if alpha > 0 {
        return frame
      }
    }
    return nil
  }
}

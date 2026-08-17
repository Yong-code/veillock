import AppKit
import CoreGraphics

enum WindowFrameResolver {
  /// Returns only geometry owned by the target process. It does not capture or inspect window content.
  static func visibleFrames(for application: NSRunningApplication) -> [CGRect] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    else { return [] }

    let frames = windowList.compactMap { info -> CGRect? in
      guard
        let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        ownerPID == application.processIdentifier,
        (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        frame.width > 1,
        frame.height > 1
      else { return nil }

      let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
      return alpha > 0 ? frame : nil
    }

    var uniqueFrames: [CGRect] = []
    for frame in frames where !uniqueFrames.contains(where: { $0.equalTo(frame) }) {
      uniqueFrames.append(frame)
    }
    return uniqueFrames.sorted { ($0.width * $0.height) > ($1.width * $1.height) }
  }
}

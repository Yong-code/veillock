# VeilLock — Touch ID App Lock for macOS

> A privacy-first macOS app locker that hides selected apps until Touch ID verifies you.

VeilLock is a native Swift app for people who occasionally share a Mac but want selected apps to stay out of sight. Choose the apps you want to protect; when one launches or returns to the foreground, VeilLock hides it and presents a full-screen Touch ID gate.

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-000000?logo=apple&logoColor=white)
![Language](https://img.shields.io/badge/language-Swift-F05138?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-6B4EFF)
![Privacy](https://img.shields.io/badge/privacy-local--only-2E8B57)

## Why VeilLock

- **Touch ID, not a second password.** Uses macOS LocalAuthentication; your fingerprint data never reaches VeilLock.
- **Protect the apps you choose.** Add any ordinary macOS application from a native picker.
- **Relocks by default.** A protected app is relocked when it leaves the foreground, when it quits, and when your Mac sleeps or locks.
- **No invasive permissions.** No administrator privileges, Accessibility, Screen Recording, camera, microphone, input monitoring, or network access.
- **No telemetry.** VeilLock stores only the bundle identifiers and display names of the apps you select, locally in your user preferences.
- **Native macOS design.** SwiftUI, AppKit, system typography, dark-mode support, and a small menu-bar control.

## Important security boundary

macOS does **not** expose a public, system-level API for a third-party app to lock arbitrary apps before they run. VeilLock observes app launches and activations, immediately hides a selected app, and places an opaque full-screen gate above all displays.

That makes VeilLock appropriate for **casual physical privacy** when lending a Mac. It is not a defense against an administrator, malware, a person with control of your signed-in account, or direct access to files and notifications outside the protected app window. For a stronger boundary, use a separate macOS account and lock the Mac before handing it over.

## How it works

1. Add an app in **Protected Apps**. Configuration changes themselves require Touch ID.
2. VeilLock listens only for macOS application launch, activation, deactivation, and session notifications.
3. When a protected app becomes active, VeilLock hides it and shows opaque lock panels on every connected display.
4. Successful Touch ID authentication restores that app. Moving away from it relocks the session.

## Requirements

- macOS 13 Ventura or later
- A Mac with Touch ID enrolled for the current user
- Xcode Command Line Tools or Xcode, if building from source

## Build from source

```zsh
git clone https://github.com/Yong-code/veillock.git
cd veillock
swift test
zsh Scripts/build-app.sh
open dist/VeilLock.app
```

The build script creates an ad-hoc-signed local app bundle. It is deliberately **not** distributed as a release binary: a public binary should be Developer ID signed and Apple-notarized by its maintainer before people install it.

## Verify before publishing or sharing

```zsh
zsh Scripts/audit-public-release.sh
swift test
zsh Scripts/build-app.sh
codesign --verify --deep --strict dist/VeilLock.app
```

## Privacy design

| VeilLock uses | VeilLock does not use |
| --- | --- |
| LocalAuthentication for Touch ID | Network access, accounts, telemetry, or analytics |
| macOS app lifecycle notifications | Administrator privileges or a privileged helper |
| Local preferences for selected bundle IDs | Accessibility, Screen Recording, camera, microphone, or key logging |

## Contributing

Contributions are welcome. Keep the project local-only, dependency-free, and explicit about its security boundary. Please read [SECURITY.md](SECURITY.md) before reporting a vulnerability.

## License

MIT. See [LICENSE](LICENSE).

# Security Policy

## Scope

VeilLock is designed to reduce casual physical access to selected macOS apps. It does not claim to provide a system-level security boundary against administrators, malware, or a person who controls the signed-in macOS account.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for this repository. Do not post exploit details, screenshots of personal app content, device identifiers, or logs containing private data in a public issue.

## Security principles

- No network access, telemetry, analytics, accounts, or remote configuration.
- No administrator privileges, Accessibility permission, Screen Recording, camera, microphone, or input monitoring.
- No application-content inspection; only user-selected app bundle identifiers are stored locally.
- Touch ID is evaluated by macOS. VeilLock receives only an authentication result, never fingerprint data.

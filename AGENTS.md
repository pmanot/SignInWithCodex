# Repository Guidelines

## Structure

- `Sources/SignInWithCodex/` contains the package implementation.
- `Tests/SignInWithCodexTests/` contains package tests.
- `Demo/SignInWithCodexDemo/` contains the iOS demo source.
- `project.yml` defines the checked-in Xcode project.
- `COMPATIBILITY.md` records the upstream contract.

## Architecture

Keep OAuth, Keychain, model discovery, request creation, and SSE parsing inside the package.

Keep the demo focused on sign-in and text chat. Do not add Python, Rust, an XCFramework, tools, or an agent loop.

The ChatGPT subscription transport is not a stable public API. Compare the full transport path before compatibility changes.

## Security

Store OAuth credentials only in Keychain. Never log tokens, authorization callbacks, or account identifiers.

## Validation

Run package tests with this command:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift test
```

Build the iOS demo with this command:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project SignInWithCodexDemo.xcodeproj \
  -scheme SignInWithCodexDemo \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

# SignInWithCodex

SignInWithCodex is a Swift package for ChatGPT OAuth, Keychain storage, model discovery, and streamed Codex responses.

This package uses the ChatGPT subscription transport from the Codex CLI. It does not use the public OpenAI Responses API.

This transport is not a stable public API. See [`COMPATIBILITY.md`](COMPATIBILITY.md) for the pinned Codex revision and fallback model.

> ## Warning — read before shipping
>
> This package authenticates as the **Codex CLI**: it uses OpenAI's Codex OAuth client ID, sends the Codex `originator` and version headers, and calls the private `chatgpt.com/backend-api/codex` endpoints. It is not an OpenAI product and is not endorsed by OpenAI.
>
> - OpenAI's terms restrict how ChatGPT subscriptions may be used outside of OpenAI's own clients. Using this package may violate those terms. **Your users' ChatGPT accounts can be rate-limited, flagged, or banned.**
> - The transport can change or be blocked at any time without notice. Any release can stop working overnight.
>
> ## No guarantees
>
> This software is provided **"as is"**, without warranty of any kind, express or implied. The authors accept no liability for account actions, data loss, service interruption, or any other damages arising from its use. There is no commitment to maintain compatibility with future Codex revisions. Use at your own risk, and disclose this risk to your users.

## Add the package

Add this repository as a Swift package. Select the `SignInWithCodex` library product.

Enable local network access for OAuth callbacks:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

## Create a session

Keep one session for the application lifetime:

```swift
import SignInWithCodex
import SwiftUI

@main
struct ExampleApp: App {
    @StateObject private var codex = CodexSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(codex)
        }
    }
}
```

The session restores its Keychain credential. Its default service name derives from the application bundle identifier.

If several targets share credentials, pass a fixed service name:

```swift
let codex = CodexSession(keychainService: "com.example.app.codex")
```

## Present sign-in

Use the supplied button:

```swift
CodexSignInButton(session: codex)
```

For a custom button, use the supplied sheet modifier:

```swift
Button("Connect Codex") {
    codex.signIn()
}
.codexSignInSheet(session: codex)
```

## Stream a response

Stream a prompt with the default model:

```swift
Task {
    for try await event in codex.stream(prompt: "Explain this function") {
        switch event {
        case let .responseStarted(model):
            print("Model:", model)
        case let .textDelta(delta):
            output += delta
        case let .completed(response):
            print("Complete:", response.model)
        }
    }
}
```

`CodexRequest` also supports conversation history, exact model identifiers, custom instructions, and reasoning effort.

## Demo application

If `project.yml` changes, regenerate the project:

```bash
xcodegen generate
```

Open the demo project:

```bash
open SignInWithCodexDemo.xcodeproj
```

Select a code-sign team for a physical device. Run the `SignInWithCodexDemo` scheme.

## Security

The package stores OAuth credentials in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

Do NOT log `CodexCredential`, authorization callbacks, request headers, or response headers. These values can contain credentials or account identifiers.

Call `try session.signOut()` to remove the Keychain credential.

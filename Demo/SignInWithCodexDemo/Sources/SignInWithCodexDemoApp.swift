import SignInWithCodex
import SwiftUI

@main
struct SignInWithCodexDemoApp: App {
  @StateObject private var session = CodexSession()

  var body: some Scene {
    WindowGroup {
      ContentView(session: session)
    }
  }
}

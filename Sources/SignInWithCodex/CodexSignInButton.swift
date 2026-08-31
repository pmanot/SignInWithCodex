#if os(iOS)
  import SafariServices
  import SwiftUI

  public struct CodexSignInButton: View {
    @ObservedObject private var session: CodexSession
    private let preferredProvider: CodexLoginProvider?

    public init(
      session: CodexSession,
      preferredProvider: CodexLoginProvider? = nil
    ) {
      self.session = session
      self.preferredProvider = preferredProvider
    }

    public var body: some View {
      Button {
        session.signIn(preferredProvider: preferredProvider)
      } label: {
        HStack(spacing: 10) {
          if session.state == .preparingSignIn
            || session.state == .exchangingCode
          {
            ProgressView()
          }
          Text(title)
            .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(session.state != .signedOut)
      .codexSignInSheet(session: session)
    }

    private var title: String {
      switch session.state {
      case .signedOut:
        "Sign in with Codex"
      case .preparingSignIn, .awaitingCallback, .exchangingCode:
        "Complete Sign In"
      case .signedIn:
        "Signed In"
      }
    }
  }

  extension View {
    public func codexSignInSheet(session: CodexSession) -> some View {
      modifier(CodexSignInSheetModifier(session: session))
    }
  }

  private struct CodexSignInSheetModifier: ViewModifier {
    @ObservedObject var session: CodexSession

    func body(content: Content) -> some View {
      content.sheet(item: authorizationBinding) { authorization in
        SafariAuthorizationView(
          url: authorization.authorizationURL,
          onCancel: session.cancelSignIn
        )
        .ignoresSafeArea()
      }
    }

    private var authorizationBinding: Binding<CodexAuthorization?> {
      Binding(
        get: { session.authorization },
        set: { authorization in
          if authorization == nil, session.authorization != nil {
            session.cancelSignIn()
          }
        }
      )
    }
  }

  private struct SafariAuthorizationView: UIViewControllerRepresentable {
    let url: URL
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
      Coordinator(onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
      let configuration = SFSafariViewController.Configuration()
      configuration.entersReaderIfAvailable = false
      let controller = SFSafariViewController(url: url, configuration: configuration)
      controller.delegate = context.coordinator
      controller.dismissButtonStyle = .cancel
      return controller
    }

    func updateUIViewController(
      _ viewController: SFSafariViewController,
      context: Context
    ) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
      private let onCancel: () -> Void

      init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
      }

      func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        onCancel()
      }
    }
  }
#endif

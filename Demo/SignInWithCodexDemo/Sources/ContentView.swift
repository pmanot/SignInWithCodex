import SignInWithCodex
import SwiftUI

struct ContentView: View {
  @ObservedObject var session: CodexSession

  @State private var messages: [DemoMessage] = []
  @State private var draft = ""
  @State private var activeModel: String?
  @State private var requestError: String?
  @State private var isSending = false

  var body: some View {
    NavigationStack {
      Group {
        if session.isSignedIn {
          chatView
        } else {
          signInView
        }
      }
      .navigationTitle("Codex")
      .toolbar {
        if session.isSignedIn {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Sign Out", action: signOut)
          }
        }
      }
    }
  }

  private var signInView: some View {
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: "chevron.left.forwardslash.chevron.right")
        .font(.system(size: 54, weight: .semibold))
        .foregroundStyle(.tint)

      VStack(spacing: 8) {
        Text("Sign In with Codex")
          .font(.largeTitle)
          .fontWeight(.bold)
        Text("Authenticate with ChatGPT, then stream a reply from the latest Codex model.")
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
      }

      CodexSignInButton(session: session)
        .frame(maxWidth: 360)

      if let error = session.lastErrorMessage {
        Text(error)
          .font(.footnote)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
      }

      Spacer()
    }
    .padding(28)
  }

  private var chatView: some View {
    VStack(spacing: 0) {
      accountBar
      Divider()

      ScrollView {
        LazyVStack(spacing: 14) {
          if messages.isEmpty {
            ContentUnavailableView(
              "Start a conversation",
              systemImage: "text.bubble",
              description: Text("The package selects the latest available model.")
            )
            .padding(.top, 72)
          }

          ForEach(messages) { message in
            messageBubble(message)
          }

          if let requestError {
            Text(requestError)
              .font(.footnote)
              .foregroundStyle(.red)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding()
      }

      Divider()
      composer
    }
  }

  private var accountBar: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("Signed in")
          .font(.caption.weight(.semibold))
        if let planType = session.account?.planType {
          Text(planType.uppercased())
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      if let activeModel {
        Text(activeModel)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      } else {
        Text("Latest model")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 12) {
      TextField("Message Codex", text: $draft, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...5)
        .disabled(isSending)
        .onSubmit(send)

      Button(action: send) {
        if isSending {
          ProgressView()
        } else {
          Image(systemName: "arrow.up.circle.fill")
            .font(.title2)
        }
      }
      .disabled(!canSend)
      .accessibilityLabel("Send")
    }
    .padding()
  }

  private func messageBubble(_ message: DemoMessage) -> some View {
    HStack {
      if message.role == .assistant {
        bubble(message)
        Spacer(minLength: 44)
      } else {
        Spacer(minLength: 44)
        bubble(message)
      }
    }
  }

  private func bubble(_ message: DemoMessage) -> some View {
    Text(message.text.isEmpty ? "…" : message.text)
      .textSelection(.enabled)
      .padding(12)
      .background(
        message.role == .user
          ? Color.accentColor.opacity(0.16)
          : Color.secondary.opacity(0.12),
        in: RoundedRectangle(cornerRadius: 14)
      )
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var canSend: Bool {
    !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func send() {
    let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, !isSending else { return }

    let requestMessages =
      messages.compactMap(\.codexMessage)
      + [CodexMessage(role: .user, text: prompt)]
    let assistantID = UUID()
    messages.append(DemoMessage(role: .user, text: prompt))
    messages.append(DemoMessage(id: assistantID, role: .assistant, text: ""))
    draft = ""
    requestError = nil
    isSending = true

    Task {
      defer { isSending = false }
      do {
        let request = CodexRequest(messages: requestMessages)
        for try await event in session.stream(request) {
          switch event {
          case .responseStarted(let model):
            activeModel = model
          case .textDelta(let delta):
            append(delta, to: assistantID)
          case .completed(let response):
            activeModel = response.model
            replaceEmptyMessage(assistantID, with: response.text)
          }
        }
      } catch {
        requestError = error.localizedDescription
        removeEmptyMessage(assistantID)
      }
    }
  }

  private func append(_ text: String, to id: UUID) {
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[index].text += text
  }

  private func replaceEmptyMessage(_ id: UUID, with text: String) {
    guard let index = messages.firstIndex(where: { $0.id == id }),
      messages[index].text.isEmpty
    else {
      return
    }
    messages[index].text = text
  }

  private func removeEmptyMessage(_ id: UUID) {
    messages.removeAll { $0.id == id && $0.text.isEmpty }
  }

  private func signOut() {
    do {
      try session.signOut()
      messages = []
      activeModel = nil
      requestError = nil
    } catch {
      requestError = error.localizedDescription
    }
  }
}

private struct DemoMessage: Identifiable, Equatable {
  enum Role {
    case user
    case assistant
  }

  let id: UUID
  let role: Role
  var text: String

  init(id: UUID = UUID(), role: Role, text: String) {
    self.id = id
    self.role = role
    self.text = text
  }

  var codexMessage: CodexMessage? {
    guard !text.isEmpty else { return nil }
    return CodexMessage(
      id: id,
      role: role == .user ? .user : .assistant,
      text: text
    )
  }
}

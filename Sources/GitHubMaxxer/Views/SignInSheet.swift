import AppKit
import SwiftUI

struct SignInSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  let connection: AccountConnection
  @State private var code: String?
  @State private var step = Step.code
  @State private var error: String?
  @State private var signIn: Task<Void, Never>?

  private enum Step: Int, CaseIterable {
    case code, approve, access

    var title: String {
      switch self {
      case .code: "Code copied"
      case .approve: "Paste it on GitHub and approve GitHub CLI"
      case .access: "Authorize any organization that uses single sign-on"
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Sign in to GitHub again").font(.title2.weight(.semibold))
        Text("@\(connection.profile.login)").foregroundStyle(.secondary)
      }
      HStack(spacing: 10) {
        let groups = code?.split(separator: "-").map(String.init) ?? ["····", "····"]
        CodeGroup(text: groups.first ?? "")
        Text("–").font(.readout(24)).foregroundStyle(.tertiary)
        CodeGroup(text: groups.last ?? "")
      }
      .foregroundStyle(code == nil ? .tertiary : .primary)
      .frame(maxWidth: .infinity)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(code.map { "One-time code \($0)" } ?? "Waiting for a one-time code")
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Step.allCases, id: \.self) { row in
          StepRow(title: row.title, state: state(of: row))
        }
      }
      if let error {
        Text(error).font(.callout).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      HStack {
        Spacer()
        Button("Cancel") {
          signIn?.cancel()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        if error == nil {
          Button("Open GitHub") { openURL(GitHubCLI.deviceURL) }
            .buttonStyle(.prominent).keyboardShortcut(.defaultAction)
            .disabled(code == nil || step == .access)
        } else {
          Button("Try Again", action: start)
            .buttonStyle(.prominent).keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(28).frame(width: 420)
    .task { start() }
    .onDisappear { signIn?.cancel() }
    .interactiveDismissDisabled(signIn != nil)
  }

  private func state(of row: Step) -> StepRow.State {
    if row.rawValue < step.rawValue { return .done }
    guard row == step else { return .pending }
    return error == nil ? .active : .failed
  }

  private func start() {
    error = nil
    code = nil
    step = .code
    signIn = Task {
      do {
        let token = try await GitHubCLI.signIn(as: connection.profile.login) { shown in
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(shown, forType: .string)
          code = shown
          step = .approve
        }
        step = .access
        try await model.connect(token: token, replacing: connection.id)
        let hidden = model.hiddenOrganizations[connection.id, default: 0]
        if hidden == 0 {
          dismiss()
        } else {
          error =
            "GitHub still hides \(hidden == 1 ? "1 organization" : "\(hidden) organizations") from this sign-in. Try again, and click Authorize next to each organization when GitHub lists it."
        }
      } catch is CancellationError {
      } catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
      signIn = nil
    }
  }
}

private struct CodeGroup: View {
  let text: String

  var body: some View {
    Text(text).font(.readout(24)).tracking(4).textSelection(.enabled)
      .padding(.horizontal, 14).padding(.vertical, 8)
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
  }
}

private struct StepRow: View {
  enum State { case pending, active, done, failed }

  let title: String
  let state: State

  var body: some View {
    Label {
      Text(title).fontWeight(state == .active ? .medium : .regular)
        .foregroundStyle(state == .pending ? .secondary : .primary)
    } icon: {
      switch state {
      case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
      case .active: ProgressView().controlSize(.small)
      case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.reached)
      case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
      }
    }
    .font(.callout)
  }
}

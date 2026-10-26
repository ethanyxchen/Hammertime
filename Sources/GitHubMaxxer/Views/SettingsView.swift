import GitHubMaxxerCore
import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  let connect: (AccountConnection?) -> Void
  @State private var removing: AccountConnection?
  @State private var removalError: String?
  @AppStorage(Soundtrack.mutedKey) private var isSlamSoundMuted = false
  @Environment(\.appearsActive) private var appearsActive
  @State private var opensAtLogin = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        SettingsSection(
          "Daily merged PR targets",
          footer:
            "Set a target for Personal and each organisation, or 0 for none. All activity adds them together. Right-click Personal or an organisation in the sidebar to change its colour. Weekly and monthly targets follow the daily target: 5 days per week and 20 days per month. PRs count on their merge date, using your Mac's time zone. Weeks run Monday through Sunday. Each PR counts once across all connections."
        ) {
          ForEach(model.workspaces, id: \.self) { TargetRow(workspace: $0) }
          LabeledContent(ActivityFilter.all.title) {
            let total = model.goals(for: .all)
            Text("\(total.daily) a day · \(total.weekly) a week · \(total.monthly) a month")
              .monospacedDigit()
          }
        }
        SettingsSection(
          "GitHub connections",
          footer:
            "Connect personal and work accounts. Signing in to the same account again updates its credential and keeps your repository selections. Credentials are stored in macOS Keychain. Activity is saved locally so it stays available offline. Targets, colours, and repository selections sync through a secret gist on your first account."
        ) {
          ForEach(model.connections) { connection in
            VStack(alignment: .leading, spacing: 10) {
              HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                  .font(.title).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                  ConnectionNameField(connection: connection)
                  Link("@\(connection.profile.login)", destination: connection.profileURL)
                    .font(.callout)
                }
                Spacer()
                Menu {
                  Button("Reconnect…") { connect(connection) }
                  Divider()
                  Button("Disconnect…", role: .destructive) { removing = connection }
                } label: {
                  Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.isPreview)
                .accessibilityLabel("Manage \(connection.label)")
              }
              if let error = model.connectionErrors[connection.id] {
                Label(error, systemImage: "exclamationmark.circle")
                  .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
              }
            }
          }
        } accessory: {
          Button("Add GitHub Connection…", systemImage: "plus") { connect(nil) }
            .labelStyle(.iconOnly).buttonStyle(.accessoryBarAction)
            .help("Add GitHub Connection…")
            .disabled(model.isPreview)
        }
        SettingsSection(
          "Merge celebration",
          footer: "Play the hammer's impact and shatter sounds when a pull request merges."
        ) {
          LabeledContent("Sound") {
            Toggle(
              "Sound",
              isOn: Binding(get: { !isSlamSoundMuted }, set: { isSlamSoundMuted = !$0 })
            )
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
          }
        }
        SettingsSection("Login", footer: "Start Hammertime when you log in.") {
          LabeledContent("Open at login") {
            Toggle(
              "Open at login",
              isOn: Binding(
                get: { opensAtLogin },
                set: {
                  LoginItem.setEnabled($0)
                  opensAtLogin = LoginItem.isEnabled
                })
            )
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .disabled(model.isPreview)
          }
        }
        SettingsSection("Updates") {
          LabeledContent("Refresh", value: "Every minute while the app is running")
          LabeledContent("History", value: "Merged PRs from the last 90 days")
        }
      }
      .padding(20)
    }
    .onChange(of: appearsActive, initial: true) { opensAtLogin = LoginItem.isEnabled }
    .confirmationDialog(
      "Disconnect \(removing?.label ?? "GitHub")?",
      isPresented: Binding(
        get: { removing != nil }, set: { if !$0 { removing = nil } }
      ), titleVisibility: .visible
    ) {
      Button("Disconnect", role: .destructive) {
        if let removing {
          do { try model.remove(removing.id) } catch { removalError = error.localizedDescription }
        }
        removing = nil
      }
    } message: {
      Text("This removes the saved credential and activity for this connection from your Mac.")
    }
    .alert(
      "Could not disconnect",
      isPresented: Binding(
        get: { removalError != nil }, set: { if !$0 { removalError = nil } }
      )
    ) {
      Button("OK") { removalError = nil }
    } message: {
      Text(removalError ?? "")
    }
  }
}

private struct SettingsSection<Content: View, Accessory: View>: View {
  let title: String
  var footer: String?
  let content: Content
  let accessory: Accessory
  private let inset: CGFloat = 10

  init(
    _ title: String, footer: String? = nil, @ViewBuilder content: () -> Content,
    @ViewBuilder accessory: () -> Accessory = { EmptyView() }
  ) {
    self.title = title
    self.footer = footer
    self.content = content()
    self.accessory = accessory()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        accessory
      }
      .padding(.trailing, inset)
      VStack(alignment: .leading, spacing: 0) {
        Group(subviews: content) { rows in
          ForEach(rows) { row in
            if row.id != rows.first?.id { Divider() }
            row.padding(.vertical, 12)
          }
        }
      }
      .labeledContentStyle(SettingsRowStyle())
      .padding(.horizontal, inset)
      .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
      if let footer {
        Text(footer).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, inset)
      }
    }
  }
}

private struct SettingsRowStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack {
      configuration.label
      Spacer()
      configuration.content.foregroundStyle(.secondary)
    }
  }
}

private struct ConnectionNameField: View {
  @Environment(AppModel.self) private var model
  let connection: AccountConnection
  @State private var name: String
  @FocusState private var isFocused: Bool

  init(connection: AccountConnection) {
    self.connection = connection
    _name = State(initialValue: connection.label)
  }

  var body: some View {
    TextField("Connection name", text: $name)
      .labelsHidden().accessibilityLabel("Connection name")
      .textFieldStyle(.plain).font(.headline)
      .focused($isFocused)
      .onSubmit { model.rename(name, id: connection.id) }
      .onChange(of: isFocused) { _, focused in
        if !focused { model.rename(name, id: connection.id) }
      }
      .onDisappear { model.rename(name, id: connection.id) }
  }
}

private struct TargetRow: View {
  @Environment(AppModel.self) private var model
  let workspace: ActivityFilter
  @State private var text = ""
  @FocusState private var isFocused: Bool

  private var daily: Int { model.goals(for: workspace).daily }

  var body: some View {
    let label = "\(model.title(for: workspace)) daily target"
    HStack {
      RoundedRectangle(cornerRadius: 2).fill(Palette.colour(model.colour(for: workspace)))
        .frame(width: 10, height: 10).accessibilityHidden(true)
      Text(model.title(for: workspace))
      Spacer()
      TextField("Pull requests", text: $text)
        .labelsHidden().accessibilityLabel(label)
        .textFieldStyle(.plain)
        .multilineTextAlignment(.trailing).frame(width: 56)
        .monospacedDigit()
        .focused($isFocused)
        .onSubmit(commit)
        .onChange(of: isFocused) { _, focused in
          if !focused { commit() }
        }
        .onChange(of: daily, initial: true) { text = String(daily) }
        .onDisappear(perform: commit)
      Stepper(
        label,
        value: Binding(get: { daily }, set: { model.setDailyGoal($0, for: workspace) }),
        in: Goals.dailyRange
      )
      .labelsHidden().fixedSize()
      Text("PRs").foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
    }
  }

  private func commit() {
    if let value = Int(text.trimmingCharacters(in: .whitespaces)), value != daily {
      model.setDailyGoal(value, for: workspace)
    }
    text = String(daily)
  }
}

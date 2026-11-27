import GitHubMaxxerCore
import SwiftUI

enum SettingsPane: CaseIterable {
  case tracking, accounts, app

  var title: String {
    switch self {
    case .tracking: "Tracking"
    case .accounts: "Accounts"
    case .app: "App"
    }
  }

  var symbol: String {
    switch self {
    case .tracking: "chart.bar.xaxis"
    case .accounts: "person.crop.circle"
    case .app: "gearshape"
    }
  }
}

struct SettingsPanel: View {
  @Environment(AppModel.self) private var model
  let pane: SettingsPane
  let connect: (AccountConnection?) -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.2).ignoresSafeArea()
        .contentShape(.rect).onTapGesture(perform: close)
      VStack(spacing: 0) {
        HStack {
          Text("Settings").font(.headline)
          Spacer()
          Button("Close", systemImage: "xmark", action: close)
            .labelStyle(.iconOnly).buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        Divider()
        HStack(spacing: 0) {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases, id: \.self) { item in
              PaneRow(
                pane: item, isSelected: item == pane,
                needsAttention: item == .accounts && !model.notices.isEmpty
              ) { model.settingsPane = item }
            }
            Spacer()
          }
          .padding(10).frame(width: 180)
          Divider()
          ScrollView {
            SettingsView(pane: pane, connect: connect).padding(20)
          }
          .id(pane)
        }
      }
      .frame(width: 760, height: 540)
      .accessibilityAddTraits(.isModal)
      .background(.background, in: .rect(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
      .shadow(color: .black.opacity(0.2), radius: 30, y: 12)
    }
  }

  private func close() { model.settingsPane = nil }
}

private struct PaneRow: View {
  let pane: SettingsPane
  let isSelected: Bool
  let needsAttention: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      HStack(spacing: 8) {
        Image(systemName: pane.symbol).frame(width: 18)
        Text(pane.title)
        Spacer()
        if needsAttention {
          Circle().fill(.orange).frame(width: 7, height: 7).accessibilityLabel("Needs attention")
        }
      }
      .padding(.horizontal, 8).padding(.vertical, 6)
      .background(
        isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6)
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }
}

private struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(SoftwareUpdate.self) private var softwareUpdate
  let pane: SettingsPane
  let connect: (AccountConnection?) -> Void
  @State private var removing: AccountConnection?
  @State private var removalError: String?
  @AppStorage(Soundtrack.mutedKey) private var isSlamSoundMuted = false
  @Environment(\.appearsActive) private var appearsActive
  @State private var opensAtLogin = false

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      switch pane {
      case .tracking: tracking
      case .accounts: accounts
      case .app: app
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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

  @ViewBuilder private var tracking: some View {
    SettingsSection("Display") {
      SettingsToggle(
        "Show lines changed",
        isOn: Binding(get: { model.showsLineChanges }, set: { model.setShowsLineChanges($0) }))
      SettingsToggle(
        "Merge celebration sound",
        isOn: Binding(get: { !isSlamSoundMuted }, set: { isSlamSoundMuted = !$0 }))
    }
    SettingsSection("Targets") {
      SettingsToggle(
        "Use targets",
        isOn: Binding(get: { !model.countsOnly }, set: { model.setCountsOnly(!$0) }))
      if !model.countsOnly {
        ForEach(model.workspaces, id: \.self) { TargetRow(workspace: $0) }
        LabeledContent(ActivityFilter.all.title) {
          let total = model.goals(for: .all)
          Text("\(total.daily) a day · \(total.weekly) a week · \(total.monthly) a month")
            .monospacedDigit()
        }
      }
    }
  }

  @ViewBuilder private var accounts: some View {
    if !model.notices.isEmpty {
      SettingsSection("Needs attention") {
        ForEach(model.notices) { notice in
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
              Text(notice.title).fontWeight(.medium)
              Text(notice.detail).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            Spacer()
            if notice.signIn != nil {
              Button("Sign In Again") { model.show(notice) }
            }
          }
        }
      }
    }
    SettingsSection("GitHub accounts") {
      ForEach(model.connections) { connection in
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
      }
    } accessory: {
      Button("Add GitHub Connection…", systemImage: "plus") { connect(nil) }
        .labelStyle(.iconOnly).buttonStyle(.accessoryBarAction)
        .help("Add GitHub Connection…")
        .disabled(model.isPreview)
    }
    SettingsSection("Activity") {
      LabeledContent("Refresh", value: "Every minute while the app is running")
      LabeledContent("History", value: "Merged PRs from the last 90 days")
    }
  }

  @ViewBuilder private var app: some View {
    SettingsSection("Startup and sync") {
      SettingsToggle(
        "Open at login",
        isOn: Binding(
          get: { opensAtLogin },
          set: {
            LoginItem.setEnabled($0)
            opensAtLogin = LoginItem.isEnabled
          })
      )
      .disabled(model.isPreview)
      SettingsToggle(
        "Sync settings with GitHub",
        isOn: Binding(get: { model.syncsSettings }, set: { model.setSyncsSettings($0) })
      )
      .disabled(model.isPreview)
    }
    SettingsSection("Software update") {
      SettingsToggle("Check automatically", isOn: Bindable(softwareUpdate).checksAutomatically)
        .disabled(model.isPreview)
      LabeledContent("Latest version") {
        Button("Check for Updates…") { softwareUpdate.check() }
          .disabled(!softwareUpdate.canCheck || model.isPreview)
      }
    }
  }
}

private struct SettingsSection<Content: View, Accessory: View>: View {
  let title: String
  let content: Content
  let accessory: Accessory
  private let inset: CGFloat = 10

  init(
    _ title: String, @ViewBuilder content: () -> Content,
    @ViewBuilder accessory: () -> Accessory = { EmptyView() }
  ) {
    self.title = title
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
    }
  }
}

private struct SettingsToggle: View {
  let title: String
  @Binding var isOn: Bool

  init(_ title: String, isOn: Binding<Bool>) {
    self.title = title
    _isOn = isOn
  }

  var body: some View {
    LabeledContent(title) {
      Toggle(title, isOn: $isOn)
        .labelsHidden().toggleStyle(.switch).controlSize(.small)
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

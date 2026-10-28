import GitHubMaxxerCore
import SwiftUI

enum Destination: Hashable {
  case activity(ActivityFilter)
  case repositories, settings

  var title: String {
    switch self {
    case .activity(let filter): filter.title
    case .repositories: "Repositories"
    case .settings: "Targets & Accounts"
    }
  }

  var symbol: String {
    switch self {
    case .activity(.all): "square.stack"
    case .activity(.personal): "person"
    case .activity(.organization): "building.2"
    case .repositories: "folder"
    case .settings: "slider.horizontal.3"
    }
  }

  func step(_ offset: Int, through activities: [ActivityFilter]) -> Destination {
    let all = activities.map(Destination.activity) + [.repositories, .settings]
    guard let index = all.firstIndex(of: self) else { return self }
    return all[(index + offset + all.count) % all.count]
  }
}

extension FocusedValues {
  @Entry var destination: Binding<Destination>?
  @Entry var searchFocus: FocusState<Bool>.Binding?
}

private struct Findable: ViewModifier {
  @FocusState private var isFocused: Bool

  func body(content: Content) -> some View {
    content.searchFocused($isFocused).focusedSceneValue(\.searchFocus, $isFocused)
  }
}

extension View {
  func findable() -> some View { modifier(Findable()) }
}

struct ConnectionDraft: Identifiable {
  let id = UUID()
  var existing: AccountConnection?
}

struct RootView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.appearsActive) private var appearsActive
  @State private var connectionDraft: ConnectionDraft?
  @State private var renaming: String?
  @State private var newName = ""
  @State private var showsShortcuts = false
  @State private var search = ""
  @AppStorage(LoginItem.offeredKey) private var hasOfferedLoginItem = false

  var body: some View {
    Group {
      if model.isWelcoming {
        WelcomeView { connectionDraft = ConnectionDraft() }
          .toolbar(removing: .title)
      } else {
        navigation
      }
    }
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .overlay { HammerSlam(landing: model.landing).ignoresSafeArea() }
    .sheet(item: $connectionDraft) { draft in
      ConnectionSheet(existing: draft.existing)
        .environment(model)
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await model.refresh() } }
    }
    .alert(
      "Rename \(renaming ?? "")",
      isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    ) {
      TextField("Name", text: $newName)
      Button("Rename") {
        if let renaming { model.renameOrganization(renaming, to: newName) }
      }
      .keyboardShortcut(.defaultAction)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The new name only appears in Hammertime.")
    }
    .alert(
      "Open Hammertime at login?",
      isPresented: Binding(
        get: {
          !hasOfferedLoginItem && !model.isWelcoming && !model.isPreview && !LoginItem.isEnabled
        },
        set: { if !$0 { hasOfferedLoginItem = true } })
    ) {
      Button("Open at Login") { LoginItem.setEnabled(true) }
        .keyboardShortcut(.defaultAction)
      Button("Not Now", role: .cancel) {}
    } message: {
      Text("You can change this anytime in Settings.")
    }
    .onChange(of: model.activities) { _, activities in
      if case .activity(let filter) = model.destination, !activities.contains(filter) {
        model.destination = .activity(.all)
      }
    }
    .onChange(of: appearsActive, initial: true) { _, active in model.setFocused(active) }
    .onDisappear { model.setFocused(false) }
    .frame(minWidth: 920, minHeight: 680)
  }

  private var navigation: some View {
    NavigationSplitView {
      List(selection: Bindable(model).destination) {
        section("Activity") {
          row(.activity(.all))
          if model.countsPersonal {
            row(.activity(.personal)).contextMenu { colourMenu(.personal) }
          }
          ForEach(model.sidebarOrganizations, id: \.self) { owner in
            row(.activity(.organization(owner))).contextMenu { organizationMenu(owner) }
          }
        }
        section("Manage") {
          row(.repositories)
        }
      }
      .scrollContentBackground(.hidden)
      .background(Palette.sidebar)
      .background(SidebarResizeBehavior())
      .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 270)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SidebarFooter(isSelected: model.destination == .settings) { model.destination = .settings }
      }
    } detail: {
      VStack(spacing: 0) {
        if model.isPreview {
          HStack {
            Label("Preview", systemImage: "eye")
            Text("Sample activity · no account connected").foregroundStyle(.secondary)
            Spacer()
          }
          .font(.caption).padding(.horizontal, 24).padding(.vertical, 8)
          .background(.quaternary)
        }
        if let error = model.errors.first {
          ErrorBanner(message: error, additionalCount: model.errors.count - 1)
        }
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .navigationTitle(title(for: model.destination))
      .toolbar(removing: .title)
      .toolbar {
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task { await model.refresh() }
          } label: {
            if model.isRefreshing {
              ProgressView().controlSize(.small)
            } else {
              Label("Refresh", systemImage: "arrow.clockwise")
            }
          }
          .keyboardShortcut("r", modifiers: .command)
          .disabled(model.isRefreshing || model.isConnecting || model.isPreview)
          .help(model.isRefreshing ? "Refreshing GitHub activity" : "Refresh GitHub activity (⌘R)")
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .searchable(text: $search, placement: .toolbar, prompt: searchPrompt)
    .findable()
    .onChange(of: model.destination) { search = "" }
    .focusedSceneValue(\.destination, Bindable(model).destination)
    .onModifierKeysChanged(mask: .command) { _, keys in showsShortcuts = keys.contains(.command) }
  }

  private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
    Section {
      rows()
    } header: {
      Eyebrow(title).padding(.horizontal, 10).listRowInsets(EdgeInsets())
    }
  }

  private func row(_ destination: Destination) -> some View {
    SidebarRow(
      symbol: symbol(for: destination), title: title(for: destination),
      tint: tint(for: destination),
      isPinned: isPinned(destination), shortcut: shortcut(for: destination),
      isSelected: model.destination == destination
    )
    .tag(destination)
    .listRowInsets(EdgeInsets())
    .listRowBackground(Palette.sidebar)
  }

  private var searchPrompt: String {
    model.destination == .repositories ? "Find a repository or owner" : "Search merges"
  }

  private func title(for destination: Destination) -> String {
    guard case .activity(let filter) = destination else { return destination.title }
    return model.title(for: filter)
  }

  private func symbol(for destination: Destination) -> String {
    guard case .activity(.organization(let owner)) = destination, model.isPerson(owner) else {
      return destination.symbol
    }
    return "person.circle"
  }

  private func tint(for destination: Destination) -> Color {
    guard case .activity(let filter) = destination, filter != .all else { return Palette.secondary }
    return Palette.colour(model.colour(for: filter))
  }

  private func shortcut(for destination: Destination) -> Int? {
    guard showsShortcuts, case .activity(let filter) = destination,
      let index = model.activities.firstIndex(of: filter), index < 9
    else { return nil }
    return index + 1
  }

  private func isPinned(_ destination: Destination) -> Bool {
    guard case .activity(.organization(let owner)) = destination else { return false }
    return model.isPinned(owner)
  }

  private func colourMenu(_ workspace: ActivityFilter) -> some View {
    Picker(
      "Colour",
      selection: Binding(
        get: { model.colour(for: workspace) },
        set: { if let colour = $0 { model.setColour(colour, for: workspace) } })
    ) {
      ForEach(WorkspaceColour.allCases) { colour in
        Label(colour.title, systemImage: "circle.fill").tint(Palette.colour(colour))
          .tag(Optional(colour))
      }
    }
    .pickerStyle(.palette)
  }

  @ViewBuilder
  private func organizationMenu(_ owner: String) -> some View {
    colourMenu(.organization(owner))
    Divider()
    Button(model.isPinned(owner) ? "Unpin" : "Pin to Top") {
      model.setPinned(!model.isPinned(owner), organization: owner)
    }
    Button("Rename…") {
      newName = model.displayName(for: owner)
      renaming = owner
    }
    if model.displayName(for: owner) != owner {
      Button("Reset Name") { model.renameOrganization(owner, to: "") }
    }
    Divider()
    Button(role: .destructive) {
      model.stopCounting(owner)
    } label: {
      Text("Stop Counting").foregroundStyle(.red)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.destination {
    case .activity(let filter):
      ActivityView(filter: filter, title: title(for: model.destination), search: search)
    case .repositories:
      VStack(spacing: 0) {
        PageTitle(title(for: model.destination)).padding([.horizontal, .top], 20)
        RepositoriesView(search: search)
      }
    case .settings:
      VStack(spacing: 0) {
        PageTitle(title(for: model.destination)).padding([.horizontal, .top], 20)
        SettingsView { existing in connectionDraft = ConnectionDraft(existing: existing) }
      }
    }
  }
}

private struct SidebarRow: View {
  let symbol: String
  let title: String
  let tint: Color
  let isPinned: Bool
  let shortcut: Int?
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .frame(width: 18)
        .foregroundStyle(isSelected ? Palette.panel : tint)
      Text(title).lineLimit(1)
      Spacer(minLength: 0)
      if isPinned {
        Image(systemName: "pin.fill").font(.system(size: 9))
          .foregroundStyle(isSelected ? Palette.panel : Palette.secondary)
          .accessibilityLabel("Pinned")
      }
      if let shortcut {
        Text("⌘\(shortcut)").font(.system(size: 11, design: .monospaced))
          .foregroundStyle(isSelected ? Palette.panel : Palette.secondary)
      }
    }
    .foregroundStyle(isSelected ? Palette.panel : Palette.ink)
    .fontWeight(isSelected ? .semibold : .regular)
    .padding(.horizontal, 10).frame(height: 30)
    .background(isSelected ? Palette.ink : .clear, in: RoundedRectangle(cornerRadius: 3))
    .contentShape(Rectangle())
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct SidebarFooter: View {
  @Environment(AppModel.self) private var model
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Lamp(isOn: model.errors.isEmpty && model.lastUpdated != nil)
          Text(
            model.connections.count == 1
              ? model.connections[0].label : "\(model.connections.count) accounts"
          )
          .fontWeight(.medium).lineLimit(1)
          Spacer(minLength: 0)
          Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.secondary)
        }
        Group {
          if !model.errors.isEmpty {
            Text("Needs attention")
          } else if let date = model.lastUpdated {
            Text(
              "Updated \(Text(.currentDate, format: .reference(to: date, allowedFields: [.minute, .hour, .day])))"
            )
          } else {
            Text("Updating…")
          }
        }
        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
        .padding(.leading, 15)
      }
      .padding(.horizontal, 20).padding(.vertical, 14)
      .background(Palette.ink.opacity(isSelected ? 0.1 : 0))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Targets & Accounts")
    .accessibilityLabel("Targets & Accounts")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .background(Palette.sidebar)
  }
}

private struct WelcomeView: View {
  let connect: () -> Void

  var body: some View {
    VStack(spacing: 22) {
      Image(nsImage: Bundle.main.image(forResource: "Hammer")!)
        .resizable()
        .frame(width: 96, height: 96)
      VStack(spacing: 9) {
        Text("Keep track of what you merge")
          .font(.system(size: 26, weight: .semibold))
        Text(
          "Set your PR targets and follow your GitHub activity,\nacross your personal projects and work repositories."
        )
        .foregroundStyle(.secondary).multilineTextAlignment(.center)
        .lineSpacing(4)
      }
      Button("Connect GitHub", action: connect)
        .buttonStyle(.prominent).controlSize(.large)
      Label("Your credentials stay in macOS Keychain", systemImage: "lock")
        .font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(40)
  }
}

struct ErrorBanner: View {
  let message: String
  var additionalCount = 0

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 4) {
        Text(message).font(.callout).textSelection(.enabled)
        if additionalCount > 0 {
          Text("\(additionalCount) more connections need attention in Targets & Accounts.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    .background(.orange.opacity(0.08))
  }
}

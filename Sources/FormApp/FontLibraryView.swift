import AppKit
import FormCore
import FormGraphics
import SwiftUI

/// A browsing session owns only its specimen and comparison settings. Font
/// assignment stays explicit and uses the selection captured before focus moves.
@MainActor final class FontBrowsingState: ObservableObject, Identifiable {
  let id = UUID()
  let context: FontSelectionContext
  let currentFace: String
  @Published var query = ""
  @Published var sample: String
  @Published var scope = FontBrowserScope.all
  @Published var category = FontBrowserCategory.all
  @Published var selectedFace: String
  @Published var highlighted: String?
  @Published var previewSize = 42.0
  @Published var previewInk = Color.black
  @Published var previewPaper = Color.white
  @Published var grid = true
  @Published var projectSaved: [String] = []
  @Published var projectUsed: [String] = []
  @Published var issue: String?
  var didApply = false

  init(session: ArtworkSession) {
    context = session.captureFontSelection()
    currentFace = FontLibraryCatalog.canonicalName(session.inspectedTypography.fontName)
    selectedFace = currentFace
    sample = context.previewText
    refreshProject(session)
  }
  func refreshProject(_ session: ArtworkSession) {
    projectSaved = session.projectFontNames
    projectUsed = session.projectUsedFontNames
  }
}

struct FontExplorer: View {
  @ObservedObject var session: ArtworkSession
  @ObservedObject var state: FontBrowsingState
  var onChoose: ((String) -> Void)?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    Group {
      if let store = session.store {
        FontLibraryContent(session: session, store: store, preferences: store.fontLibraryPreferences,
          state: state, expanded: true, onChoose: onChoose, onClose: { dismiss() })
      }
    }.frame(width: 980, height: 680).background(Palette.paper).labInterface()
  }
}

struct FontLibraryContent: View {
  @ObservedObject var session: ArtworkSession
  @ObservedObject var store: StudioStore
  @ObservedObject var preferences: FontLibraryPreferences
  @ObservedObject var state: FontBrowsingState
  let expanded: Bool
  var onChoose: ((String) -> Void)?
  let onClose: () -> Void
  var onExplore: (() -> Void)?
  @State private var showingUsage = false
  @State private var fontRevision = 0
  @FocusState private var searchFocused: Bool

  private var model: FontBrowserModel {
    _ = fontRevision
    let names = Set(state.projectSaved + state.projectUsed + preferences.favorites + preferences.recent + [state.currentFace])
    let aliases = Dictionary(uniqueKeysWithValues: names.compactMap { name -> (String, String)? in
      let resolved = FontLibraryCatalog.canonicalName(name)
      return resolved == name ? nil : (name, resolved)
    })
    return FontBrowserModel(faces: FontLibraryCatalog.faces, projectSaved: state.projectSaved,
      projectUsed: state.projectUsed, studioSaved: preferences.favorites, recent: preferences.recent,
      legacyStudioFamilies: preferences.legacyFamilies, aliases: aliases)
  }
  private var sections: [FontBrowserSection] {
    model.sections(scope: state.scope, category: state.category, query: state.query, currentFace: state.currentFace)
  }
  private var chosen: InstalledFontFace? { FontLibraryCatalog.face(named: state.selectedFace) }
  private var chosenFamily: InstalledFontFamily? { chosen.flatMap { FontLibraryCatalog.family(named: $0.family) } }
  private var allRows: [FontBrowserRow] { sections.flatMap(\.rows) }
  private var selectionIssue: String? {
    if onChoose != nil {
      return store.project?.id == state.context.projectID && store.artworkTransferProjectEpoch == state.context.projectEpoch
        ? nil : "The project changed. Reopen the font picker."
    }
    if state.context.sourceElements.isEmpty { return "Select text on the canvas to apply a font." }
    return session.fontSelectionUnavailableReason(context: state.context)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      if expanded {
        HStack(spacing: 0) {
          librarySidebar
          Divider()
          VStack(spacing: 0) { searchAndSpecimen; results }
        }
        explorerFooter
      } else {
        VStack(spacing: 9) { scopes; specimenField; categoryBar }.padding(.horizontal, 16).padding(.bottom, 8)
        results
        compactFooter
      }
      if let issue = state.issue ?? preferences.error {
        Text(issue).font(.system(size: 11)).foregroundStyle(Color.red).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }
    }.background(Palette.paper)
      .onAppear {
        state.refreshProject(session); searchFocused = true
        if !state.query.isEmpty { resetHighlight() }
      }
      .onChange(of: store.revision) { _, _ in state.refreshProject(session) }
      .onChange(of: state.query) { _, _ in resetHighlight() }
      .onChange(of: state.scope) { _, _ in resetHighlight() }
      .onChange(of: state.category) { _, _ in resetHighlight() }
      .onChange(of: state.sample) { _, value in
        if value.count > 128 { state.sample = String(value.prefix(128)) }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSFont.fontSetChangedNotification)) { _ in
        FontLibraryCatalog.invalidate(); fontRevision += 1
      }
      .onExitCommand(perform: onClose)
      .sheet(isPresented: $showingUsage) { DocumentFontsPanel(session: session) }
  }

  private var header: some View {
    HStack(spacing: 10) {
      if expanded {
        Text("Explore type").font(.system(size: 22, weight: .semibold))
        Spacer()
      } else { search }
      if !expanded, let onExplore {
        Button(action: onExplore) { Label("Explore", systemImage: "arrow.up.left.and.arrow.down.right") }
          .buttonStyle(FontQuietButtonStyle()).accessibilityIdentifier("font-browser-explore")
      }
      AppCloseButton(expanded ? "Close font exploration" : "Close fonts", keyEquivalent: "\u{1b}", action: onClose)
    }.padding(.horizontal, expanded ? 22 : 16).padding(.vertical, expanded ? 16 : 10)
  }
  private var search: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
      TextField("Search families or styles", text: $state.query).textFieldStyle(.plain)
        .focused($searchFocused).accessibilityLabel("Search fonts").accessibilityIdentifier("font-library-search")
        .onSubmit(activateHighlighted)
        .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in moveHighlight(-1); return .handled }
        .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in moveHighlight(1); return .handled }
      if !state.query.isEmpty {
        Button { state.query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
          .buttonStyle(.plain).foregroundStyle(Palette.secondary).accessibilityLabel("Clear font search")
      }
    }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 34)
      .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
  }
  private var specimenField: some View {
    HStack(spacing: 7) {
      Text("Aa").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.secondary)
      TextField("Type a phrase to preview", text: $state.sample).textFieldStyle(.plain)
        .font(.system(size: 12)).accessibilityLabel("Font preview text").accessibilityIdentifier("font-library-specimen")
      Button { state.sample = state.context.previewText } label: { Image(systemName: "arrow.counterclockwise") }
        .buttonStyle(.plain).foregroundStyle(Palette.secondary).help("Use the selected text")
        .accessibilityLabel("Reset preview to selected text")
    }.padding(.horizontal, 10).frame(height: 32)
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line).allowsHitTesting(false))
  }
  private var scopes: some View {
    HStack(spacing: 4) { ForEach(FontBrowserScope.allCases) { scope in scopeButton(scope, sidebar: false) } }
      .frame(maxWidth: .infinity)
  }
  private func scopeTitle(_ scope: FontBrowserScope) -> String {
    switch scope { case .all: return "All fonts"; case .project: return "Project"; case .studio: return "Favorites"; case .recent: return "Recent" }
  }
  private func scopeSymbol(_ scope: FontBrowserScope) -> String {
    switch scope { case .all: return "textformat"; case .project: return "folder"; case .studio: return "star"; case .recent: return "clock" }
  }
  private func scopeButton(_ scope: FontBrowserScope, sidebar: Bool) -> some View {
    Button { state.scope = scope } label: {
      HStack(spacing: 7) {
        if sidebar { Image(systemName: scopeSymbol(scope)).frame(width: 16) }
        Text(sidebar && scope == .studio ? "Studio favorites" : scopeTitle(scope))
        if sidebar { Spacer(minLength: 0) }
      }.font(.system(size: 11, weight: state.scope == scope ? .semibold : .regular))
        .frame(maxWidth: .infinity).padding(.horizontal, 9).frame(height: 30)
        .background(state.scope == scope ? Palette.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(state.scope == scope ? Palette.accent : Palette.secondary).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel(scope == .studio ? "Studio favorite fonts" : scopeTitle(scope))
      .accessibilityValue(state.scope == scope ? "Selected" : "")
      .accessibilityIdentifier("font-library-scope-" + scope.rawValue)
  }
  private var categoryBar: some View {
    HStack(spacing: 2) {
      ForEach(FontBrowserCategory.allCases) { category in
        Button { state.category = category } label: {
          Text(category.title).font(.system(size: 10, weight: state.category == category ? .semibold : .regular))
            .padding(.horizontal, 9).frame(height: 25)
            .background(state.category == category ? Palette.surface : Color.clear, in: Capsule())
            .foregroundStyle(state.category == category ? Palette.ink : Palette.secondary)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(category.title + " fonts")
          .accessibilityValue(state.category == category ? "Selected" : "")
          .accessibilityIdentifier("font-library-category-" + category.rawValue)
      }
      Spacer(minLength: 0)
    }
  }
  private var librarySidebar: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("LIBRARY").font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(Palette.secondary).padding(.horizontal, 9).padding(.bottom, 6)
      ForEach(FontBrowserScope.allCases) { scope in scopeButton(scope, sidebar: true) }
      Divider().padding(.vertical, 12)
      Text(store.project?.name ?? "No open project").font(.system(size: 12, weight: .medium)).lineLimit(3)
      Text("\(state.projectSaved.count) saved · \(state.projectUsed.count) used")
        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
      Text("Save faces to this project with the folder button. Stars stay in your Studio.")
        .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
      Spacer()
      if onChoose == nil { usageButton }
    }.padding(14).frame(width: 175).background(Palette.surface.opacity(0.5))
  }
  private var searchAndSpecimen: some View {
    VStack(spacing: 10) {
      HStack(spacing: 12) { specimenField; search.frame(width: 245) }
      HStack(spacing: 14) {
        categoryBar
        HStack(spacing: 5) {
          Text("Aa").font(.system(size: 11)).foregroundStyle(Palette.secondary)
          Slider(value: $state.previewSize, in: 20...80).frame(width: 84)
            .accessibilityLabel("Specimen size").accessibilityIdentifier("font-library-preview-size")
          Text("\(Int(state.previewSize))").font(.system(size: 10, design: .monospaced)).frame(width: 20)
        }
        ColorPicker("Specimen ink", selection: $state.previewInk, supportsOpacity: false).labelsHidden()
          .help("Specimen ink").accessibilityIdentifier("font-library-preview-ink")
        ColorPicker("Specimen background", selection: $state.previewPaper, supportsOpacity: false).labelsHidden()
          .help("Specimen background").accessibilityIdentifier("font-library-preview-paper")
        Menu {
          Button("Light") { state.previewPaper = .white; state.previewInk = .black }
          Button("Dark") { state.previewPaper = Color(white: 0.09); state.previewInk = .white }
          Button("Green") { state.previewPaper = Color(red: 0, green: 0.72, blue: 0.34); state.previewInk = .white }
        } label: { Image(systemName: "circle.lefthalf.filled") }.menuStyle(.borderlessButton).frame(width: 20)
          .help("Specimen color presets").accessibilityLabel("Specimen color presets")
        Button { state.grid.toggle() } label: {
          Image(systemName: state.grid ? "list.bullet" : "rectangle.grid.2x2").frame(width: 22, height: 26)
        }.buttonStyle(.plain).foregroundStyle(Palette.secondary)
          .help(state.grid ? "Wide specimens" : "Specimen grid")
          .accessibilityLabel(state.grid ? "Show wide font specimens" : "Show font specimen grid")
      }
    }.padding(.horizontal, 18).padding(.vertical, 12)
  }

  private var results: some View {
    let groups = sections
    let unavailable = model.unavailableFaces(scope: state.scope, query: state.query)
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: expanded ? 18 : 4) {
          if expanded && state.grid {
            HStack {
              Text(state.scope == .all ? "Project, Studio & installed fonts" : state.scope.title)
              Spacer()
              Text("\(groups.flatMap(\.rows).count) \(groups.flatMap(\.rows).count == 1 ? "family" : "families")")
            }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
              ForEach(groups.flatMap(\.rows)) { row in fontRow(row).id(row.id) }
            }
          } else {
            ForEach(groups) { section in
              VStack(alignment: .leading, spacing: expanded ? 10 : 3) {
              HStack {
                Text(section.title).font(.system(size: 10, weight: .medium))
                Spacer()
                Text("\(section.rows.count)").font(.system(size: 10, design: .monospaced))
              }.foregroundStyle(Palette.secondary).padding(.horizontal, expanded ? 2 : 10).padding(.vertical, 5)
                LazyVStack(spacing: 2) { ForEach(section.rows) { row in fontRow(row).id(row.id) } }
              }
            }
          }
          if !unavailable.isEmpty {
            Text("Unavailable on this Mac").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.secondary).padding(.top, 10)
            ForEach(unavailable, id: \.self) { name in
              HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.secondary)
                Text(name).font(.system(size: 12)).lineLimit(1)
                Spacer()
                if state.projectSaved.contains(name) {
                  Button("Remove saved face") { toggleProject(name) }
                    .buttonStyle(.borderless).font(.system(size: 10))
                }
                if preferences.favorites.contains(name) {
                  Button { preferences.toggle(name) } label: { Image(systemName: "star.fill") }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent).help("Remove Studio favorite")
                    .accessibilityLabel("Unfavorite " + name)
                }
              }.padding(8).help("The assignment is retained. Install this face to preview or apply it.")
            }
          }
          if groups.isEmpty && unavailable.isEmpty { emptyState }
        }.padding(.horizontal, expanded ? 18 : 10).padding(.bottom, 12)
      }.onChange(of: state.highlighted) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
    }
  }
  private func faceForRow(_ row: FontBrowserRow) -> InstalledFontFace {
    if expanded, state.highlighted == row.id, let chosen, chosen.family == row.family.name,
      chosen.matches(state.query), state.category.includes(chosen) { return chosen }
    return row.face
  }
  private func fontRow(_ row: FontBrowserRow) -> some View {
    let face = faceForRow(row)
    return FontSpecimenRow(face: face, family: row.family, sample: state.sample,
      size: expanded ? state.previewSize : 25, expanded: expanded,
      ink: expanded ? state.previewInk : Palette.ink, paper: expanded ? state.previewPaper : Palette.paper,
      selected: expanded ? chosen?.name == face.name : state.highlighted == row.id,
      applied: state.currentFace == face.name, favorite: preferences.favorite(face),
      projectSaved: session.isProjectFont(face.name), used: state.projectUsed.contains { FontLibraryCatalog.canonicalName($0) == face.name },
      onSelect: { select(face, family: row.id) },
      onFavorite: { preferences.toggle(face) },
      onProject: { toggleProject(face.name) },
      onStyle: { select($0, family: row.id) })
  }
  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: state.scope == .studio ? "star" : "textformat").font(.system(size: 25)).foregroundStyle(Palette.secondary)
      Text(emptyTitle).font(.system(size: 15, weight: .medium))
      Text(state.scope == .studio && state.query.isEmpty ? "Star a face while browsing. It will be here in every project." : state.scope == .project && state.query.isEmpty ? "Fonts used in your text and faces saved to this project appear here." : "Try another family, style, or category.")
        .font(.system(size: 12)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
      Button("Browse all fonts") { state.query = ""; state.category = .all; state.scope = .all }
        .buttonStyle(FontQuietButtonStyle())
    }.frame(maxWidth: .infinity).padding(.horizontal, 30).padding(.vertical, 36)
  }
  private var emptyTitle: String {
    guard state.query.isEmpty, state.category == .all else { return "No matching fonts" }
    switch state.scope {
    case .studio: return "No Studio favorites yet"
    case .project: return "No project fonts yet"
    case .recent: return "No recent fonts yet"
    case .all: return "No installed fonts"
    }
  }
  private var usageButton: some View {
    Button { showingUsage = true } label: { Label("Document fonts…", systemImage: "doc.text.magnifyingglass") }
      .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.secondary)
      .accessibilityIdentifier("font-library-document-usage")
  }
  private var compactFooter: some View {
    VStack(spacing: 0) {
      Divider()
      HStack {
        if onChoose == nil { usageButton }
        Spacer()
        Text("↑ ↓ browse  ·  ↵ apply").font(.system(size: 10)).foregroundStyle(Palette.secondary)
      }.padding(.horizontal, 16).padding(.vertical, 12)
    }
  }
  private var explorerFooter: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 14) {
        if let chosen, let family = chosenFamily {
          VStack(alignment: .leading, spacing: 3) {
            Text(family.name).font(.system(size: 13, weight: .semibold))
            Text("\(family.faces.count) \(family.faces.count == 1 ? "style" : "styles")").font(.system(size: 10)).foregroundStyle(Palette.secondary)
          }
          FontNativeStylePicker(faces: family.faces.filter { $0.name == state.selectedFace || $0.matches(state.query) && state.category.includes($0) },
            selected: $state.selectedFace, didSelect: { _ in state.highlighted = family.name }).frame(width: 175)
          Spacer()
          Text(selectionIssue ?? "Preview only until applied").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            .frame(maxWidth: 230, alignment: .trailing)
          FontPressable(title: onChoose == nil ? "Apply font" : "Choose font", identifier: "font-explorer-apply", action: { apply(chosen.name) }) {
            Text(onChoose == nil ? "Apply font" : "Choose font").font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.white).padding(.horizontal, 18).frame(height: 34)
              .background(Palette.accent, in: RoundedRectangle(cornerRadius: 8))
              .opacity(selectionIssue == nil ? 1 : 0.4)
          }
            .disabled(selectionIssue != nil)
        } else {
          Text("Choose a family to compare its styles.").foregroundStyle(Palette.secondary)
          Spacer()
        }
      }.padding(.horizontal, 22).padding(.vertical, 14).frame(minHeight: 64)
    }
  }
  private func resetHighlight() {
    let rows = allRows
    state.highlighted = rows.first?.id
    if expanded { state.selectedFace = rows.first?.face.name ?? "" }
  }
  private func moveHighlight(_ delta: Int) {
    let rows = allRows
    guard !rows.isEmpty else { return }
    let index = state.highlighted.flatMap { id in rows.firstIndex { $0.id == id } }
    let next = max(0, min(rows.count - 1, (index ?? (delta > 0 ? -1 : rows.count)) + delta))
    state.highlighted = rows[next].id
    if expanded { state.selectedFace = rows[next].face.name }
  }
  private func activateHighlighted() {
    guard let row = allRows.first(where: { $0.id == state.highlighted }) ?? allRows.first else { return }
    if expanded { state.selectedFace = row.face.name; state.highlighted = row.id } else { apply(row.face.name) }
  }
  private func select(_ face: InstalledFontFace, family: String) {
    state.highlighted = family; state.selectedFace = face.name
    if !expanded { apply(face.name) }
  }
  private func apply(_ name: String) {
    guard !state.didApply else { return }
    state.issue = nil
    if let selectionIssue { state.issue = selectionIssue; return }
    if let onChoose { onChoose(name) }
    else if !session.chooseFont(name, context: state.context) {
      state.issue = store.error ?? "The text selection changed. Close this view and choose your text again."
      return
    }
    state.didApply = true; onClose()
  }
  private func toggleProject(_ name: String) {
    guard store.project?.id == state.context.projectID, store.artworkTransferProjectEpoch == state.context.projectEpoch else {
      state.issue = "The project changed. Reopen the font library."; return
    }
    if !session.toggleProjectFont(name, projectID: state.context.projectID) { state.issue = store.error }
    state.refreshProject(session)
  }
}

struct FontQuietButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 6)
      .background(configuration.isPressed ? Palette.line : Palette.surface, in: RoundedRectangle(cornerRadius: 7))
      .foregroundStyle(Palette.ink)
  }
}

private struct FontSpecimenRow: View {
  let face: InstalledFontFace
  let family: InstalledFontFamily
  let sample: String
  let size: Double
  let expanded: Bool
  let ink: Color, paper: Color
  let selected: Bool, applied: Bool, favorite: Bool, projectSaved: Bool, used: Bool
  let onSelect: () -> Void, onFavorite: () -> Void, onProject: () -> Void
  let onStyle: (InstalledFontFace) -> Void
  @State private var hovered = false
  @State private var favoriteHovered = false
  @State private var projectHovered = false
  private var usesFallback: Bool {
    guard let font = FontLibraryCatalog.preview(face.name, size: size) else { return false }
    return FontLibraryCatalog.previewText(sample, font: font).usesFallback
  }
  var body: some View {
    VStack(alignment: .leading, spacing: expanded ? 0 : 3) {
      if expanded { metadata.padding(.horizontal, 12).padding(.top, 8) }
      HStack(spacing: 6) {
        FontPressable(title: "\(expanded ? "Preview" : "Apply") \(family.name), \(face.style)",
          identifier: "font-family-" + family.name, hover: { hovered = $0 }, action: onSelect) {
          VStack(alignment: .leading, spacing: 4) {
            specimen.frame(maxWidth: .infinity, alignment: .leading)
            if !expanded { compactMetadata }
          }.frame(maxWidth: .infinity, minHeight: expanded ? 116 : 55, alignment: .leading)
            .contentShape(Rectangle())
        }
        if !expanded { actions }
      }.padding(.horizontal, expanded ? 14 : 10).padding(.vertical, expanded ? 12 : 6)
    }.frame(height: expanded ? 176 : nil, alignment: .top)
      .background(paper, in: RoundedRectangle(cornerRadius: expanded ? 10 : 7))
      .overlay(RoundedRectangle(cornerRadius: expanded ? 10 : 7)
        .strokeBorder(selected ? Palette.accent : hovered ? Palette.line : expanded ? Palette.line.opacity(0.7) : .clear,
          lineWidth: selected ? 2 : 1).allowsHitTesting(false))
      .onHover { hovered = $0 }
      .contextMenu {
        Button(favorite ? "Remove Studio favorite" : "Favorite in Studio", action: onFavorite)
        Button(projectSaved ? "Remove from project fonts" : "Save to project fonts", action: onProject)
        Divider()
        ForEach(family.faces) { style in Button(style.style) { onStyle(style) } }
      }
  }
  @ViewBuilder private var specimen: some View {
    if let font = FontLibraryCatalog.preview(face.name, size: size) {
      let preview = FontLibraryCatalog.previewText(sample, font: font)
      Text(preview.text).font(Font(font)).foregroundStyle(ink).lineLimit(expanded ? 2 : 1)
        .frame(height: expanded ? 108 : 31, alignment: .leading).clipped()
        .help(preview.usesFallback ? "Some characters use a fallback font." : face.name)
    } else { Text("Unavailable").foregroundStyle(Palette.secondary) }
  }
  private var compactMetadata: some View {
    HStack(spacing: 5) {
      Text(family.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
      Text(face.style).font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(1)
      if usesFallback { Image(systemName: "exclamationmark.circle").font(.system(size: 9)).foregroundStyle(Palette.secondary).help("Some preview characters use a fallback font.") }
      if applied { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.accent) }
      if projectSaved { Image(systemName: "folder.fill").font(.system(size: 9)).foregroundStyle(Palette.secondary).help("Saved in this project") }
      Spacer(minLength: 0)
    }
  }
  private var metadata: some View {
    HStack(spacing: 4) {
      VStack(alignment: .leading, spacing: 3) {
        Text(family.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        Text(face.style + " · \(family.faces.count) \(family.faces.count == 1 ? "style" : "styles")" + (used ? " · In project" : "") + (usesFallback ? " · Fallback glyphs" : ""))
          .font(.system(size: 9)).lineLimit(1)
      }.foregroundStyle(ink.opacity(0.7))
      Spacer(minLength: 0)
      actions
    }
  }
  private var actions: some View {
    HStack(spacing: 0) {
      FontPressable(title: (favorite ? "Unfavorite " : "Favorite ") + face.name,
        identifier: "font-favorite-" + face.name, hover: { favoriteHovered = $0 }, action: onFavorite) {
          Image(systemName: favorite ? "star.fill" : "star").frame(width: 27, height: 28)
            .foregroundStyle(favorite ? Palette.accent : expanded ? ink.opacity(0.55) : Palette.secondary)
            .background(favoriteHovered ? ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.help(favorite ? "Remove Studio favorite" : "Favorite in Studio")
      if expanded {
        FontPressable(title: (projectSaved ? "Remove project font " : "Save project font ") + face.name,
          identifier: "font-project-" + face.name, hover: { projectHovered = $0 }, action: onProject) {
            Image(systemName: projectSaved ? "folder.fill" : "folder.badge.plus").frame(width: 27, height: 28)
              .foregroundStyle(projectSaved ? Palette.accent : ink.opacity(0.55))
              .background(projectHovered ? ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
          }.help(projectSaved ? "Remove from project fonts" : "Save to project fonts")
      } else {
        Menu {
          Button(projectSaved ? "Remove from project fonts" : "Save to project fonts", action: onProject)
          Divider()
          ForEach(family.faces) { style in
            Button { onStyle(style) } label: { Text(style.style + (style.name == face.name ? " ✓" : "")) }
          }
        } label: { Image(systemName: "chevron.down").font(.system(size: 9)).frame(width: 20, height: 28) }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          .help("\(family.faces.count) \(family.faces.count == 1 ? "style" : "styles") · save to project").accessibilityLabel("Styles and collection for " + family.name)
      }
    }
  }
}

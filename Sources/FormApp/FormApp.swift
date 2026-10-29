import AppKit
import FormCore
import FormGraphics
import SwiftUI

@main struct FormApplication: App {
  @NSApplicationDelegateAdaptor(FormAppDelegate.self) var delegate
  @StateObject var store = StudioStore.shared
  var body: some Scene {
    WindowGroup("LAB", id: "studio") {
      RootView().environmentObject(store)
        .frame(minWidth: store.surfaceLayout == .split && store.splitDirection == .sideBySide ? 1280 : 1020,
          minHeight: store.surfaceLayout == .split && store.splitDirection == .stacked ? 900 : 700)
        .preferredColorScheme(.light)
        .onAppear { delegate.store = store }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1440, height: 940)
    .commands {
      CommandGroup(replacing:.appInfo){
        Button("About LAB"){
          NSApp.orderFrontStandardAboutPanel(options:[.credits:NSAttributedString(string:"Exact geometry uses Open CASCADE Technology 8.0.1, licensed under LGPL 2.1 with the OCCT exception. Third-party notices include the exact corresponding source archive and rebuild instructions. 2D geometry uses Clipper2 (Boost 1.0) and Mapbox Earcut (ISC).")])
        }
        Button("Third-party notices…"){
          if let root=Bundle.main.resourceURL?.appendingPathComponent("ThirdPartyNotices"){NSWorkspace.shared.open(root)}
        }
      }
      CommandGroup(replacing: .newItem) {
        Button("New Project") { store.createProject() }.keyboardShortcut("n")
        Menu("New from Study") {
          ForEach(Samples.templates) { template in
            Button(template.title) { store.createProject(template: template.id) }
          }
        }
        Button("Open Project…") { store.openPackage() }.keyboardShortcut("o")
        Button("Import SVG Artwork…") { store.importSVGDialog() }.keyboardShortcut(
          "i", modifiers: [.command, .shift])
        Divider()
        Button("Show Home") { store.home() }.keyboardShortcut("h", modifiers: [.command, .shift])
      }
      CommandGroup(replacing: .saveItem) {
        Button("Save") {
          NSApp.keyWindow?.makeFirstResponder(nil)
          if store.environment == .studio,!store.studioShowingShots {
            store.studioComposition.save()
            guard store.studioComposition.error==nil else{return}
          }
          store.save()
          store.capturePreview()
          store.toast("All changes saved")
        }.keyboardShortcut("s").disabled(store.project == nil)
        Button("Save a Copy…") { store.saveCopy() }.keyboardShortcut(
          "s", modifiers: [.command, .shift]
        ).disabled(store.project == nil)
      }
      CommandGroup(replacing: .undoRedo) {
        Button("Undo") { store.undo() }.keyboardShortcut("z").disabled(
          store.artworkSession.editingText
            ? store.artworkSession.canvas?.canUndoText != true : store.engine.undoStack.isEmpty && !(store.environment == .studio && !store.studioShowingShots && store.studioComposition.canUndoDraft))
        Button("Redo") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
          .disabled(
            store.artworkSession.editingText
              ? store.artworkSession.canvas?.canRedoText != true : store.engine.redoStack.isEmpty && !(store.environment == .studio && !store.studioShowingShots && store.studioComposition.canRedoDraft))
      }
      CommandGroup(replacing: .printItem) {
        Button("Print…") { store.prepareSelectedPrint() }.keyboardShortcut("p").disabled(
          store.project?.objects.isEmpty != false)
      }
      CommandMenu("Object") {
        Button("New Exact CAD Model…"){store.cad.openEditor()}.disabled(store.project==nil)
        Button("Import 3D Model…"){store.modelAssets.openImport()}.disabled(store.project==nil)
        Button("Import Exact STEP / BRep…"){store.cad.openImport()}.disabled(store.project==nil)
        Divider()
        ForEach(Recipe.builtins.filter { $0.id != "reference" && $0.id != "patternAssembly" && !["importedMesh","cadModel"].contains($0.id) }) { recipe in
          Button("Add \(recipe.name)") {
            if store.project == nil { store.createProject() }
            store.add(recipe)
          }
        }
        Divider()
        Button("Duplicate as Iteration") { store.duplicate("iteration") }.keyboardShortcut("d")
          .disabled(
            store.mode == .artwork ? store.artworkSession.selection.isEmpty : store.primary == nil)
        Button("Create Linked Variant") { store.duplicate("variant") }.keyboardShortcut(
          "d", modifiers: [.command, .shift]
        ).disabled(
          store.mode == .artwork ? store.artworkSession.selection.isEmpty : store.primary == nil)
        Button("Group Selection") { store.group() }.keyboardShortcut("g").disabled(
          store.mode == .artwork
            ? store.artworkSession.selection.count < 2 : store.selected.count < 2)
        Button("Delete") { store.deleteSelection() }
          .disabled(store.mode == .artwork ? store.artworkSession.selection.isEmpty : store.selected.isEmpty)
      }
      CommandGroup(after: .toolbar) {
        Button("Fit All Objects") {
          if store.mode == .artwork { store.artworkSession.fit() } else { store.scene?.fitAll() }
        }.keyboardShortcut("0")
        Button("Focus Selection") { store.scene?.focusSelection() }
        Button(store.isolated.isEmpty ? "Isolate Selection" : "Show All Objects") {
          store.isolate()
        }
        Divider()
        Button("Perspective") { store.scene?.preset("perspective") }
        Button("Top") { store.scene?.preset("overhead") }
        Button("Front") { store.scene?.preset("front") }
        Toggle("Show Grid", isOn: $store.showGrid)
      }
      CommandMenu("Artwork") {
        Button("New Artwork Frame") {
          if store.project == nil { store.createProject() }
          store.artworkSession.createFrame(width: 203.2, height: 254, name: "Untitled artwork")
        }.keyboardShortcut("n", modifiers: [.command, .option])
        Divider()
        Button("Ungroup") { store.artworkSession.execute("ungroup") }.keyboardShortcut(
          "g", modifiers: [.command, .shift]
        ).disabled(store.mode != .artwork)
        Button("Convert Text to Outlines") {
          store.artworkSession.canvas?.finishText()
          store.artworkSession.convert()
        }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(store.mode != .artwork)
        Button("Outline Stroke") { store.artworkSession.convert("stroke") }.disabled(
          store.mode != .artwork)
        Button("Convert Shapes to Paths") { store.artworkSession.convert("shape") }.disabled(
          store.mode != .artwork)
        Divider()
        Button("Make Compound Path") { store.artworkSession.editPath("combine") }
          .keyboardShortcut("8").disabled(
            store.mode != .artwork || store.artworkSession.selection.count < 2)
        Button("Release Compound Path") { store.artworkSession.editPath("release") }
          .keyboardShortcut("8", modifiers: [.command, .option]).disabled(store.mode != .artwork)
        Button("Join Selected Endpoints") { store.artworkSession.editPath("join") }
          .keyboardShortcut("j").disabled(
            store.mode != .artwork || store.artworkSession.nodes.count != 2)
        Divider()
        Menu("Live Boolean") {
          ForEach(BooleanCommands.operations, id: \.self) { operation in
            Button(operation.capitalized) { store.artworkSession.boolean(operation) }
          }
          Divider()
          Button("Divide into Editable Regions") {
            store.artworkSession.boolean("union", mode: "divide")
          }
        }.disabled(store.mode != .artwork || store.artworkSession.selection.count < 2)
        Button("Flatten Boolean Result") { store.artworkSession.boolean("union", mode: "flatten") }
          .disabled(
            store.mode != .artwork || store.artworkSession.elements.count != 1
              || store.artworkSession.primary?.booleanOperation == nil)
        Divider()
        Button("Create Component from Selection") { store.artworkSession.component("create") }
          .keyboardShortcut("k", modifiers: [.command, .option])
          .disabled(store.mode != .artwork || store.artworkSession.selection.isEmpty)
        Menu("Insert Component") {
          ForEach(store.project?.artworkComponents ?? []) { source in
            Button(source.name) {
              store.artworkSession.component("insert", ["source_object_id": source.id.uuidString])
            }.disabled(source.id == store.artworkSession.objectID)
          }
        }.disabled(store.mode != .artwork || store.project?.artworkComponents.isEmpty != false)
        Button("Detach Component Instance") { store.artworkSession.component("detach") }
          .disabled(store.mode != .artwork || store.artworkSession.primary?.component == nil)
        Divider()
        Button("Show / Hide Guides") {
          store.artworkSession.mutate { $0.showGuides = !($0.showGuides ?? true) }
        }.keyboardShortcut(";").disabled(store.mode != .artwork)
        Button("Show / Hide Artwork Grid") {
          store.artworkSession.mutate { $0.showGrid = !($0.showGrid ?? false) }
        }.keyboardShortcut("'").disabled(store.mode != .artwork)
      }
      CommandMenu("Environment") {
        ForEach(ProjectEnvironment.primary) { environment in
          Button(environment.title) { store.showEnvironment(environment) }.disabled(store.project == nil)
        }
        Divider()
        Button("Canvas") { store.showSurface(.artwork) }.disabled(store.project == nil)
        Button("Table") { store.showSurface(.table) }.disabled(store.project == nil)
        Button("Split Side by Side") { store.showSplit(.sideBySide) }.disabled(store.project == nil)
        Button("Split Stacked") { store.showSplit(.stacked) }.disabled(store.project == nil)
        Button("Flip Split Direction") {
          store.showSplit(store.splitDirection == .sideBySide ? .stacked : .sideBySide)
        }.disabled(store.project == nil || store.surfaceLayout != .split)
        Button("Open Canvas Window") { store.detachCanvas() }.disabled(store.project == nil)
      }
      CommandMenu("Studio") {
        Button("Show Studio") { store.showEnvironment(.studio) }.disabled(store.project == nil)
        Divider()
        Button("Document Fonts…") {store.showingDocumentFonts=true}.disabled(store.project==nil)
        Button("Materials & Equipment") { store.showingLibrary = true }
        Button("Codex Connection") { store.showingBridge = true }
        Divider()
        Button("Export Studio Image…") { store.exportDialog("png") }.disabled(store.project == nil)
        Button("Export Artwork PDF…") { store.exportDialog("pdf") }.disabled(store.primary == nil)
        Button("Export Cut Profile SVG…") { store.exportDialog("svg") }.disabled(
          !["sleeve", "clock"].contains(store.primary?.recipeID ?? ""))
        Button("Export Component Summary…") { store.exportDialog("json") }.disabled(
          store.project == nil)
      }
    }
    Settings { AppearanceSettingsView(appearance: .shared, store: store) }
  }
}

final class FormAppDelegate: NSObject, NSApplicationDelegate {
  weak var store: StudioStore?
  func applicationDidFinishLaunching(_ notification: Notification) {
    NotificationCenter.default.addObserver(
      forName: NSFont.fontSetChangedNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        TypographyEngine.invalidateFonts()
        GeometryFactory.invalidateFontResources()
        self?.store?.changed(save: false)
      }
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      self?.store?.startBridge()
      self?.store?.generateMissingPreviews()
    }
  }
  func applicationWillTerminate(_ notification: Notification) {
    store?.save()
    store?.capturePreview()
    store?.bridge.stop()
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    for path in filenames where path.hasSuffix(".form") {
      store?.importPackage(URL(fileURLWithPath: path))
    }
  }
}

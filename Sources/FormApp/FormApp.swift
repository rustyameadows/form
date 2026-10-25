import AppKit
import FormCore
import FormGraphics
import SwiftUI

@main struct FormApplication: App {
  @NSApplicationDelegateAdaptor(FormAppDelegate.self) var delegate
  @StateObject var store = StudioStore.shared
  var body: some Scene {
    WindowGroup("FORM", id: "studio") {
      RootView().environmentObject(store)
        .frame(minWidth: 1020, minHeight: 700)
        .preferredColorScheme(.light)
        .onAppear { delegate.store = store }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1440, height: 940)
    .commands {
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
            ? store.artworkSession.canvas?.canUndoText != true : store.engine.undoStack.isEmpty)
        Button("Redo") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
          .disabled(
            store.artworkSession.editingText
              ? store.artworkSession.canvas?.canRedoText != true : store.engine.redoStack.isEmpty)
      }
      CommandGroup(replacing: .printItem) {
        Button("Print…") { store.printing.open() }.keyboardShortcut("p").disabled(
          store.project?.objects.isEmpty != false)
      }
      CommandMenu("Object") {
        ForEach(Recipe.builtins.filter { $0.id != "reference" }) { recipe in
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
          .disabled(store.selected.isEmpty)
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
        Button("Overhead") { store.scene?.preset("overhead") }
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
        Divider()
        Button("Show / Hide Guides") {
          store.artworkSession.mutate { $0.showGuides = !($0.showGuides ?? true) }
        }.keyboardShortcut(";").disabled(store.mode != .artwork)
        Button("Show / Hide Artwork Grid") {
          store.artworkSession.mutate { $0.showGrid = !($0.showGrid ?? false) }
        }.keyboardShortcut("'").disabled(store.mode != .artwork)
      }
      CommandMenu("Studio") {
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

import AppKit
import FormCore
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
        Button("Open Project…") { store.openPackage() }.keyboardShortcut("o")
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
          store.engine.undoStack.isEmpty)
        Button("Redo") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
          .disabled(store.engine.redoStack.isEmpty)
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
          .disabled(store.primary == nil)
        Button("Create Linked Variant") { store.duplicate("variant") }.keyboardShortcut(
          "d", modifiers: [.command, .shift]
        ).disabled(store.primary == nil)
        Button("Group Selection") { store.group() }.keyboardShortcut("g").disabled(
          store.selected.count < 2)
        Button("Delete") { store.deleteSelection() }
          .disabled(store.selected.isEmpty)
      }
      CommandGroup(after: .toolbar) {
        Button("Fit All Objects") { store.scene?.fitAll() }.keyboardShortcut("0")
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
      CommandMenu("Studio") {
        Button("Materials & Equipment") { store.showingLibrary = true }
        Button("Codex Connection") { store.showingBridge = true }
        Divider()
        Button("Export Studio Image…") { store.exportDialog("png") }.disabled(store.project == nil)
        Button("Export Artwork PDF…") { store.exportDialog("pdf") }.disabled(store.primary == nil)
        Button("Export Dieline SVG…") { store.exportDialog("svg") }.disabled(
          store.primary?.recipeID != "sleeve")
        Button("Export Component Summary…") { store.exportDialog("json") }.disabled(
          store.project == nil)
      }
    }
  }
}

final class FormAppDelegate: NSObject, NSApplicationDelegate {
  weak var store: StudioStore?
  func applicationDidFinishLaunching(_ notification: Notification) {
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

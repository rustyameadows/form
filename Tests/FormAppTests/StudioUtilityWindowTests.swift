import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class StudioUtilityWindowTests: XCTestCase {
  private func fixture() throws -> StudioStore {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lab-utility-window-tests-" + UUID().uuidString)
    let repository = try ProjectRepository(root: root), project = Project(name: "First notebook")
    try repository.save(project)
    let store = StudioStore(repository: repository, seedLibrary: false)
    try store.engine.open(project.id); store.showingHome = false
    addTeardownBlock { @MainActor in
      store.utilityWindows?.shutdown(); store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
    return store
  }
  private func settle() async throws { try await Task.sleep(nanoseconds: 60_000_000) }

  func testSimultaneousNormalWindowsReuseAndSynchronizeCloseWithoutBlockingProject() async throws {
    let store = try fixture(), windows = StudioUtilityWindows(store: store)
    defer { windows.shutdown() }
    store.showingLibrary = true; store.showingProjectInfo = true; store.showingPrint = true
    try await settle()
    let library = try XCTUnwrap(windows.window(for: .library)), notes = try XCTUnwrap(windows.window(for: .projectInfo)), printing = try XCTUnwrap(windows.window(for: .printPreparation))
    for window in [library, notes, printing] {
      XCTAssertTrue(window.isVisible); XCTAssertTrue(window.styleMask.contains(.resizable))
      XCTAssertTrue(window.styleMask.contains(.closable)); XCTAssertEqual(window.level, .normal)
      XCTAssertNil(window.sheetParent); XCTAssertTrue(window.sheets.isEmpty)
    }
    XCTAssertNil(NSApp.modalWindow)
    let main = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    main.isReleasedWhenClosed = false
    defer { main.close() }
    let field = NSTextField(frame: .init(x: 20, y: 20, width: 240, height: 28))
    let presenter = StudioUtilityWindowPresenter.Coordinator(), anchor = StudioUtilityWindowPresenter.HostView(frame: .zero)
    presenter.bind(store); anchor.coordinator = presenter
    main.contentView?.addSubview(anchor)
    main.contentView?.addSubview(field); main.makeKeyAndOrderFront(nil)
    XCTAssertTrue(main.makeFirstResponder(field))
    try store.engine.edit("Main remains editable") { $0.subtitle = "Edited while all three utilities are open" }
    XCTAssertEqual(store.project?.subtitle, "Edited while all three utilities are open")
    store.showingLibrary = true; store.showingProjectInfo = true
    try await settle()
    XCTAssertTrue(windows.window(for: .library) === library)
    XCTAssertTrue(windows.window(for: .projectInfo) === notes)
    notes.performClose(nil)
    XCTAssertFalse(store.showingProjectInfo); XCTAssertFalse(notes.isVisible)
    XCTAssertTrue(library.isVisible); XCTAssertTrue(printing.isVisible)
    store.showingProjectInfo = true
    try await settle()
    XCTAssertTrue(windows.window(for: .projectInfo) === notes); XCTAssertTrue(notes.isVisible)
    // Done uses this explicit close callback; Escape reaches the normal window responder.
    windows.dismiss(.library)
    XCTAssertFalse(store.showingLibrary); XCTAssertFalse(library.isVisible)
    printing.cancelOperation(nil)
    XCTAssertFalse(store.showingPrint); XCTAssertFalse(printing.isVisible)
    store.showingProjectInfo = false
    try await settle()
    XCTAssertFalse(notes.isVisible)
    store.showingLibrary = true
    try await settle()
    XCTAssertTrue(library.isVisible)
    main.close()
    XCTAssertFalse(library.isVisible); XCTAssertFalse(store.showingLibrary)
    XCTAssertNil(presenter.windows); XCTAssertNil(store.utilityWindows)
  }

  func testProjectSwitchAndHomeDiscardScopedContentKeepLibraryAndReleasePresenterOwnership() async throws {
    let store = try fixture(), windows = StudioUtilityWindows(store: store)
    let firstOwner = UUID(), secondOwner = UUID()
    windows.attach(firstOwner); windows.attach(secondOwner)
    store.showingLibrary = true; store.showingProjectInfo = true; store.showingPrint = true
    try await settle()
    let library = try XCTUnwrap(windows.window(for: .library)), oldNotes = try XCTUnwrap(windows.window(for: .projectInfo)), oldPrint = try XCTUnwrap(windows.window(for: .printPreparation))
    let second = Project(name: "Second notebook")
    try store.repository.save(second)
    try store.engine.open(second.id)
    XCTAssertFalse(oldNotes.isVisible); XCTAssertNil(oldNotes.contentViewController)
    XCTAssertFalse(oldPrint.isVisible); XCTAssertNil(oldPrint.contentViewController)
    XCTAssertFalse(store.showingProjectInfo); XCTAssertFalse(store.showingPrint)
    XCTAssertTrue(library.isVisible); XCTAssertTrue(store.showingLibrary)
    XCTAssertNil(windows.window(for: .projectInfo)); XCTAssertNil(windows.window(for: .printPreparation))
    // A new request immediately after the ID change opens the new project, with no old drafts.
    store.showingProjectInfo = true
    try await settle()
    let newNotes = try XCTUnwrap(windows.window(for: .projectInfo))
    XCTAssertFalse(newNotes === oldNotes); XCTAssertTrue(newNotes.isVisible)
    let before = try XCTUnwrap(store.project)
    store.home()
    XCTAssertFalse(newNotes.isVisible); XCTAssertNil(newNotes.contentViewController)
    XCTAssertFalse(store.showingProjectInfo); XCTAssertFalse(store.showingPrint)
    XCTAssertTrue(library.isVisible); XCTAssertTrue(store.showingLibrary)
    XCTAssertEqual(store.project?.id, before.id); XCTAssertEqual(store.project?.notes, before.notes)
    store.showingPrint = true
    try await settle()
    XCTAssertFalse(store.showingPrint); XCTAssertNil(windows.window(for: .printPreparation))
    windows.detach(firstOwner)
    XCTAssertTrue(library.isVisible, "Another main presenter still owns the shared utilities")
    windows.detach(secondOwner)
    XCTAssertFalse(library.isVisible); XCTAssertNil(library.contentViewController)
    XCTAssertFalse(store.showingLibrary); XCTAssertNil(store.utilityWindows); XCTAssertNil(windows.store)
  }
}

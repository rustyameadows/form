import AppKit
import SwiftUI

/// Menu tracking and native button actions may finish after the project or
/// current draft changes. Carry the exact destination through that delay.
struct CanvasImagePromptIdentity: Equatable {
  let projectID: UUID
  let projectEpoch: UUID
  let destinationID: UUID
  let draftID: UUID

  init(_ draft: CanvasImageGenerationDraft) {
    projectID = draft.projectID; projectEpoch = draft.projectEpoch
    destinationID = draft.destinationID; draftID = draft.id
  }
}

extension VectorCanvasView {
  var canvasImagePromptIdentity: CanvasImagePromptIdentity? {
    guard let store = session?.store, !store.showingHome,
      let draft = store.canvasImages.draft,
      draft.projectID == store.project?.id,
      draft.projectEpoch == store.artworkTransferProjectEpoch,
      store.project?.objects.contains(where: { $0.id == draft.destinationID && $0.recipeID == "artboard" }) == true
    else { return nil }
    return CanvasImagePromptIdentity(draft)
  }

  @discardableResult func requestCanvasImagePrompt(_ identity: CanvasImagePromptIdentity) -> Bool {
    guard window != nil, canvasImagePromptIdentity == identity else { return false }
    // Waiting until menu tracking has ended prevents AppKit from immediately
    // dismissing the newly presented transient prompt with the menu's event.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.window != nil, self.canvasImagePromptIdentity == identity,
        let session = self.session, let store = session.store else { return }
      self.prepareForGroupNavigation()
      NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
      self.finishText(); session.endGesture()
      guard self.canvasImagePromptIdentity == identity else { return }
      store.activateDesignSurface(.artwork)
      session.activate(identity.destinationID)
      self.synchronize()
      self.showCanvasImagePrompt()
    }
    return true
  }

  func synchronizeCanvasImagePromptButton() {
    guard let scroll = enclosingScrollView else { return }
    let existing = scroll.subviews.compactMap { $0 as? CanvasImagePromptButton }.first
    guard let identity = canvasImagePromptIdentity else {
      existing?.removeFromSuperview(); return
    }
    let button = existing ?? CanvasImagePromptButton(canvas: self, scroll: scroll)
    button.identity = identity
    button.boardRect = session?.frames.first(where: { $0.object.id == identity.destinationID })?.rect
    if button.superview == nil { scroll.addSubview(button, positioned: .above, relativeTo: scroll.contentView) }
    button.reposition()
  }
}

/// A scroll-view overlay keeps a usable native target at every Canvas zoom.
/// Its normal position is above the title strip, clear of frame resize handles.
final class CanvasImagePromptButton: NSButton {
  private weak var canvas: VectorCanvasView?
  var identity: CanvasImagePromptIdentity?
  var boardRect: CGRect?
  private var boundsObservation: NSObjectProtocol?
  private var magnificationObservation: NSKeyValueObservation?
  static let buttonSize = NSSize(width: 126, height: 26)

  init(canvas: VectorCanvasView, scroll: NSScrollView) {
    self.canvas = canvas
    super.init(frame: NSRect(origin: .zero, size: Self.buttonSize))
    title = "Image prompt…"
    image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
    imagePosition = .imageLeading
    bezelStyle = .rounded; font = .systemFont(ofSize: 11, weight: .medium)
    setButtonType(.momentaryPushIn)
    target = self; action = #selector(reopen)
    setAccessibilityIdentifier("canvas-image-prompt-reopen")
    setAccessibilityLabel("Continue image prompt")
    toolTip = "Reopen this artboard’s image prompt and references"
    scroll.contentView.postsBoundsChangedNotifications = true
    boundsObservation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
      object: scroll.contentView, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.reposition() }
      }
    magnificationObservation = scroll.observe(\.magnification, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.reposition() }
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  deinit { if let boundsObservation { NotificationCenter.default.removeObserver(boundsObservation) } }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  func reposition() {
    guard let canvas, let scroll = superview as? NSScrollView, let identity,
      canvas.canvasImagePromptIdentity == identity,
      let boardRect
    else { isHidden = true; return }
    let anchor = canvas.convert(canvas.documentPoint(CGPoint(x: boardRect.maxX, y: boardRect.minY)), to: scroll)
    let viewport = scroll.convert(scroll.contentView.bounds, from: scroll.contentView)
    let top = scroll.isFlipped ? viewport.minY : viewport.maxY
    let boardTop = scroll.isFlipped ? anchor.y : -anchor.y
    let viewportTop = scroll.isFlipped ? top : -top
    // A board whose top-right corner is offscreen has no floating control
    // detached from its frame. Its inspector offers the same reopen action.
    guard anchor.x >= viewport.minX, anchor.x <= viewport.maxX,
      boardTop >= viewportTop, boardTop <= viewportTop + viewport.height else { isHidden = true; return }
    let gap: CGFloat = 18
    let desired = NSRect(x: anchor.x - Self.buttonSize.width,
      y: scroll.isFlipped ? anchor.y - gap - Self.buttonSize.height : anchor.y + gap,
      width: Self.buttonSize.width, height: Self.buttonSize.height)
    guard viewport.insetBy(dx: 2, dy: 2).contains(desired) else { isHidden = true; return }
    frame = desired; isHidden = false
  }

  @objc private func reopen() {
    guard let identity else { return }
    _ = canvas?.requestCanvasImagePrompt(identity)
  }
}

struct CanvasImagePromptInspectorShortcut: View {
  @ObservedObject var controller: CanvasImageGenerationController
  @ObservedObject var session: ArtworkSession
  var body: some View {
    if let draft = controller.draft, session.objectID == draft.destinationID,
      let canvas = session.canvas, canvas.canvasImagePromptIdentity == CanvasImagePromptIdentity(draft) {
      Button {
        canvas.requestCanvasImagePrompt(CanvasImagePromptIdentity(draft))
      } label: {
        Label("Image prompt…", systemImage: "sparkles")
      }.font(.system(size: 12)).accessibilityIdentifier("canvas-image-prompt-inspector")
    }
  }
}

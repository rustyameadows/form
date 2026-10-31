import AppKit
import FormCore

extension StudioStore {
  var isStudioImageWorkspace:Bool {environment == .studio && studioShowingImages}
  var studioImageTextEditor:NSTextView? {
    guard isStudioImageWorkspace,let editor=NSApp.keyWindow?.firstResponder as? NSTextView,editor.isEditable else{return nil}
    return editor
  }
  func applyStudioImageTextHistory(in window:NSWindow?,redo:Bool=false)->Bool {
    guard isStudioImageWorkspace else{return false}
    if let editor=window?.firstResponder as? NSTextView,editor.isEditable {
      if redo {editor.undoManager?.redo()}else{editor.undoManager?.undo()}
    }
    return true
  }

  func openAssetLibrary() {
    guard project != nil,!showingHome else{return}
    showingAssets=true
    Task {await studioAssets.refresh()}
  }

  func createStudioStill() {
    guard project != nil else {return}
    showEnvironment(.studio)
    studioShowingShots=false;studioShowingImages=true
    studioImages.reconcile()
    let images=studioImages
    images.refreshSceneInputFromStudio()
  }

  func reviewStudioImageRun(_ id:UUID) {
    guard let project,!showingHome,studioImages.history.contains(where:{$0.id==id && $0.capture.projectID==project.id}) else {return}
    showEnvironment(.studio)
    studioShowingShots=false;studioShowingImages=true
    studioImages.selectRun(id)
  }

  func useLibraryAssetAsReference(_ asset:StudioAsset) {
    guard project != nil,!showingHome else{return}
    guard asset.metadata.projectID==project?.id else{return}
    guard asset.kind == .image else {error="Choose an image as a rendering reference.";return}
    createStudioStill()
    studioImages.addReference(assetID:asset.id)
  }

  func placeLibraryAssetOnCanvas(_ asset:StudioAsset) {
    guard project != nil,!showingHome else{return}
    guard asset.metadata.projectID==project?.id else{return}
    guard [.image,.pdf,.vector].contains(asset.kind) else {error="Choose an image, PDF or vector to place on Canvas.";return}
    do {
      let url=try studioAssets.fileURL(for:asset)
      guard let id=ensureCanvas() else {return}
      studioShowingImages=false
      showEnvironment(.form);showSurface(.artwork)
      artworkSession.activate(id)
      if artworkSession.placeImages([url]) {toast("Placed Library image on Canvas")}
    } catch {self.error=error.localizedDescription}
  }
}

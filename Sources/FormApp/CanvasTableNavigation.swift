import Foundation
import FormCore

extension StudioStore {
  /// Explicit cross-viewport navigation. Ordinary Canvas selection never calls this.
  @discardableResult func findOnTable(_ id: UUID) -> Bool {
    guard project?.objects.contains(where: { $0.id == id && !$0.isCanvasWorkspace }) == true else { return false }
    finishArtworkEditing()
    showEnvironment(.form)
    select(id)
    if !isolated.isEmpty, !isolated.contains(id) { isolated = [] }
    showingHome = false
    activateDesignSurface(.table)
    designSurfaceHost?.refresh()
    synchronizeScene()
    scene?.focusSelection()
    return true
  }
}

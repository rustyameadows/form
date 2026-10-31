import Foundation
import FormCore

extension StudioStore {
  /// Explicit cross-viewport navigation. Ordinary Canvas selection never calls this.
  @discardableResult func findOnTable(_ id: UUID) -> Bool {
    guard project?.objects.contains(where: { $0.id == id && $0.hasTablePresentation }) == true else { return false }
    showEnvironment(.form)
    showingHome = false
    return navigateToTableObject(id)
  }
}

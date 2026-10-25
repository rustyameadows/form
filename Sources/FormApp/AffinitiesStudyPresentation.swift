import AppKit
import FormCore
import FormGraphics

@MainActor enum AffinitiesStudyPresentation {
  static func missingFonts(
    in project: Project, available: @MainActor (String) -> Bool = FontLibraryCatalog.installed
  ) -> [String] {
    Set(FontUsage.uses(in: project).map(\.fontName)).filter { !available($0) }.sorted()
  }
}

extension StudioStore {
  /// Navigation only: creation already saved the complete, independently identified source.
  @discardableResult func presentAffinitiesStudy(
    fontAvailable: @MainActor (String) -> Bool = FontLibraryCatalog.installed
  ) -> [String] {
    guard let project,
      let source = project.objects.first(where: { $0.name == AffinitiesStudy.sourceName }),
      let edition = project.objects.first(where: { $0.name == "AFFINITIES / Oak edition" })
    else { return [] }
    showSplit()
    artworkSession.activate(source.id)
    engine.selection = [edition.id]
    artworkSession.linkedTargetID = edition.id
    if let title = source.artwork?.elements.first(where: { $0.name == "Editable display wordmark" })
    {
      artworkSession.choose([title.id])
    }
    let missing = AffinitiesStudyPresentation.missingFonts(in: project, available: fontAvailable)
    if !missing.isEmpty {
      toast("Font assignments retained. Unavailable: " + missing.joined(separator: ", "))
      showingDocumentFonts = true
    }
    changed(save: false)
    return missing
  }
}

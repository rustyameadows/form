import AppKit
import FormCore
import FormGraphics

@MainActor enum ProjectPreview {
  static func image(project:Project,size:CGSize,assets:URL) -> NSImage {
    guard project.physicalObjectCount == 0,let workspace = project.canvasWorkspace else {
      return TableSceneController.preview(project:project,size:size,assets:assets)
    }
    var art = project.editableArtwork(workspace) ?? .init(background:"#E7E7E1")
    let maskIDs = Set(art.elements.compactMap(\.clipID))
    let ids = Set(art.elements.filter {
      $0.parentID == nil && $0.hidden != true && !maskIDs.contains($0.id)
    }.map(\.id))
    let aspect = Double(max(1,size.width) / max(1,size.height))
    var width = 400.0,height = 400.0 / aspect
    if !ids.isEmpty,let crop = try? art.exporting(ids) {
      art = crop.artwork
      width = max(40,crop.bounds.width * 1.2)
      height = max(26,crop.bounds.height * 1.2)
      if width / height < aspect { width = height * aspect }
      else { height = width / aspect }
      let translation = Affine2.translation((width-crop.bounds.width)/2,(height-crop.bounds.height)/2)
      for index in art.elements.indices where art.elements[index].parentID == nil {
        art.elements[index].affine = translation.followed(by:art.elements[index].affine ?? .init())
      }
    }
    art.background = "#E7E7E1"; art.backgroundOpacity = 1; art.boundary = nil
    return ArtworkRenderer.image(art,width:width,height:height,assets:assets,
      pixelsPerMM:Double(max(1,size.width))/width,opaqueBackground:true)
  }
}

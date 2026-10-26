import AppKit
import FormCore
import FormGraphics

@MainActor enum ProjectPreview {
  static func image(project:Project,size:CGSize,assets:URL) -> NSImage {
    let pageIDs = Set((project.publications ?? []).flatMap { $0.pages.map(\.objectID) })
    let physicalIDs = Set(project.objects.filter { !$0.isCanvasWorkspace }.map(\.id))
    if !physicalIDs.isEmpty, physicalIDs.isSubset(of: pageIDs),
      let page = project.publications?.first(where: { !$0.pages.isEmpty })?.pages.first,
      let object = project.objects.first(where: { $0.id == page.objectID }),
      let artwork = project.surfaceArtwork(object),
      let preview = publicationPage(artwork, physicalSize: object.artworkSize, size: size, assets: assets) {
      return preview
    }
    guard project.physicalObjectCount == 0,let workspace = project.canvasWorkspace else {
      return TableSceneController.preview(project:project,size:size,assets:assets)
    }
    let composition = canvasComposition(artwork:project.editableArtwork(workspace) ?? .init(background:"#E7E7E1"),size:size)
    return ArtworkRenderer.image(composition.artwork,width:composition.width,height:composition.height,assets:assets,
      pixelsPerMM:composition.density,opaqueBackground:true)
  }
  struct CanvasComposition {
    var artwork:Artwork
    var width:Double
    var height:Double
    var density:Double
  }
  /// Shared framing only. The normal project-cache render keeps physical strokes.
  static func canvasComposition(artwork:Artwork,size:CGSize)->CanvasComposition {
    var art = artwork
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
    return .init(artwork:art,width:width,height:height,density:Double(max(1,size.width))/width)
  }
  private static func publicationPage(_ artwork: Artwork, physicalSize: Point2, size: CGSize, assets: URL) -> NSImage? {
    guard size.width.isFinite, size.height.isFinite, physicalSize.x.isFinite, physicalSize.y.isFinite,
      physicalSize.x > 0, physicalSize.y > 0 else { return nil }
    let width = Int(max(1, min(4096, size.width))), height = Int(max(1, min(4096, size.height)))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let w = Double(width), h = Double(height), gutter = min(w, h) * 0.065
    let scale = min((w - 2 * gutter) / physicalSize.x, (h - 2 * gutter) / physicalSize.y)
    let page = CGRect(x: (w - physicalSize.x * scale) / 2, y: (h - physicalSize.y * scale) / 2,
      width: physicalSize.x * scale, height: physicalSize.y * scale)
    context.setFillColor(FormColor.color("#E7E7E1").cgColor); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -3), blur: 12, color: NSColor.black.withAlphaComponent(0.13).cgColor)
    context.setFillColor(NSColor.white.cgColor); context.fill(page)
    context.restoreGState()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    context.translateBy(x: page.minX, y: page.maxY); context.scaleBy(x: scale, y: -scale)
    ArtworkRenderer.draw(artwork, width: physicalSize.x, height: physicalSize.y, assets: assets)
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage() else { return nil }
    return NSImage(cgImage: image, size: CGSize(width: width, height: height))
  }
}

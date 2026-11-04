import AppKit
import FormCore
import FormGraphics
import FormGeometry

@MainActor enum SheetAssemblyRenderValidation {
  /// Source owners are canonical pages/covers. A physical book itself owns no
  /// artwork, so validating only surfaceArtwork(book) misses all these inputs.
  static func sources(_ object:ProductObject,project:Project,assets:URL)throws {
    guard object.sheetAssembly != nil else{try panelSources(object,project:project,assets:assets);return}
    let resolved:ResolvedSheetAssembly
    do{resolved=try project.resolvedSheetAssembly(object)}
    catch{throw FormError.invalid("Cannot render \(object.name): \(error.localizedDescription)")}
    let faces=resolved.leaves.flatMap{[$0.front,$0.back].compactMap{$0}}
      + resolved.enclosure.flatMap{[$0.front,$0.back].compactMap{$0}}
      + resolved.enclosure.flatMap{$0.features?.recesses.compactMap{$0.insert?.face} ?? []}
      + [resolved.edgeArtwork?.head,resolved.edgeArtwork?.tail,resolved.edgeArtwork?.foreEdge].compactMap{$0}
    try validate(faces,object:object,project:project,assets:assets)
  }
  static func panelSources(_ object:ProductObject,project:Project,assets:URL)throws {
    guard PaperConstruction.isPaper(object),let definition=try? PaperConstruction.definition(for:object) else{return}
    let faces=definition.authored?.panels.flatMap{$0.features?.recesses?.compactMap{$0.insert?.face} ?? []} ?? []
    try validate(faces.map{.init(sourceObjectID:$0.sourceObjectID,sourceSide:$0.sourceSide)},object:object,project:project,assets:assets)
  }
  private static func validate(_ faces:[ResolvedSheetAssemblyFace],object:ProductObject,project:Project,assets:URL)throws {
    var checked=Set<String>(),images=Set<String>(),stories=Set<UUID>()
    for face in faces {
      let key=face.sourceObjectID.uuidString+":"+face.sourceSide.rawValue
      guard checked.insert(key).inserted else{continue}
      guard let source=project.objects.first(where:{$0.id==face.sourceObjectID}),
        let art=PaperConstruction.isPaper(source) ? project.paperArtwork(for:source,inside:face.sourceSide == .inside):project.surfaceArtwork(source) else {
        throw FormError.invalid("Cannot render \(object.name): a canonical page or cover source is unavailable.")
      }
      do {
        try ArtworkRenderer.validateGlyphOutput(art,assets:assets)
        var required=try ArtworkRenderer.requiredImageAssets(art,assets:assets)
        for element in art.elements {
          if let story=element.storyFrame?.resolved,stories.insert(story.story.id).inserted {
            let source=story.story.sourceElement.inheritingLanguage(story.language)
            try GlyphEngine.validateOutput(source)
            required.formUnion(try ArtworkRenderer.requiredImageAssets(Artwork(elements:[source]),assets:assets))
          }
        }
        for name in required where images.insert(name).inserted {
          guard !name.isEmpty,!name.contains("/"),!name.contains("\\") else{throw FormError.invalid("An image must reference an ordinary project asset filename.")}
          do {
            let url=assets.appendingPathComponent(name)
            let resource=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard resource.isRegularFile==true,resource.isSymbolicLink != true else{throw FormError.invalid("An image must be a regular portable asset file.")}
            // A deleted/repaired file must not pass because an older thumbnail
            // is warm. Decode a bounded sample from the current file identity.
            ImageRenderer.invalidate(url)
            _=try ImageRenderer.bitmap(url,requestedEdge:64)
          }catch{throw FormError.invalid("Image asset ‘\(name)’ is missing or unreadable: \(error.localizedDescription)")}
        }
      }catch{throw FormError.invalid("Cannot render \(object.name), source \(source.name): \(error.localizedDescription)")}
    }
  }
  static func scene(_ root:MeshNode,project:Project,objectIDs:Set<UUID>)throws {
    for object in project.objects where object.sheetAssembly != nil && objectIDs.contains(object.id) {
      guard let node=root.childNode(withName:"object:"+object.id.uuidString,recursively:false) else {
        throw FormError.invalid("Cannot render \(object.name): its physical geometry was not prepared.")
      }
      var issue=node.constructionFailure
      node.enumerateChildNodes{child,stop in if let found=child.constructionFailure{issue=found;stop.pointee=true}}
      if let issue{throw issue}
      guard node.childNode(withName:SheetAssemblyGeometry.rootName,recursively:true) != nil else {
        throw FormError.invalid("Cannot render \(object.name): linked sheet construction produced no physical geometry.")
      }
    }
  }
}

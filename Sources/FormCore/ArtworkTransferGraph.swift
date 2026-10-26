import Foundation

public enum ArtworkTransferGraph {
  static func boundedOwner(_ project:Project,_ objectID:UUID,_ limits:ArtworkTransferLimits)throws->ProductObject {
    guard project.objects.count<=min(10000,limits.work),Set(project.objects.map(\.id)).count==project.objects.count else{throw FormError.invalid("Artwork owner lookup exceeds its budget or has duplicate IDs.")}
    let objects=Dictionary(uniqueKeysWithValues:project.objects.map{($0.id,$0)})
    guard var owner=objects[objectID] else{throw FormError.invalid("Missing artwork owner.")}
    var seen=Set<UUID>(),depth=0
    while let id=owner.artworkSourceID {depth+=1;guard depth<=limits.depth,seen.insert(owner.id).inserted,let next=objects[id] else{throw FormError.invalid("Artwork source links are cyclic, missing or too deep.")};owner=next}
    return owner
  }
  /// Read-only graph/resource capture. Asset bytes are supplied by a bounded reader.
  public static func capture(project:Project,objectID:UUID,ids:Set<UUID>,
    readAsset:(String,Int)throws->Data,limits:ArtworkTransferLimits = .init())throws->ArtworkTransferBundle {
    guard project.objects.count<=min(10000,limits.work),let object=project.objects.first(where:{$0.id==objectID}),!ids.isEmpty else{throw FormError.invalid("Select artwork to copy.")}
    let owner=try boundedOwner(project,object.id,limits)
    guard let original=owner.artwork,ids.isSubset(of:Set(original.elements.map(\.id))) else{throw FormError.invalid("Copy needs existing editable source layers.")}
    guard !(project.publications ?? []).contains(where:{$0.pages.contains(where:{$0.objectID==owner.id})}) else{throw FormError.invalid("Publication pages need a complete publication transfer; partial clipboard scope is unsupported.")}
    var work=project.objects.count+original.elements.count
    guard work<=limits.work,original.elements.count<=5000 else{throw FormError.invalid("Source inspection exceeds its transfer budget.")}
    guard Set(original.elements.map(\.id)).count==original.elements.count,Set(project.objects.map(\.id)).count==project.objects.count else{throw FormError.invalid("Duplicate source identities.")}
    let objectsByID=Dictionary(uniqueKeysWithValues:project.objects.map{($0.id,$0)})
    let byID=Dictionary(uniqueKeysWithValues:original.elements.map{($0.id,$0)})
    let children=Dictionary(grouping:original.elements,by:\.parentID)
    var required=Set<UUID>(),pending=Array(ids)
    func descend(_ id:UUID)throws {
      var stack=[id]
      while let value=stack.popLast() {work+=1;guard work<=limits.work,let e=byID[value] else{throw FormError.invalid("Missing or excessive transfer graph.")};if required.insert(value).inserted {stack += (children[e.id] ?? []).map(\.id)}}
    }
    for id in ids {try descend(id)}
    // Ancestors are shells, not unrelated visible siblings. Complete masks travel.
    pending=Array(required)
    while let id=pending.popLast() {
      work+=1;guard work<=limits.work,required.count<=limits.elements,let e=byID[id] else{throw FormError.invalid("Transfer dependencies exceed their work budget.")}
      for dependency in [e.parentID,e.clipID].compactMap({$0}) {if required.insert(dependency).inserted {pending.append(dependency)}}
    }
    guard required.allSatisfy({byID[$0] != nil}) else{throw FormError.invalid("A selected layer has a missing parent or mask.")}
    for e in original.elements where required.contains(e.id) {
      if e.booleanOperation != nil {
        var operands=(children[e.id] ?? []).map(\.id)
        while let id=operands.popLast() {work+=1;guard work<=limits.work,required.contains(id) else{throw FormError.invalid("Select the complete boolean group before copying; its descendants must fit the transfer work budget.")};let next=(children[id] ?? []).map(\.id);guard next.count<=limits.work-work-operands.count else{throw FormError.invalid("Boolean traversal queue exceeds its transfer budget.")};operands += next}
      }
      // Existing outline sources have no typed association. Do not infer one from
      // names, and do not put unrelated hidden content on a clipboard silently.
      if e.kind=="path",(children[e.parentID] ?? []).contains(where:{!required.contains($0.id) && $0.hidden==true && ($0.kind=="text" || $0.visibleStroke != nil || ["rectangle","ellipse","line","polygon","star"].contains($0.kind))}) {
        throw FormError.invalid("This partial path scope has ambiguous hidden recoverable source. Copy its complete enclosing scope instead.")
      }
    }
    let chosenLists=Set(original.elements.filter{required.contains($0.id)}.flatMap{($0.listItems ?? []).map(\.listID)})
    guard !original.elements.contains(where:{!required.contains($0.id) && !chosenLists.isDisjoint(with:Set(($0.listItems ?? []).map(\.listID)))}) else{throw FormError.invalid("Copy the complete continued list; its numbering will not be baked into restarts.")}
    guard original.imports?.isEmpty != false || required.count==original.elements.count else{throw FormError.invalid("Copy the complete imported scope to retain its original source-file provenance.")}
    // Keep source frame metadata in the portable record, including future known
    // source-only properties. Layer paste still preserves destination frame settings.
    var art=original;art.elements=original.elements.filter{required.contains($0.id)};art.requiresInkOutput=false
    art.sewingSeams=(original.sewingSeams ?? []).filter{required.contains($0.first.elementID) || required.contains($0.second.elementID)}
    guard art.sewingSeams?.allSatisfy({required.contains($0.first.elementID) && required.contains($0.second.elementID)}) != false else{throw FormError.invalid("Copy both sides of every sewing seam together.")}
    if art.sewingSeams?.isEmpty==true {art.sewingSeams=nil}
    guard original.sewingLayout==nil else{throw FormError.invalid("Cutting layouts require their complete manufacturing context; clipboard transfer is not supported yet.")}
    guard !(project.garmentBlocks ?? []).contains(where:{$0.bindings.contains(where:{$0.objectID==owner.id && required.contains($0.elementID)})}) else{throw FormError.invalid("Managed garment pieces require their complete source block, not a partial clipboard transfer.")}
    var definitions=[UUID:ArtworkTransferComponent](),visiting=Set<UUID>()
    func inspect(_ value:Artwork)throws {
      work+=value.elements.count
      guard work<=limits.work,definitions.count<=limits.components else{throw FormError.invalid("Component closure exceeds its transfer budget.")}
      guard value.sewingLayout==nil else{throw FormError.invalid("Component manufacturing layouts are not portable in this prototype.")}
      guard !value.elements.contains(where:{$0.storyFrame != nil || $0.sewingPiece?.materialID != nil}) else{throw FormError.invalid("Stories and material-bound manufacturing pieces need a complete context transfer.")}
      for ref in value.elements.compactMap(\.component) {try collect(ref.sourceObjectID,depth:1)}
    }
    func collect(_ id:UUID,depth:Int)throws {
      guard depth<=8,!visiting.contains(id) else{throw FormError.invalid("Component closure is cyclic or more than eight levels deep.")}
      if definitions[id] != nil {return}
      guard definitions.count<limits.components,let source=objectsByID[id],source.componentDefinition==true,source.artworkSourceID==nil,let sourceArt=source.artwork else{throw FormError.invalid("A complete independent component definition is required.")}
      visiting.insert(id);defer{visiting.remove(id)}
      for ref in sourceArt.elements.compactMap(\.component) {try collect(ref.sourceObjectID,depth:depth+1)}
      definitions[id] = .init(id:id,name:source.name,size:source.artworkSize,artwork:sourceArt)
      try inspect(sourceArt)
    }
    try inspect(art)
    let arts=[art]+definitions.values.map(\.artwork)
    let styleIDs=arts.reduce(into:Set<UUID>()){$0.formUnion($1.referencedTextStyles)}
    let swatchIDs=arts.reduce(into:Set<UUID>()){$0.formUnion($1.referencedSwatches)}
    let styles=(project.textStyles ?? []).filter{styleIDs.contains($0.id)},swatches=(project.swatches ?? []).filter{swatchIDs.contains($0.id)}
    guard Set(styles.map(\.id))==styleIDs,Set(swatches.map(\.id))==swatchIDs else{throw FormError.invalid("Selected artwork is missing a named style or swatch.")}
    var names=Set(arts.flatMap{$0.elements.compactMap(\.asset)+($0.imports ?? []).map(\.asset)})
    names.formUnion(arts.compactMap{$0.outputColorProfile?.asset});names.formUnion(swatches.compactMap{$0.printInk?.profile.asset})
    guard names.count<=limits.assets else{throw FormError.invalid("Too many portable transfer assets.")}
    var assets=[ArtworkTransferAsset](),blobs=[String:Data](),total=0
    for name in names.sorted() {
      guard ArtworkTransferBundle.safeName(name) else{throw FormError.invalid("Unsafe source asset path.")}
      let bytes=try readAsset(name,min(limits.individualAssetBytes,limits.totalAssetBytes-total))
      guard !bytes.isEmpty,bytes.count<=limits.individualAssetBytes,bytes.count<=limits.totalAssetBytes-total else{throw FormError.invalid("Source asset exceeds the portable byte budget.")}
      total+=bytes.count;let digest=ArtworkTransferBundle.digest(bytes),ext=URL(fileURLWithPath:name).pathExtension.lowercased()
      assets.append(.init(sourceName:name,portableName:(ext=="icc" ? "icc-":"image-")+digest+"."+ext,sha256:digest,length:bytes.count));blobs[name]=bytes
    }
    let metadata=ArtworkTransferMetadata(sourceSchema:project.minimumSchemaVersion,projectID:project.id,ownerID:owner.id,selection:ids.sorted{$0.uuidString<$1.uuidString},artwork:art,components:definitions.values.sorted{$0.id.uuidString<$1.id.uuidString},styles:styles,swatches:swatches,assets:assets)
    let bundle=ArtworkTransferBundle(metadata:metadata,blobs:blobs);_ = try bundle.encoded(limits:limits);return bundle
  }
}

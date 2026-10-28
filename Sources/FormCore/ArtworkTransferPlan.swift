import Foundation

public struct ArtworkTransferPlan {
  public var baseProject:Project
  public var project:Project
  public var selection:Set<UUID>
  public var addedComponentIDs:[UUID]
  public var assetWrites:[String:Data]
  public var assetMap:[String:String]
  public var elementMaps:[UUID:[UUID:UUID]]
  /// Refuse stale document application, while preserving independent live camera navigation.
  public func applying(to current:Project)throws->Project {
    var comparable=current;comparable.camera=baseProject.camera
    guard comparable==baseProject else{throw FormError.invalid("The paste destination changed while preparing resources. Prepare the transfer again.")}
    var result=project;result.camera=current.camera;return result
  }
}

extension ArtworkTransferGraph {
  /// Pure candidate + owned asset write plan. Nothing is written or committed here.
  public static func plan(_ bundle:ArtworkTransferBundle,into original:Project,objectID:UUID,
    scopeID:UUID?=nil,offset:Point2 = .init(10,10),existingAsset:(String,Int)throws->Data? = {_,_ in nil},
    limits:ArtworkTransferLimits = .init())throws->ArtworkTransferPlan {
    try bundle.validate(limits:limits)
    guard original.objects.count<=min(10000,limits.work),let object=original.objects.first(where:{$0.id==objectID}),!object.locked else{throw FormError.invalid("Choose an unlocked artwork destination.")}
    let owner=try boundedOwner(original,object.id,limits);guard !owner.locked,owner.patternAssembly==nil,(owner.isCanvasWorkspace || owner.supportsArtworkFace) else{throw FormError.invalid("Choose an editable independent artwork destination.")}
    var target=owner.artwork ?? Artwork(background:"#FFFFFF")
    try validateArtwork(target)
    guard !(original.publications ?? []).contains(where:{$0.pages.contains(where:{$0.objectID==owner.id})}) else{throw FormError.invalid("Publication pages require a complete publication transfer.")}
    let m=bundle.metadata,sameProject=m.projectID==original.id
    guard offset.x.isFinite,offset.y.isFinite,abs(offset.x)<=100000,abs(offset.y)<=100000 else{throw FormError.invalid("Paste placement must be a bounded physical millimeter offset.")}
    var placement=Affine2.translation(offset.x,offset.y)
    if let scopeID {
      guard let scope=target.elements.first(where:{$0.id==scopeID}),scope.kind=="group",scope.component==nil,scope.booleanOperation==nil,!target.isLocked(scope) else{throw FormError.invalid("Paste into an editable destination group.")}
      guard let inverse=target.worldTransform(scope).inverse else{throw FormError.invalid("The destination scope has no invertible physical transform.")}
      placement=inverse.followed(by:placement)
    }
    if target.elements.isEmpty {target.language=m.artwork.language;target.unit=m.artwork.unit;target.outputColorProfile=m.artwork.outputColorProfile}
    else {
      guard target.language==m.artwork.language else{throw FormError.invalid("Document languages differ; transfer into an empty or matching-language frame to preserve source language defaults.")}
      guard target.outputColorProfile==m.artwork.outputColorProfile else{throw FormError.invalid("Output profiles differ; choose an empty or matching-profile frame before pasting.")}
    }
    var candidate=original,assetMap=[String:String](),writes=[String:Data]()
    for asset in m.assets {
      let bytes=bundle.blobs[asset.sourceName]!
      if sameProject,let existing=try existingAsset(asset.sourceName,asset.length),existing==bytes {assetMap[asset.sourceName]=asset.sourceName;continue}
      let name=asset.portableName
      if let existing=try existingAsset(name,asset.length) {guard existing==bytes else{throw FormError.invalid("An existing content-addressed destination asset has different bytes.")}}
      else {writes[name]=bytes}
      assetMap[asset.sourceName]=name
    }
    var styleMap=[UUID:UUID](),swatchMap=[UUID:UUID](),objectMap=[UUID:UUID](),maps=[UUID:[UUID:UUID]](),listMaps=[UUID:[UUID:UUID]]()
    for style in m.styles {
      if sameProject,(original.textStyles ?? []).contains(style) {styleMap[style.id]=style.id;continue}
      guard !(original.textStyles ?? []).contains(where:{$0.name.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()==style.name.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}) else{throw FormError.invalid("A destination text style already uses the name \(style.name); no source formatting was replaced.")}
      var copy=style;copy.id=UUID();styleMap[style.id]=copy.id;candidate.textStyles=(candidate.textStyles ?? [])+[copy]
    }
    for swatch in m.swatches {
      if sameProject,(original.swatches ?? []).contains(swatch) {swatchMap[swatch.id]=swatch.id;continue}
      guard !(original.swatches ?? []).contains(where:{$0.name.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()==swatch.name.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}) else{throw FormError.invalid("A destination swatch already uses the name \(swatch.name); no paint declaration was replaced.")}
      var copy=swatch;copy.id=UUID();swatchMap[swatch.id]=copy.id;candidate.swatches=(candidate.swatches ?? [])+[copy]
    }
    let definitions=Dictionary(uniqueKeysWithValues:m.components.map{($0.id,$0)})
    var visiting=Set<UUID>(),reused=Set<UUID>()
    func component(_ id:UUID,depth:Int)throws {
      guard depth<=8,!visiting.contains(id),let def=definitions[id] else{throw FormError.invalid("Component closure is missing, cyclic or too deep.")}
      if objectMap[id] != nil {return}
      visiting.insert(id);defer{visiting.remove(id)}
      for ref in def.artwork.elements.compactMap(\.component) {try component(ref.sourceObjectID,depth:depth+1)}
      let resourcesMatch=def.artwork.referencedSwatches.allSatisfy{swatchMap[$0]==$0} && def.artwork.referencedTextStyles.allSatisfy{styleMap[$0]==$0}
        && def.artwork.elements.compactMap(\.component).allSatisfy{objectMap[$0.sourceObjectID]==$0.sourceObjectID}
        && def.artwork.elements.compactMap(\.asset).allSatisfy{assetMap[$0]==$0}
        && (def.artwork.imports ?? []).allSatisfy{assetMap[$0.asset]==$0.asset}
      if sameProject,resourcesMatch,let current=original.objects.first(where:{$0.id==id}),current.componentDefinition==true,current.artwork==def.artwork,current.artworkSize==def.size {objectMap[id]=id;reused.insert(id)}else{objectMap[id]=UUID()}
    }
    for def in m.components {try component(def.id,depth:1)}
    let owners=[(m.ownerID,m.artwork)]+m.components.map{($0.id,$0.artwork)}
    guard Set(owners.map{$0.0}).count==owners.count else{throw FormError.invalid("The primary artwork cannot also be its component dependency.")}
    for (id,art) in owners {
      maps[id]=Dictionary(uniqueKeysWithValues:art.elements.map{($0.id,reused.contains(id) ? $0.id:UUID())})
      let ids=Set(art.elements.flatMap{($0.listItems ?? []).map(\.listID)})
      listMaps[id]=Dictionary(uniqueKeysWithValues:ids.map{($0,reused.contains(id) ? $0:UUID())})
    }
    func translated(_ art:Artwork,ownerID:UUID)throws->Artwork {
      if reused.contains(ownerID) {return art}
      var result=art;var nodeMaps=[UUID:[UUID:UUID]]()
      if let id=result.backgroundSwatchID {guard let mapped=swatchMap[id] else{throw FormError.invalid("Missing component background palette dependency.")};result.backgroundSwatchID=mapped}
      for i in result.elements.indices {
        var e=result.elements[i];let old=e.id
        e.id=maps[ownerID]![old]!
        if let parent=e.parentID {guard let mapped=maps[ownerID]![parent] else{throw FormError.invalid("Transfer parent closure is incomplete.")};e.parentID=mapped}
        if let clip=e.clipID {guard let mapped=maps[ownerID]![clip] else{throw FormError.invalid("Transfer mask closure is incomplete.")};e.clipID=mapped}
        nodeMaps[old]=PathCommands.refreshNodeIDs(in:&e)
        for n in e.sewingPiece?.notches.indices ?? 0..<0 {e.sewingPiece!.notches[n].id=UUID()}
        for n in e.gradient?.stops.indices ?? 0..<0 {e.gradient!.stops[n].id=UUID();if let id=e.gradient!.stops[n].swatchID {guard let new=swatchMap[id] else{throw FormError.invalid("Missing gradient swatch.")};e.gradient!.stops[n].swatchID=new}}
        for n in e.glyphOverrides?.indices ?? 0..<0 {e.glyphOverrides![n].id=UUID()}
        for n in e.listItems?.indices ?? 0..<0 {e.listItems![n].id=UUID();e.listItems![n].listID=listMaps[ownerID]![e.listItems![n].listID]!;e.listItems![n].resolvedNumber=nil}
        func paint(_ id:UUID?)throws->UUID? {guard let id else{return nil};guard let new=swatchMap[id] else{throw FormError.invalid("Missing palette dependency.")};return new}
        func style(_ ref:TextStyleReference?)throws->TextStyleReference? {guard var ref else{return nil};guard let new=styleMap[ref.styleID] else{throw FormError.invalid("Missing text-style dependency.")};ref.styleID=new;return ref}
        e.fillSwatchID=try paint(e.fillSwatchID);if var stroke=e.stroke {stroke.swatchID=try paint(stroke.swatchID);e.stroke=stroke};if var shadow=e.shadow {shadow.swatchID=try paint(shadow.swatchID);e.shadow=shadow}
        e.textStyle=try style(e.textStyle);e.paragraphStyle=try style(e.paragraphStyle)
        for n in e.textRuns?.indices ?? 0..<0 {e.textRuns![n].swatchID=try paint(e.textRuns![n].swatchID);e.textRuns![n].textStyle=try style(e.textRuns![n].textStyle);e.textRuns![n].paragraphStyle=try style(e.textRuns![n].paragraphStyle)}
        if var ref=e.component {
          let sourceID=ref.sourceObjectID;guard let new=objectMap[sourceID] else{throw FormError.invalid("Missing component source dependency.")};ref.sourceObjectID=new;ref.colorSwatchID=try paint(ref.colorSwatchID)
          for n in ref.overrides?.indices ?? 0..<0 {guard let target=maps[sourceID]?[ref.overrides![n].elementID] else{throw FormError.invalid("Component override target is missing from its source definition.")};ref.overrides![n].elementID=target;ref.overrides![n].colorSwatchID=try paint(ref.overrides![n].colorSwatchID)}
          e.component=ref
        }
        if let name=e.asset {guard let new=assetMap[name] else{throw FormError.invalid("Missing image bytes.")};e.asset=new}
        result.elements[i]=e
      }
      for i in result.imports?.indices ?? 0..<0 {result.imports![i].id=UUID();guard let name=assetMap[result.imports![i].asset] else{throw FormError.invalid("Missing original import bytes.")};result.imports![i].asset=name}
      for i in result.sewingSeams?.indices ?? 0..<0 {
        result.sewingSeams![i].id=UUID()
        func end(_ old:SewingSeamEnd)throws->SewingSeamEnd {var value=old;guard let new=maps[ownerID]?[old.elementID] else{throw FormError.invalid("Incomplete seam pair.")};value.elementID=new;if let id=old.edgeID {guard let new=nodeMaps[old.elementID]?[id] else{throw FormError.invalid("Missing seam edge identity.")};value.edgeID=new};if let id=old.endID {guard let new=nodeMaps[old.elementID]?[id] else{throw FormError.invalid("Missing seam endpoint guard.")};value.endID=new};return value}
        result.sewingSeams![i].first=try end(art.sewingSeams![i].first);result.sewingSeams![i].second=try end(art.sewingSeams![i].second)
      }
      if var boundary=result.boundary {for c in boundary.contours.indices {if boundary.contours[c].id != nil {boundary.contours[c].id=UUID()};for n in boundary.contours[c].nodes.indices {boundary.contours[c].nodes[n].id=UUID()}};result.boundary=boundary}
      return result
    }
    var added=[UUID]()
    for def in m.components where !reused.contains(def.id) {
      var object=ProductObject(name:def.name,recipeID:"artboard",parameters:["width":def.size.x,"depth":def.size.y,"thickness":1],artwork:try translated(def.artwork,ownerID:def.id));object.id=objectMap[def.id]!;object.componentDefinition=true;candidate.objects.append(object);added.append(object.id)
    }
    var pasted=try translated(m.artwork,ownerID:m.ownerID)
    if let boundary=pasted.boundary {
      var wrapper=ArtworkElement(kind:"group",x:0,y:0,width:boundary.width,height:boundary.height);wrapper.contentSize = .init(boundary.width,boundary.height);wrapper.name="Pasted boundary";wrapper.parentID=scopeID;wrapper.affine=placement
      var mask=ArtworkElement(kind:"path",x:0,y:0,width:boundary.width,height:boundary.height);mask.path=boundary;mask.parentID=wrapper.id
      var content=ArtworkElement(kind:"group",x:0,y:0,width:boundary.width,height:boundary.height);content.contentSize = .init(boundary.width,boundary.height);content.parentID=wrapper.id;content.clipID=mask.id
      for i in pasted.elements.indices where pasted.elements[i].parentID==nil {pasted.elements[i].parentID=content.id}
      pasted.elements += [wrapper,mask,content]
    }else {
      for i in pasted.elements.indices where pasted.elements[i].parentID==nil {pasted.elements[i].affine=placement.followed(by:pasted.elements[i].affine ?? .init());pasted.elements[i].parentID=scopeID}
    }
    target.elements += pasted.elements;target.sewingSeams=(target.sewingSeams ?? [])+(pasted.sewingSeams ?? []);if target.sewingSeams?.isEmpty==true {target.sewingSeams=nil}
    target.imports=(target.imports ?? [])+(pasted.imports ?? []);if target.imports?.isEmpty==true {target.imports=nil}
    try candidate.setArtwork(target,for:owner.id,recordingStyleOverrides:false);try candidate.validateArtworkLinks()
    return .init(baseProject:original,project:candidate,selection:Set(m.selection.compactMap{maps[m.ownerID]?[$0]}),addedComponentIDs:added,assetWrites:writes,assetMap:assetMap,elementMaps:maps)
  }
}

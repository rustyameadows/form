import AppKit
import FormCore
import FormGraphics

struct CanvasPublicationSpread {
  let publicationID: UUID
  let spreadID: UUID
  let frameOrder: [UUID]
  let pageRects: [CGRect]
  var id: UUID { ComponentCommands.derivedID(publicationID,spreadID) }
  var frameIDs: Set<UUID> { Set(frameOrder) }
  var bounds: CGRect { pageRects.reduce(CGRect.null){$0.union($1)} }
}
struct CanvasPublicationSubstrate: Equatable {
  var color: String
  var opacity: Double
}

@MainActor enum CanvasPublicationSpreads {
  /// View geometry only: never rewrite source placement when opening, closing,
  /// navigating or reopening a publication. The rail owns no layout state.
  static func applying(to frames:[CanvasFrame],project:Project)->[CanvasFrame] {
    let canonical=Dictionary(frames.filter{$0.projection==nil}.map{($0.object.id,$0)},uniquingKeysWith:{first,_ in first})
    var replacement=[UUID:CanvasFrame]()
    for document in project.publications ?? [] where document.layout?.facingPages==true {
      let sources=document.pages.compactMap{canonical[$0.objectID]}
      guard let anchorX=sources.map(\.rect.minX).min(),let anchorY=sources.map(\.rect.minY).min() else{continue}
      let x=Double(anchorX);var y=Double(anchorY)
      for geometry in project.publicationReaderSpreads(document.id) {
        let shift=geometry.pages.count==1 && geometry.pages.first.map{document.side(of:$0.objectID) == .recto}==true
          ? geometry.sizeMM.x:0
        let rects=geometry.pages.map{page in CGRect(x:x+shift+page.originMM.x,y:y+page.originMM.y,width:page.sizeMM.x,height:page.sizeMM.y)}
        let spread=CanvasPublicationSpread(publicationID:document.id,spreadID:geometry.spreadID,
          frameOrder:geometry.pages.map(\.objectID),pageRects:rects)
        for (page,rect) in zip(geometry.pages,rects) {
          guard var frame=canonical[page.objectID] else{continue}
          frame.rect=rect;frame.publicationSpread=spread;replacement[frame.id]=frame
        }
        y += geometry.sizeMM.y+44
      }
    }
    var emitted=Set<UUID>(),result=[CanvasFrame]()
    for original in frames {
      guard let frame=replacement[original.id],let spread=frame.publicationSpread else{result.append(original);continue}
      if emitted.insert(spread.id).inserted {result += spread.frameOrder.compactMap{replacement[$0]}}
    }
    return result
  }
  static func sharesSpread(_ first:CanvasFrame?,_ second:CanvasFrame?)->Bool {
    guard let id=first?.publicationSpread?.id else{return false}
    return second?.publicationSpread?.id==id
  }
  static func clip(for frame:CanvasFrame)->CGPath? {
    guard let spread=frame.publicationSpread else{return nil}
    let path=CGMutablePath()
    for rect in spread.pageRects {path.addRect(rect.offsetBy(dx:-frame.rect.minX,dy:-frame.rect.minY))}
    return path
  }
  static func canonicalArtwork(_ frame:CanvasFrame,project:Project)->Artwork {
    project.removingPublicationFurniture(from:frame.artwork,objectID:frame.object.id)
  }
  static func furniture(_ frame:CanvasFrame,project:Project,behind:Bool)->Artwork {
    var result=frame.artwork;result.elements=[]
    guard let document=project.publicationDocument(for:frame.object.id),let page=document.pages.first(where:{$0.objectID==frame.object.id}) else{return result}
    let roots=Set(document.appliedMasters(for:frame.object.id).filter{$0.behind==behind}.map{ComponentCommands.derivedID(page.id,$0.id)})
    let ids=frame.artwork.descendants(of:roots).union(roots)
    result.elements=frame.artwork.elements.filter{ids.contains($0.id)};return result
  }
  static func substrate(for frame:CanvasFrame,project:Project)->CanvasPublicationSubstrate? {
    guard let document=project.publicationDocument(for:frame.object.id),let page=document.pages.first(where:{$0.objectID==frame.object.id}) else{return nil}
    let assemblies=project.objects.filter{$0.sheetAssembly?.publicationID==document.id}
    guard !assemblies.isEmpty else{return nil}
    var agreed:CanvasPublicationSubstrate?
    for assembly in assemblies {
      let stock:PaperStock,inside:Bool
      if let parent=try? project.parentSheet(forPageObjectID:frame.object.id,in:assembly) {
        stock=parent.stock;inside=parent.backPageIDs.contains(page.id)
      }else if let leaf=(try? project.resolvedSheetAssembly(assembly))?.leaves.first(where:{$0.frontPageID==page.id || $0.backPageID==page.id}) {
        stock=leaf.stock;inside=leaf.backPageID==page.id
      }else{return nil}
      let face=PaperGeometry.faceAppearance(for:frame.object,stock:stock,project:project,inside:inside)
      let candidate=CanvasPublicationSubstrate(color:face.resolvedColor,opacity:face.profile.opacity)
      if let agreed,agreed != candidate{return nil};agreed=candidate
    }
    return agreed
  }
  static func drawBackdrops(_ frames:[CanvasFrame],project:Project,context:CGContext,scale:Double) {
    for frame in frames where frame.publicationSpread != nil {
      context.saveGState()
      context.setShadow(offset:.init(width:0,height:2/scale),blur:9/scale,color:NSColor.black.withAlphaComponent(0.13).cgColor)
      context.setFillColor(NSColor.white.cgColor);context.fill(frame.rect);context.restoreGState()
      if let stock=substrate(for:frame,project:project) {
        context.setFillColor(FormColor.color(stock.color).withAlphaComponent(stock.opacity).cgColor);context.fill(frame.rect)
      }
      context.setFillColor(FormColor.color(frame.artwork.background).withAlphaComponent(frame.artwork.backgroundOpacity ?? 1).cgColor)
      context.fill(frame.rect)
    }
  }
  static func drawFurniture(_ frames:[CanvasFrame],project:Project,assets:URL,context:CGContext,behind:Bool) {
    for frame in frames where frame.publicationSpread != nil {
      let artwork=furniture(frame,project:project,behind:behind)
      guard !artwork.elements.isEmpty else{continue}
      context.saveGState();context.clip(to:frame.rect);context.translateBy(x:frame.rect.minX,y:frame.rect.minY)
      ArtworkRenderer.draw(artwork,width:frame.rect.width,height:frame.rect.height,assets:assets,production:false,unbounded:true)
      context.restoreGState()
    }
  }
  static func drawGuides(_ frames:[CanvasFrame],project:Project,activeFrameID:UUID?,context:CGContext,scale:Double) {
    var drawn=Set<UUID>()
    for frame in frames {
      guard let spread=frame.publicationSpread,drawn.insert(spread.id).inserted else{continue}
      context.saveGState();context.setLineWidth(0.75/scale)
      context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.8).cgColor)
      for rect in spread.pageRects {context.stroke(rect)}
      if let activeFrameID,spread.frameIDs.contains(activeFrameID) {
        context.setStrokeColor(Palette.accentNS.withAlphaComponent(0.7).cgColor);context.setLineWidth(1.25/scale)
        context.stroke(spread.bounds)
      }
      context.restoreGState()
    }
    for frame in frames where frame.publicationSpread != nil && frame.artwork.showGuides != false {
      guard let document=project.publicationDocument(for:frame.object.id) else{continue}
      let margins=document.resolvedMargins(for:frame.object.id)
      let rect=CGRect(x:frame.rect.minX+margins.left,y:frame.rect.minY+margins.top,
        width:frame.rect.width-margins.left-margins.right,height:frame.rect.height-margins.top-margins.bottom)
      guard rect.width>0,rect.height>0 else{continue}
      context.saveGState();context.setStrokeColor(Palette.accentNS.withAlphaComponent(0.25).cgColor)
      context.setLineWidth(0.6/scale);context.setLineDash(phase:0,lengths:[3/scale,3/scale]);context.stroke(rect);context.restoreGState()
    }
  }
  /// Picking a visible overflow returns its real canonical owner, including
  /// when the pointer is on the other physical half of the spread.
  static func artworkFrame(at point:CGPoint,frames:[CanvasFrame],session:ArtworkSession,tolerance:Double,scale:Double=1)->CanvasFrame? {
    guard let project=session.store?.project else{return nil}
    for frame in frames.reversed() {
      guard !frame.isWorkspace else{continue}
      let header=CanvasFrameChrome.headerRect(for:frame,scale:max(0.001,scale))
      if frame.publicationSpread==nil {
        // Ordinary artboards paint an opaque rectangular backdrop before their
        // clipped content. Respect that visible draw order, including an empty
        // or transparent source, before considering underlying spread overflow.
        if frame.rect.contains(point) || header.contains(point) {return nil}
        continue
      }
      if header.contains(point),!frame.rect.contains(point) {return nil}
      guard frame.editable,frame.publicationSpread!.pageRects.contains(where:{$0.contains(point)}) else{continue}
      let art=project.editableArtwork(frame.object) ?? canonicalArtwork(frame,project:project)
      let local=CGPoint(x:point.x-frame.rect.minX,y:point.y-frame.rect.minY)
      let scope=frame.id==session.activeFrameID ? session.scopeID:nil
      if ArtworkHitTesting.hit(at:local,in:art,scope:scope,tolerance:tolerance,
        excluding:ArtworkProduction.hiddenIDs(in:frame.artwork,roles:session.hiddenProductionRoles),
        renderedArtwork:canonicalArtwork(frame,project:project),outerClip:clip(for:frame),assets:session.assets) != nil {return frame}
    }
    return nil
  }
}

import AppKit
import FormCore

/// The native Canvas only lays out Core's canonical physical source descriptors.
/// MCP artwork frames and native pattern/surface editing share the same crop,
/// reverse orientation, ownership and material authority.
@MainActor enum CanvasConstructionPieces {
  static func frames(object:ProductObject,paper:PaperConstruction,net:PaperNet,project:Project,startY:Double)->[CanvasFrame] {
    guard let descriptors=try? ConstructionArtworkProjection.resolveAll(in:project,object:object,paper:paper,net:net) else{return []}
    let technical:[ConstructionArtworkTechnicalPath],technicalReview:String?
    do{technical=try CanvasConstructionTechnicalGuides.paths(paper,net:net);technicalReview=nil}
    catch{technical=[];technicalReview="Construction guides need review: "+error.localizedDescription}
    var result=[CanvasFrame](),y=startY,x=36.0,rowHeight=0.0,group:String?
    var artworkSources=[String:Artwork]()
    for descriptor in descriptors {
      let nextGroup=descriptor.componentID+":"+String(descriptor.inside)
      if group != nextGroup {
        if group != nil {y+=rowHeight+76}
        group=nextGroup;x=36;rowHeight=0
      }
      guard let source=project.objects.first(where:{$0.id==descriptor.sourceObjectID}) else{continue}
      let sourceKey=source.id.uuidString+":"+String(descriptor.requiresInsideSource)
      let art:Artwork
      if let cached=artworkSources[sourceKey] {art=cached}
      else {
        var blank=Artwork(background:"#FFFFFF");blank.backgroundOpacity=0
        let raw=descriptor.artwork(in:project) ?? blank
        let text=project.resolvingTextStories(in:raw,objectID:source.id)
        art=(try? project.resolvingComponents(in:text)) ?? text;artworkSources[sourceKey]=art
      }
      let frame=descriptor.frame
      let projection=CanvasSourceProjection(constructionID:object.id,sourceID:source.id,panelID:descriptor.panelID,inside:descriptor.inside,
        title:descriptor.title,size:frame.size,sourceToLocal:frame.sourceToLocal,boundary:frame.boundary,cutouts:frame.cutouts,
        requiresInsideSource:descriptor.requiresInsideSource,componentID:descriptor.componentID)
      let position=object.canvasProjectionPositions?[projection.key] ?? .init(x,y)
      result.append(.init(object:source,surfaceObject:object,
        rect:.init(x:position.x,y:position.y,width:projection.size.x,height:projection.size.y),artwork:projection.display(art),
        sourceReview:technicalReview,projection:projection,paperDefinition:paper,paperNet:descriptor.sourceNet,physicalStock:descriptor.stock,
        constructionTechnicalPaths:descriptor.technicalPaths(technical)))
      rowHeight=max(rowHeight,projection.size.y);x+=projection.size.x+42
      if x>1600 {x=36;y+=rowHeight+56;rowHeight=0}
    }
    return result
  }
}

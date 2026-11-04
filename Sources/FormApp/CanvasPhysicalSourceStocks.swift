import AppKit
import FormCADModel
import FormCore
import FormGraphics

/// Display-only physical substrate in canonical source millimeters. Printed
/// artwork, export pixels, source backgrounds and document history stay separate.
struct CanvasPhysicalSourceStockRegion:Equatable {
  var rect:CGRect
  var color:String
  var opacity:Double
}

@MainActor final class CanvasPhysicalSourceStockCache {
  private struct ObjectInput:Equatable {
    var id:UUID,recipeID:String,parameters:[String:Double]
    var source:UUID?,color:String?,materialColor:String
    var paper:PaperConstruction?,sheets:SheetAssemblyDefinition?
  }
  private struct PageInput:Equatable {var id:UUID,objectID:UUID}
  private struct PublicationInput:Equatable {var id:UUID,pages:[PageInput],firstSide:PublicationPageSide?}
  private struct Inputs:Equatable {var projectID:UUID,objects:[ObjectInput],publications:[PublicationInput]}
  private struct Candidate {var sourceID:UUID,rect:CGRect,color:String,opacity:Double}
  private var request:(engine:ObjectIdentifier,generation:UInt64,projectID:UUID)?
  private var input:Inputs?
  private var index:[UUID:[CanvasPhysicalSourceStockRegion]]=[:]
  private(set) var builds=0,hits=0
  private let maximumCandidatesPerSource=512,maximumRegionsPerSource=4096
  var count:Int {index.count}
  func clear(){request=nil;input=nil;index=[:]}

  func regions(for frame:CanvasFrame,store:StudioStore?)->[CanvasPhysicalSourceStockRegion] {
    // Logical reader-page backdrops already use their publication substrate.
    // Projected physical faces retain the existing direct paper appearance path.
    guard let store,let project=store.project,frame.projection==nil,
      frame.publicationSpread==nil,!frame.isWorkspace,!PaperConstruction.isPaper(frame.object) else{return []}
    let next=(ObjectIdentifier(store.engine),store.engine.projectGeneration,project.id)
    if let request,request.engine==next.0,request.generation==next.1,request.projectID==next.2 {
      hits+=1;return clipped(index[frame.object.id] ?? [],to:CGRect(origin:.zero,size:frame.rect.size))
    }
    let result=regions(for:frame.object.id,in:project)
    request=(next.0,next.1,next.2)
    return clipped(result,to:CGRect(origin:.zero,size:frame.rect.size))
  }
  /// Also useful to native previews/tests without a mounted document engine.
  /// A compact structural signature excludes words, artwork paints and cameras.
  func regions(for sourceObjectID:UUID,in project:Project)->[CanvasPhysicalSourceStockRegion] {
    let current=inputs(project)
    if input==current {hits+=1;return index[sourceObjectID] ?? []}
    request=nil;input=current;builds+=1
    index=build(project)
    return index[sourceObjectID] ?? []
  }
  private func inputs(_ project:Project)->Inputs {
    let objects=project.objects.map {object -> ObjectInput in
      var paper=object.paperConstruction
      paper?.insideArtwork=nil;paper?.finishes=nil;paper?.annotations=[]
      paper?.artworkReviewRequired=false;paper?.artworkReferenceSize=nil
      return .init(id:object.id,recipeID:object.recipeID,parameters:object.parameters,
        source:object.artworkSourceID,color:object.color,materialColor:project.material(object.materialID).color,
        paper:paper,sheets:object.sheetAssembly)
    }
    let publications=(project.publications ?? []).map {document in
      PublicationInput(id:document.id,pages:document.pages.map{.init(id:$0.id,objectID:$0.objectID)},firstSide:document.layout?.firstPageSide)
    }
    return .init(projectID:project.id,objects:objects,publications:publications)
  }
  private func build(_ project:Project)->[UUID:[CanvasPhysicalSourceStockRegion]] {
    var candidates=[UUID:[Candidate]](),overflow=Set<UUID>(),totalCandidates=0
    var exceededBudget=false
    func append(_ sourceID:UUID,rect:CGRect,stock:PaperStock,consumer:ProductObject,inside:Bool) {
      guard !exceededBudget,rect.width>0,rect.height>0,[rect.minX,rect.minY,rect.width,rect.height].allSatisfy(\.isFinite),
        !overflow.contains(sourceID) else{return}
      if (candidates[sourceID]?.count ?? 0)>=maximumCandidatesPerSource {candidates[sourceID]=nil;overflow.insert(sourceID);return}
      guard totalCandidates<32768,candidates[sourceID] != nil || candidates.count<2048 else{exceededBudget=true;return}
      totalCandidates+=1
      let appearance=PaperGeometry.faceAppearance(for:consumer,stock:stock,project:project,inside:inside)
      candidates[sourceID,default:[]].append(.init(sourceID:sourceID,rect:rect,color:appearance.resolvedColor.uppercased(),opacity:appearance.profile.opacity))
    }
    func appendFace(_ face:ResolvedSheetAssemblyFace?,size:Point2,stock:PaperStock,consumer:ProductObject,inside:Bool,margin:Double=0) {
      guard let face,let source=project.objects.first(where:{$0.id==face.sourceObjectID}) else{return}
      let owner:ProductObject
      if face.sourceSide == .inside,PaperConstruction.isPaper(source) {
        guard let id=source.paperConstruction?.insideArtworkSourceID,let linked=project.objects.first(where:{$0.id==id}) else{return}
        owner=project.artworkOwner(linked)
      }else{owner=project.artworkOwner(source)}
      append(owner.id,rect:.init(x:face.originMM.x-margin,y:face.originMM.y-margin,width:size.x+2*margin,height:size.y+2*margin),
        stock:stock,consumer:consumer,inside:inside)
    }
    for consumer in project.objects where consumer.sheetAssembly != nil {
      guard let resolved=try? project.resolvedSheetAssembly(consumer,validateSourceCrops:false) else{continue}
      for leaf in resolved.leaves where leaf.auxiliaryID != nil {
        appendFace(leaf.front,size:leaf.size,stock:leaf.stock,consumer:consumer,inside:false)
        appendFace(leaf.back,size:leaf.size,stock:leaf.stock,consumer:consumer,inside:true)
      }
      for plane in resolved.enclosure {
        if let wrap=plane.features?.wrap {
          appendFace(plane.front,size:plane.size,stock:wrap.stock,consumer:consumer,inside:false,
            margin:plane.stock.resolvedThicknessMM+wrap.turnInMM)
        }else{appendFace(plane.front,size:plane.size,stock:plane.stock,consumer:consumer,inside:false)}
        appendFace(plane.back,size:plane.size,stock:plane.stock,consumer:consumer,inside:true)
        for recess in plane.features?.recesses ?? [] {
          if let insert=recess.insert {appendFace(insert.face,size:recess.size,stock:insert.stock,consumer:consumer,inside:false)}
        }
      }
    }
    for consumer in project.objects where PaperConstruction.isPaper(consumer) {
      guard let paper=try? PaperConstruction.definition(for:consumer),let net=try? paper.net() else{continue}
      let owner=project.artworkOwner(consumer)
      let insideOwner=paper.insideArtworkSourceID.flatMap{id in project.objects.first{$0.id==id}}.map{project.artworkOwner($0)}
      let base=(try? paper.authored?.resolvedValues()) ?? [:]
      let variables=base.merging(["fold":paper.foldPercent,"opening":paper.openingPercent]){_,new in new}
      for panel in net.panels {
        let bounds=panel.bounds,size=Point2(bounds.width,bounds.height)
        let physical=try? panel.features?.resolved(size:size,stock:paper.stock,variables:variables,face:{declaration,_ in
          guard let declaration else{return nil}
          let origin=try declaration.sourceOriginMM.map{Point2(
            try CADExpression.evaluate($0.x.expression,variables:variables),try CADExpression.evaluate($0.y.expression,variables:variables))} ?? .init()
          return .init(sourceObjectID:declaration.sourceObjectID,sourceSide:declaration.sourceSide,originMM:origin)
        })
        let core=physical?.0 ?? paper.stock
        if let wrap=physical?.1.wrap {
          let margin=core.resolvedThicknessMM+wrap.turnInMM
          append(owner.id,rect:CGRect(x:bounds.x,y:bounds.y,width:bounds.width,height:bounds.height).insetBy(dx:-margin,dy:-margin),
            stock:wrap.stock,consumer:consumer,inside:false)
        }else{append(owner.id,rect:.init(x:bounds.x,y:bounds.y,width:bounds.width,height:bounds.height),stock:core,consumer:consumer,inside:false)}
        if let insideOwner {append(insideOwner.id,rect:.init(x:bounds.x,y:bounds.y,width:bounds.width,height:bounds.height),stock:core,consumer:consumer,inside:true)}
        for recess in physical?.1.recesses ?? [] {
          if let insert=recess.insert {appendFace(insert.face,size:recess.size,stock:insert.stock,consumer:consumer,inside:false)}
        }
      }
    }
    guard !exceededBudget else{return [:]}
    var result=[UUID:[CanvasPhysicalSourceStockRegion]](),totalRegions=0
    for (source,uses) in candidates {
      // Paint each agreed region once, including translucent stock. A conflicting
      // overlap remains neutral instead of selecting an arbitrary physical use.
      var regions=[CanvasPhysicalSourceStockRegion](),excessive=false
      for (index,use) in uses.enumerated() {
        var pieces=[use.rect]
        for (otherIndex,other) in uses.enumerated() where otherIndex != index {
          let same=use.color==other.color && use.opacity==other.opacity
          if same && otherIndex>index {continue}
          pieces=pieces.flatMap{subtract($0,other.rect)}
          if pieces.count+regions.count>maximumRegionsPerSource {excessive=true;break}
          if pieces.isEmpty {break}
        }
        if excessive {break}
        regions+=pieces.map{.init(rect:$0,color:use.color,opacity:use.opacity)}
      }
      if !excessive {
        totalRegions+=regions.count
        guard totalRegions<=32768 else{return [:]}
        result[source]=regions
      }
    }
    return result
  }
  private func subtract(_ rect:CGRect,_ removal:CGRect)->[CGRect] {
    let hit=rect.intersection(removal)
    guard !hit.isNull,hit.width>0,hit.height>0 else{return [rect]}
    return [CGRect(x:rect.minX,y:rect.minY,width:rect.width,height:hit.minY-rect.minY),
      CGRect(x:rect.minX,y:hit.maxY,width:rect.width,height:rect.maxY-hit.maxY),
      CGRect(x:rect.minX,y:hit.minY,width:hit.minX-rect.minX,height:hit.height),
      CGRect(x:hit.maxX,y:hit.minY,width:rect.maxX-hit.maxX,height:hit.height)].filter{$0.width>1e-10 && $0.height>1e-10}
  }
  private func clipped(_ regions:[CanvasPhysicalSourceStockRegion],to bounds:CGRect)->[CanvasPhysicalSourceStockRegion] {
    regions.compactMap{region in
      let rect=region.rect.intersection(bounds)
      return rect.isNull || rect.isEmpty ? nil:.init(rect:rect,color:region.color,opacity:region.opacity)
    }
  }
  static func draw(_ regions:[CanvasPhysicalSourceStockRegion],in context:CGContext) {
    context.saveGState();defer{context.restoreGState()}
    context.setShouldAntialias(false)
    for region in regions {
      context.setFillColor(FormColor.color(region.color).withAlphaComponent(region.opacity).cgColor)
      context.fill(region.rect)
    }
  }
}

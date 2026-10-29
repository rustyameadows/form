import Foundation
import FormCADModel

/// A named physical surface references the same independent artwork source used by Canvas.
public struct PhysicalSurfaceArtworkBinding: Codable, Equatable, Sendable {
  public var surfaceID: String
  public var sourceObjectID: UUID?
  public var artwork: Artwork?
  /// Frozen publication composition belongs to this detached consumer. Runtime
  /// frame references alone are not persisted by Artwork's ordinary encoding.
  public var detachedSourceObjectID:UUID?
  public var storySnapshots:[ResolvedTextStory]?
  public var widthMM: Double
  public var heightMM: Double
  public init(surfaceID:String,sourceObjectID:UUID,widthMM:Double,heightMM:Double) {
    self.surfaceID=surfaceID;self.sourceObjectID=sourceObjectID;self.widthMM=widthMM;self.heightMM=heightMM
  }
}

/// Review information only: changing a frame never silently scales its artwork.
public struct PhysicalSurfaceArtworkPlacementIssue: Codable, Equatable, Identifiable, Sendable {
  public var objectID:UUID
  public var surfaceID:String
  public var sourceObjectID:UUID?
  public var code:String
  public var message:String
  public var boundSourceSizeMM:Point2
  public var currentSourceSizeMM:Point2?
  public var surfaceSizeMM:Point2?
  public var id:String {objectID.uuidString+"/"+surfaceID+"/"+code}
}

extension Project {
  public func physicalSurfaceArtwork(_ binding:PhysicalSurfaceArtworkBinding)->Artwork? {
    if let id=binding.sourceObjectID,let source=objects.first(where:{$0.id==id}) {return surfaceArtwork(source)}
    guard let art=binding.artwork else{return nil}
    var expanded=(try? resolvingComponents(in:art,keepingSwatchReferences:true)) ?? art
    for i in expanded.elements.indices {
      guard var reference=expanded.elements[i].storyFrame,
        var snapshot=binding.storySnapshots?.first(where:{$0.story.id==reference.storyID}),
        let sourceID=binding.detachedSourceObjectID else{continue}
      let source=resolvingSwatches(in:Artwork(elements:[snapshot.story.sourceElement]),keepingReferences:true).elements[0]
      snapshot.story.setSource(source);reference.resolved=snapshot
      reference.frame = .init(objectID:sourceID,elementID:expanded.elements[i].id)
      expanded.elements[i].storyFrame=reference
    }
    expanded.requiresInkOutput=hasUsedProductionInks(in:expanded)
    return resolvingSwatches(in:expanded)
  }
  /// A preview supplies its newly resolved surfaces while keeping the original
  /// target's bindings. Published objects use their saved representation.
  public func physicalSurfaceArtworkPlacementIssues(
    for object:ProductObject,surfaces:[CADResolvedPlanarSurface]?=nil
  )->[PhysicalSurfaceArtworkPlacementIssue] {
    let resolved=surfaces ?? object.cadRepresentation?.resolvedSurfaces ?? []
    let tolerance=0.000001
    var issues:[PhysicalSurfaceArtworkPlacementIssue]=[]
    for binding in object.surfaceArtworkBindings ?? [] {
      let bound=Point2(binding.widthMM,binding.heightMM)
      let current=binding.sourceObjectID.flatMap{id in objects.first{$0.id==id}}.map(\.artworkSize)
      let surface=resolved.first{$0.id==binding.surfaceID}
      let target=surface.map{Point2($0.width,$0.height)}
      func append(_ code:String,_ message:String) {
        issues.append(.init(objectID:object.id,surfaceID:binding.surfaceID,sourceObjectID:binding.sourceObjectID,
          code:code,message:message,boundSourceSizeMM:bound,currentSourceSizeMM:current,surfaceSizeMM:target))
      }
      if let current,abs(current.x-bound.x)>tolerance || abs(current.y-bound.y)>tolerance {
        append("source_frame_changed","The source artboard size changed since binding. Artwork keeps its saved physical scale; review this placement.")
      }
      guard let target else {
        append("unresolved_surface","The bound physical surface is missing or unresolved. Resolve it or explicitly unbind its artwork before applying the model.")
        continue
      }
      if max(bound.x,current?.x ?? bound.x)>target.x+tolerance ||
         max(bound.y,current?.y ?? bound.y)>target.y+tolerance {
        append("source_exceeds_surface","The physical artwork frame exceeds the declared surface and may be clipped. Review this placement; artwork has not been resized.")
      }
    }
    return issues
  }
  public func validatePhysicalSurfaceBindings()throws {
    for object in objects {
      guard let bindings=object.surfaceArtworkBindings else{continue}
      guard bindings.count<=128,Set(bindings.map(\.surfaceID)).count==bindings.count,object.cadModel != nil else {throw FormError.invalid("Physical surface bindings require unique named surfaces on an exact model.")}
      for binding in bindings {
        guard !binding.surfaceID.isEmpty,binding.surfaceID.utf8.count<=128,
          binding.widthMM.isFinite,binding.heightMM.isFinite,binding.widthMM>0,binding.heightMM>0,
          binding.widthMM<=10000,binding.heightMM<=10000 else{throw FormError.invalid("Physical surface artwork must retain its finite physical source size.")}
        if let id=binding.sourceObjectID {
          guard binding.artwork==nil,binding.detachedSourceObjectID==nil,binding.storySnapshots==nil,
            id != object.id,let source=objects.first(where:{$0.id==id}),
            isIndependentFlatArtworkSource(source),!source.isCanvasWorkspace,source.artworkSourceID==nil,source.artwork != nil else {
            throw FormError.invalid("A physical surface must reference an independent artwork frame in this project.")
          }
        }else{
          guard let art=binding.artwork else{throw FormError.invalid("A detached surface must retain its artwork source.")}
          try validateArtwork(art)
          let stories=binding.storySnapshots ?? [],references=art.elements.compactMap(\.storyFrame)
          guard stories.count<=128,Set(stories.map{$0.story.id}).count==stories.count,
            stories.reduce(0,{$0+$1.story.text.utf8.count})<=4_000_000,
            stories.reduce(0,{$0+$1.frames.count})<=4096,
            Set(stories.map{$0.story.id})==Set(references.map(\.storyID)),
            references.isEmpty || binding.detachedSourceObjectID != nil,
            art.elements.allSatisfy({$0.component==nil}) else {
            throw FormError.invalid("Detached physical artwork requires complete unique local story snapshots (up to 4 MB text / 4096 frames) and resolved component content.")
          }
          for snapshot in stories {
            let story=snapshot.story
            guard !story.name.isEmpty,story.name.count<=500,story.text.count<=100000,
              !story.frames.isEmpty,story.frames.count<=400,Set(story.frames).count==story.frames.count,
              story.frames==snapshot.frames.map(\.frame),snapshot.baselineGrid?.valid != false,
              snapshot.frames.allSatisfy({$0.width.isFinite && $0.height.isFinite && $0.width>0 && $0.height>0
                && $0.width<=10000 && $0.height<=10000 && $0.pageY.isFinite && abs($0.pageY)<=100000}) else {
              throw FormError.invalid("Detached story snapshots must retain bounded source text and complete finite ordered frame geometry.")
            }
            try ParagraphLanguage.validate(story.language);try ParagraphLanguage.validate(snapshot.language)
            try validateArtwork(Artwork(elements:[story.sourceElement]),maxTextCharacters:100000)
          }
          for element in art.elements {
            if let ref=element.storyFrame {
              guard element.kind=="text",element.text.isEmpty,element.textRuns==nil,element.glyphOverrides==nil,element.listItems==nil,
                let sourceID=binding.detachedSourceObjectID,
                let snapshot=stories.first(where:{$0.story.id==ref.storyID}),
                snapshot.frames.contains(where:{$0.frame == .init(objectID:sourceID,elementID:element.id)}) else {
                throw FormError.invalid("A detached story frame must reference its original frozen source frame.")
              }
            }
          }
        }
      }
    }
  }
  public mutating func detachPhysicalSurfaceConsumers(of ids:Set<UUID>) {
    let snapshot=self
    for i in objects.indices where !ids.contains(objects[i].id) {
      guard var bindings=objects[i].surfaceArtworkBindings else{continue}
      for j in bindings.indices {
        if let sourceID=bindings[j].sourceObjectID,ids.contains(sourceID),let source=snapshot.objects.first(where:{$0.id==sourceID}) {
          bindings[j].artwork=snapshot.surfaceArtwork(source,keepingSwatchReferences:true)
          let references=bindings[j].artwork?.elements.compactMap(\.storyFrame) ?? []
          let stories=Dictionary(references.compactMap{ref -> (UUID,ResolvedTextStory)? in
            guard let resolved=ref.resolved ?? snapshot.resolvedTextStory(ref.storyID) else{return nil}
            return (ref.storyID,resolved)
          },uniquingKeysWith:{first,_ in first})
          bindings[j].storySnapshots=stories.isEmpty ? nil:stories.values.sorted{$0.story.id.uuidString<$1.story.id.uuidString}
          bindings[j].detachedSourceObjectID=references.isEmpty ? nil:sourceID
          bindings[j].artwork?.requiresInkOutput=false
          for k in bindings[j].artwork?.elements.indices ?? 0..<0 {
            bindings[j].artwork?.elements[k].storyFrame?.resolved=nil
            bindings[j].artwork?.elements[k].storyFrame?.frame=nil
          }
          bindings[j].sourceObjectID=nil
        }
      }
      objects[i].surfaceArtworkBindings=bindings
    }
  }
}

public enum PhysicalSurfaceCommands {
  public static func isReadOnly(_ args:[String:Any])->Bool {(args["command"] as? String ?? "inspect") == "inspect"}
  public static func call(engine:OperationEngine,arguments args:[String:Any],source:String)throws->Any {
    let command=args["command"] as? String ?? "inspect"
    if ["set_intent","clear_intent"].contains(command) {
      return try PhysicalArtworkIntentCommands.call(engine:engine,arguments:args,source:source)
    }
    guard ["inspect","bind","unbind"].contains(command),Set(args.keys).isSubset(of:["command","object_id","surface_id","source_object_id"]),
      let project=engine.project,let raw=args["object_id"] as? String,let id=UUID(uuidString:raw),let object=project.objects.first(where:{$0.id==id}) else{throw FormError.invalid("Choose an existing object and a surface command.")}
    if command=="inspect" {
      if let representation=object.cadRepresentation {
        let surfaces=representation.resolvedSurfaces ?? []
        let missing=(object.surfaceArtworkBindings ?? []).filter{b in !surfaces.contains{$0.id==b.surfaceID}}
        return ["object_id":raw,"surfaces":try jsonObject(surfaces),"bindings":try jsonObject(object.surfaceArtworkBindings ?? []),
          "unresolved_bindings":missing.map(\.surfaceID),
          "surface_artwork_issues":try jsonObject(project.physicalSurfaceArtworkPlacementIssues(for:object)),
          "artwork_intent":try jsonObject(project.physicalArtworkIntentReport(for:object)),
          "units":"mm"] as [String:Any]
      }
      if PaperConstruction.isPaper(object) {
        let net=try PaperConstruction.definition(for:object).net()
        return ["object_id":raw,"surfaces":try jsonObject(net.panels),"source_object_id":project.artworkOwner(object).id.uuidString,
          "artwork_intent":try jsonObject(project.physicalArtworkIntentReport(for:object)),"units":"mm"] as [String:Any]
      }
      return ["object_id":raw,"source_object_id":project.artworkOwner(object).id.uuidString,"size_mm":[object.artworkSize.x,object.artworkSize.y],
        "artwork_intent":try jsonObject(project.physicalArtworkIntentReport(for:object)),"units":"mm"] as [String:Any]
    }
    guard !object.locked,let surface=args["surface_id"] as? String,object.cadModel != nil else{throw FormError.invalid("Choose an unlocked model and a named surface.")}
    var next=object.surfaceArtworkBindings ?? []
    if command=="bind" {
      guard object.cadRepresentation?.resolvedSurfaces?.contains(where:{$0.id==surface}) == true,
        let rawSource=args["source_object_id"] as? String,let sourceID=UUID(uuidString:rawSource),
        let artworkSource=project.objects.first(where:{$0.id==sourceID}),project.isIndependentFlatArtworkSource(artworkSource),!artworkSource.isCanvasWorkspace,
        artworkSource.artworkSourceID==nil,artworkSource.artwork != nil else{throw FormError.invalid("Choose a resolved physical surface and an independent artwork frame.")}
      next.removeAll{$0.surfaceID==surface}
      next.append(.init(surfaceID:surface,sourceObjectID:sourceID,widthMM:artworkSource.artworkSize.x,heightMM:artworkSource.artworkSize.y))
    }else{next.removeAll{$0.surfaceID==surface}}
    try engine.edit("Changed physical surface artwork",source:source){p in
      guard let i=p.objects.firstIndex(where:{$0.id==id}) else{throw FormError.missing("Model missing.")}
      p.objects[i].surfaceArtworkBindings=next.isEmpty ? nil:next
    }
    return try jsonObject(next)
  }
}

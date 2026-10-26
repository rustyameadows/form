import Foundation

public enum GarmentBlockCommands {
  public static let readOperations=["list","get","report"]
  public static func isReadOnly(_ arguments:[String:Any])->Bool {
    guard arguments["command"] as? String == "garment_block" else {return false}
    if arguments["operation"] == nil {return true}
    guard let operation=arguments["operation"] as? String else {return false}
    return readOperations.contains(operation)
  }
  private static func operation(_ arguments:[String:Any],fallback:String)throws->String {
    guard let value=arguments["operation"] else {return fallback}
    guard let operation=value as? String else {throw FormError.invalid("Garment operation must be a named string.")}
    return operation
  }
  public static func definition(_ block:GarmentBlock)throws->[String:Any] {
    var result=try jsonObject(block) as! [String:Any]
    result.removeValue(forKey:"bindings");result.removeValue(forKey:"seams")
    return result
  }
  private static func decode(_ value:Any?,base:GarmentBlock?,creating:Bool)throws->GarmentBlock {
    let defaults=base ?? GarmentBlock()
    guard let value else {return defaults}
    guard let fields=value as? [String:Any],Set(fields.keys).isSubset(of:["id","recipe","recipeVersion","name","body","style","grade","sizes","baseSizeID"]) else {
      throw FormError.invalid("Provide a garment-block definition, excluding server-owned source bindings and seams.")
    }
    var result=try definition(defaults)
    for (key,raw) in fields {
      if ["body","style","grade"].contains(key) {
        guard let child=raw as? [String:Any],var original=result[key] as? [String:Any],Set(child.keys).isSubset(of:Set(original.keys).union(key == "style" ? ["materialID","elasticMaterialID"]:[])) else {
          throw FormError.invalid("Check the named body, style and grade measurement fields.")
        }
        original.merge(child){_,new in new};result[key]=original
      } else {result[key]=raw}
    }
    result["bindings"]=[];result["seams"]=[]
    if let sizes=result["sizes"] as? [[String:Any]] {
      var resolved:[[String:Any]]=[]
      for var row in sizes {
        guard Set(row.keys).isSubset(of:["id","label","step","overrides"]) else {throw FormError.invalid("Unknown size-row fields.")}
        if let raw=row["overrides"],!(raw is NSNull) {
          guard let values=raw as? [String:Any],Set(values.keys).isSubset(of:["waist","hip","waistToHip","bodyLength"]) else {
            throw FormError.invalid("Size overrides use waist, hip, waistToHip and bodyLength only.")
          }
        }
        if row["id"] == nil {
          guard creating else {throw FormError.invalid("Existing size rows need their stable UUIDs; use get.definition when editing a chart.")}
          row["id"]=UUID().uuidString
        }
        resolved.append(row)
      }
      result["sizes"]=resolved
      if fields["sizes"] != nil,fields["baseSizeID"] == nil,let base=resolved.first(where:{($0["step"] as? Int)==0}) {
        result["baseSizeID"]=base["id"]
      }
    }
    var block=try JSONDecoder.form.decode(GarmentBlock.self,from:JSONSerialization.data(withJSONObject:result))
    block.bindings=base?.bindings ?? [];block.seams=base?.seams ?? []
    let active=Set(block.sizes.map(\.id))
    block.bindings.removeAll{!active.contains($0.sizeID)};block.seams.removeAll{!active.contains($0.sizeID)}
    try block.validate()
    return block
  }
  public static func read(_ project:Project,arguments:[String:Any])throws->Any {
    let operation=try operation(arguments,fallback:"list")
    if operation == "list" {return ["blocks":try (project.garmentBlocks ?? []).map{try jsonObject($0)}]}
    guard readOperations.contains(operation),let raw=arguments["block_id"] as? String,
      let id=UUID(uuidString:raw),let block=project.garmentBlocks?.first(where:{$0.id==id}) else {
      throw FormError.missing("Choose an existing garment block_id.")
    }
    return ["block":try jsonObject(block),"definition":try definition(block),
      "resolved_sizes":try block.sizes.map{try jsonObject(block.resolved($0))},
      "conflicts":try GarmentBlockSources.conflicts(block,in:project),
      "update_needed_sizes":try GarmentBlockSources.updateNeededSizes(block,in:project).map(\.uuidString),
      "pending_sizes":block.sizes.filter{row in !block.bindings.contains{$0.sizeID==row.id}}.map{$0.id.uuidString},
      "verified_fit":false]
  }
  public static func apply(in project:inout Project,objectID:UUID,arguments:[String:Any])throws->Any {
    let operation=try operation(arguments,fallback:"create")
    guard !readOperations.contains(operation) else {return try read(project,arguments:arguments)}
    var candidate=project
    guard let supplied=candidate.objects.first(where:{$0.id==objectID}) else {throw FormError.missing("Choose an existing Canvas source.")}
    let owner=candidate.artworkOwner(supplied)
    guard owner.recipeID == "artboard",owner.artwork != nil,!owner.locked,candidate.objects.filter({$0.designID == owner.designID}).count == 1 else {throw FormError.invalid("Choose an unlocked independent Canvas or artwork frame.")}
    let old:GarmentBlock?
    if operation == "create" {old=nil}
    else {
      guard let raw=arguments["block_id"] as? String,let id=UUID(uuidString:raw),
        let value=candidate.garmentBlocks?.first(where:{$0.id==id}) else {throw FormError.missing("Choose an existing garment block_id.")}
      old=value
    }
    if operation == "detach" {
      candidate.garmentBlocks?.removeAll{$0.id == old!.id}
      if candidate.garmentBlocks?.isEmpty == true {candidate.garmentBlocks=nil}
      project=candidate;return ["detached":true,"source_artwork_preserved":true]
    }
    if operation == "detach_size" {
      guard let raw=arguments["size_id"] as? String,let id=UUID(uuidString:raw),old!.sizes.contains(where:{$0.id==id}) else {throw FormError.missing("Choose an existing size_id.")}
      var block=old!;block.sizes.removeAll{$0.id==id};block.bindings.removeAll{$0.sizeID==id};block.seams.removeAll{$0.sizeID==id}
      if block.sizes.isEmpty {candidate.garmentBlocks?.removeAll{$0.id==block.id}}
      else {
        if block.baseSizeID == id {throw FormError.invalid("Choose a different base in the chart before detaching its current base size.")}
        candidate.garmentBlocks![candidate.garmentBlocks!.firstIndex{$0.id==block.id}!]=block
      }
      if candidate.garmentBlocks?.isEmpty == true {candidate.garmentBlocks=nil}
      try candidate.validateArtworkLinks();project=candidate
      return ["detached":true,"source_artwork_preserved":true]
    }
    guard ["create","update","configure","create_revision"].contains(operation) else {throw FormError.invalid("Use create, update, configure, create_revision, detach, detach_size, list, get or report.")}
    var block=try decode(arguments["block"],base:old,creating:operation == "create")
    if let old,block.id != old.id {throw FormError.invalid("A managed block keeps its UUID. Use Create revision for an independent version.")}
    if operation == "create_revision" {
      block.id=UUID();var mapping:[UUID:UUID]=[:]
      for i in block.sizes.indices {let old=block.sizes[i].id;block.sizes[i].id=UUID();mapping[old]=block.sizes[i].id}
      block.baseSizeID=mapping[block.baseSizeID]!;block.bindings=[];block.seams=[]
    }
    if operation == "create",candidate.garmentBlocks?.contains(where:{$0.id==block.id}) == true {throw FormError.invalid("That block UUID already exists.")}
    if operation != "configure" {
      let conflicts=try GarmentBlockSources.conflicts(block,in:candidate)
      guard conflicts.isEmpty else {throw FormError.invalid(conflicts.joined(separator:"\n"))}
      try generate(&block,in:&candidate,defaultOwner:owner.id)
    }
    if let index=candidate.garmentBlocks?.firstIndex(where:{$0.id==block.id}) {candidate.garmentBlocks![index]=block}
    else {if candidate.garmentBlocks==nil {candidate.garmentBlocks=[]};candidate.garmentBlocks!.append(block)}
    try candidate.validateArtworkLinks();project=candidate
    return try read(project,arguments:["operation":"get","block_id":block.id.uuidString])
  }
  public static func preview(_ proposed:GarmentBlock)throws->Artwork {try previewStudy(proposed).artwork}
  public static func previewStudy(_ proposed:GarmentBlock)throws->(artwork:Artwork,block:GarmentBlock) {
    var block=proposed;block.bindings=[];block.seams=[];try block.validate()
    var project=Project(name:"Uncommitted garment proposal")
    let owner=try project.ensureCanvasWorkspace()
    try generate(&block,in:&project,defaultOwner:owner.id)
    return (project.canvasWorkspace!.artwork!,block)
  }
  private static func generate(_ block:inout GarmentBlock,in project:inout Project,defaultOwner:UUID)throws {
    for row in block.sizes {
      let size=try block.resolved(row),refs=block.bindings.filter{$0.sizeID==row.id}
      guard refs.isEmpty || refs.count == 3 else {throw FormError.invalid("The managed size has incomplete source bindings; detach it or create a revision.")}
      let ownerID=refs.first?.objectID ?? defaultOwner
      guard let ownerIndex=project.objects.firstIndex(where:{$0.id==ownerID}),var art=project.objects[ownerIndex].artwork,!project.objects[ownerIndex].locked else {throw FormError.invalid("A managed source owner is missing or locked.")}
      var pieces:[GarmentPieceRole:ArtworkElement]=[:]
      if refs.isEmpty {
        let bottom=art.elements.filter{$0.parentID==nil}.map{art.bounds(of:$0).maxY}.max() ?? -80
        let y=max(40,bottom+120),x=40.0
        for role in GarmentPieceRole.allCases {
          var e=GarmentBlockSources.piece(block:block,size:size,role:role)
          e.x=role == .back ? x+size.panelWidth+80:x
          e.y=role == .elastic ? y+size.rawHeight+100:y
          art.elements.append(e);pieces[role]=e
        }
        _ = try ArtworkCommands.apply("group",to:&art,ids:Set(pieces.values.map(\.id)),arguments:["name":block.name+" / "+row.label])
      } else {
        for ref in refs {
          guard let index=art.elements.firstIndex(where:{$0.id==ref.elementID}) else {throw FormError.missing("A managed piece is missing; Update will not recreate it.")}
          let old=art.elements[index],origin=ArtworkTransforms.worldOrigin(old,in:art)
          var next=GarmentBlockSources.piece(block:block,size:size,role:ref.role,preserving:old)
          art.elements[index]=next
          let updated=ArtworkTransforms.worldOrigin(next,in:art)
          next=try ArtworkTransforms.applying(.translation(origin.x-updated.x,origin.y-updated.y),to:next,in:art)
          art.elements[index]=next;pieces[ref.role]=next
        }
      }
      block.bindings.removeAll{$0.sizeID==row.id}
      for role in GarmentPieceRole.allCases {
        let e=art.elements.first{$0.id==pieces[role]!.id}!
        block.bindings.append(.init(sizeID:row.id,objectID:ownerID,elementID:e.id,role:role,
          fingerprint:try GarmentBlockSources.fingerprint(e)))
      }
      for side in ["left","right"] {
        let prior=block.seams.first{$0.sizeID==row.id && $0.name==side}
        let seam=GarmentBlockSources.sideSeam(side,block:block,size:size,front:pieces[.front]!,back:pieces[.back]!,id:prior?.seamID ?? UUID())
        if art.sewingSeams==nil {art.sewingSeams=[]}
        if let index=art.sewingSeams!.firstIndex(where:{$0.id==seam.id}) {art.sewingSeams![index]=seam}
        else {art.sewingSeams!.append(seam)}
        block.seams.removeAll{$0.sizeID==row.id && $0.name==side}
        block.seams.append(.init(sizeID:row.id,objectID:ownerID,seamID:seam.id,name:side,
          fingerprint:try GarmentBlockSources.fingerprint(seam)))
      }
      try validateArtwork(art)
      project.objects[ownerIndex].artwork=art
    }
  }
}

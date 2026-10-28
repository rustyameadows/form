import AppKit
import FormCore
import FormGraphics
import PDFKit
import UniformTypeIdentifiers
import SwiftUI

struct GarmentSizeDraft: Identifiable, Equatable {
  var id:UUID
  var label:String
  var step:String
  var waist:String
  var hip:String
  var depth:String
  var length:String
}

@MainActor final class GarmentBlockDraft:ObservableObject {
  enum Field:String,CaseIterable {
    case waist,hip,depth,length,ease,side,casing,underturn,hem,elasticWidth,elasticAdjustment,elasticOverlap
    case waistGrade,hipGrade,depthGrade,lengthGrade
    var label:String {
      switch self {
      case .waist:return "Body waist"
      case .hip:return "Body fullest hip"
      case .depth:return "Waist to hip"
      case .length:return "Nominal finished length"
      case .ease:return "Additional body circumference"
      case .side:return "Side allowance"
      case .casing:return "Casing clear depth"
      case .underturn:return "Casing turn-under"
      case .hem:return "Total double-turn hem"
      case .elasticWidth:return "Elastic width"
      case .elasticAdjustment:return "Declared loop adjustment"
      case .elasticOverlap:return "Elastic lap overlap"
      case .waistGrade:return "Waist increment"
      case .hipGrade:return "Hip increment"
      case .depthGrade:return "Hip-depth increment"
      case .lengthGrade:return "Length increment"
      }
    }
  }
  @Published var name:String
  @Published var values:[String:String]=[:]
  @Published var rows:[GarmentSizeDraft]=[]
  @Published private(set) var baseSizeID:UUID
  @Published var error=""
  @Published var materialID=""
  @Published var elasticMaterialID=""
  private var original:GarmentBlock
  init(_ block:GarmentBlock=GarmentBlock()) {
    original=block;name=block.name;baseSizeID=block.baseSizeID
    load(block)
  }
  private func text(_ value:Double)->String {value == value.rounded() ? String(Int(value)):String(value)}
  func load(_ block:GarmentBlock) {
    original=block;name=block.name;baseSizeID=block.baseSizeID
    materialID=block.style.materialID ?? "";elasticMaterialID=block.style.elasticMaterialID ?? ""
    let numbers:[Double]=[block.body.waist,block.body.hip,block.body.waistToHip,block.style.bodyLength,block.style.bodyEase,
      block.style.sideAllowance,block.style.casingDepth,block.style.casingTurnUnder,block.style.hemAllowance,
      block.style.elasticWidth,block.style.elasticLoopAdjustment,block.style.elasticOverlap,
      block.grade.waist,block.grade.hip,block.grade.waistToHip,block.grade.bodyLength]
    values=Dictionary(uniqueKeysWithValues:zip(Field.allCases,numbers).map{($0.rawValue,text($1))})
    rows=block.sizes.map{row in .init(id:row.id,label:row.label,step:String(row.step),
      waist:row.overrides?.waist.map(text) ?? "",hip:row.overrides?.hip.map(text) ?? "",
      depth:row.overrides?.waistToHip.map(text) ?? "",length:row.overrides?.bodyLength.map(text) ?? "")}
    error=""
  }
  private func number(_ text:String,label:String)throws->Double {
    guard let value=Double(text.trimmingCharacters(in:.whitespacesAndNewlines)),value.isFinite else {throw FormError.invalid("\(label) needs a finite millimeter measurement.")}
    return value
  }
  func block()throws->GarmentBlock {
    var result=original;result.name=name.trimmingCharacters(in:.whitespacesAndNewlines);result.baseSizeID=baseSizeID
    let numbers=try Field.allCases.map{try number(values[$0.rawValue] ?? "",label:$0.label)}
    result.body.waist=numbers[0];result.body.hip=numbers[1];result.body.waistToHip=numbers[2]
    result.style.bodyLength=numbers[3];result.style.bodyEase=numbers[4];result.style.sideAllowance=numbers[5]
    result.style.casingDepth=numbers[6];result.style.casingTurnUnder=numbers[7];result.style.hemAllowance=numbers[8]
    result.style.materialID=materialID.isEmpty ? nil:materialID;result.style.elasticMaterialID=elasticMaterialID.isEmpty ? nil:elasticMaterialID
    result.style.elasticWidth=numbers[9];result.style.elasticLoopAdjustment=numbers[10];result.style.elasticOverlap=numbers[11]
    result.grade.waist=numbers[12];result.grade.hip=numbers[13];result.grade.waistToHip=numbers[14];result.grade.bodyLength=numbers[15]
    result.sizes=try rows.map{row in
      guard let step=Int(row.step.trimmingCharacters(in:.whitespacesAndNewlines)),(-12...12).contains(step) else {throw FormError.invalid("Each size step is an integer from −12 to 12.")}
      var value=GarmentSizeRow(row.label,step:step);value.id=row.id
      var o=GarmentSizeOverrides()
      if !row.waist.isEmpty {o.waist=try number(row.waist,label:"Waist override")}
      if !row.hip.isEmpty {o.hip=try number(row.hip,label:"Hip override")}
      if !row.depth.isEmpty {o.waistToHip=try number(row.depth,label:"Hip-depth override")}
      if !row.length.isEmpty {o.bodyLength=try number(row.length,label:"Length override")}
      value.overrides=o.isEmpty ? nil:o;return value
    }
    let active=Set(result.sizes.map(\.id))
    result.bindings.removeAll{!active.contains($0.sizeID)};result.seams.removeAll{!active.contains($0.sizeID)}
    try result.validate();return result
  }
  var signature:String {
    let fields=[name,materialID,elasticMaterialID,baseSizeID.uuidString]+Field.allCases.map{values[$0.rawValue] ?? ""}
    let sizes=rows.map{[$0.id.uuidString,$0.label,$0.step,$0.waist,$0.hip,$0.depth,$0.length].joined(separator:"|")}
    return fields.joined(separator:"|")+"|"+sizes.joined(separator:";")
  }

  func addSize() {
    guard rows.count<12 else{return}
    let step=(rows.compactMap{Int($0.step)}.max() ?? 0)+1
    guard step<=12 else{error="The next grade step would exceed 12. Revise the declared rows first.";return}
    rows.append(.init(id:UUID(),label:"Study \(rows.count+1)",step:String(step),waist:"",hip:"",depth:"",length:""))
  }
  func removeSize(_ id:UUID) {if id != baseSizeID && rows.count>1 {rows.removeAll{$0.id==id}}}
  func rebase(_ id:UUID) {
    do {
      var block=try block();guard let base=block.sizes.first(where:{$0.id==id}) else{return}
      let all=try Dictionary(uniqueKeysWithValues:block.sizes.map{($0.id,try block.resolved($0))}),resolved=all[id]!,shift=base.step
      guard block.sizes.allSatisfy({(-12...12).contains($0.step-shift)}) else {throw FormError.invalid("Rebasing would exceed the supported grade-step range; revise the declared steps first.")}
      block.body.waist=resolved.waist;block.body.hip=resolved.hip;block.body.waistToHip=resolved.waistToHip;block.style.bodyLength=resolved.bodyLength;block.baseSizeID=id
      for i in block.sizes.indices {
        block.sizes[i].step-=shift;let row=block.sizes[i],wanted=all[row.id]!,n=Double(row.step)
        var o=GarmentSizeOverrides()
        if wanted.waist != resolved.waist+n*block.grade.waist {o.waist=wanted.waist}
        if wanted.hip != resolved.hip+n*block.grade.hip {o.hip=wanted.hip}
        if wanted.waistToHip != resolved.waistToHip+n*block.grade.waistToHip {o.waistToHip=wanted.waistToHip}
        if wanted.bodyLength != resolved.bodyLength+n*block.grade.bodyLength {o.bodyLength=wanted.bodyLength}
        block.sizes[i].overrides=o.isEmpty ? nil:o
      }
      try block.validate();load(block)
    }catch {self.error=error.localizedDescription}
  }
}

@MainActor final class GarmentBlockController:ObservableObject {
  weak var session:ArtworkSession?
  let projectID:UUID?
  let objectID:UUID?
  @Published var draft:GarmentBlockDraft
  @Published private(set) var blockID:UUID?
  @Published private(set) var proof:Data?
  @Published private(set) var resolved:[GarmentResolvedSize]=[]
  @Published private(set) var conflicts:[String]=[]
  @Published private(set) var updateNeeded=Set<UUID>()
  @Published private(set) var error=""
  @Published private(set) var externalChange=false
  private var savedDefinition:Data?
  private var loadedSignature=""
  private var previewKey=""
  init(session:ArtworkSession) {
    self.session=session;projectID=session.store?.project?.id
    let ownerID=session.object.flatMap{session.store?.project?.artworkOwner($0).id}
    objectID=ownerID
    let block=session.store?.project?.garmentBlocks?.first{value in value.bindings.contains{$0.objectID==ownerID}}
    draft=GarmentBlockDraft(block ?? GarmentBlock());blockID=block?.id
    savedDefinition=block.flatMap{try? JSONSerialization.data(withJSONObject:GarmentBlockCommands.definition($0),options:[.sortedKeys])}
    loadedSignature=draft.signature
  }
  var contextValid:Bool {
    guard let session,let store=session.store,store.project?.id==projectID,let objectID else{return false}
    return store.project?.objects.contains{$0.id==objectID && $0.recipeID=="artboard"} == true
  }
  var blocks:[GarmentBlock] {session?.store?.project?.garmentBlocks ?? []}
  var identity:String {PhysicalDocumentController.key(project:projectID,object:objectID,kind:"garment-block-\(blockID?.uuidString ?? "proposal")")}
  func select(_ id:UUID?) {
    guard contextValid else{return}
    let block=blocks.first{$0.id==id}
    blockID=block?.id;draft=GarmentBlockDraft(block ?? GarmentBlock())
    savedDefinition=block.flatMap{try? JSONSerialization.data(withJSONObject:GarmentBlockCommands.definition($0),options:[.sortedKeys])}
    loadedSignature=draft.signature;externalChange=false;previewKey="";refreshPreview()
  }
  func refreshContext() {
    guard contextValid else{error="The source project or document is no longer open.";proof=nil;return}
    if let blockID {
      guard let current=blocks.first(where:{$0.id==blockID}) else{error="This block's metadata was detached; source artwork remains. Start a new draft or choose another block.";proof=nil;return}
      let key=try? JSONSerialization.data(withJSONObject:GarmentBlockCommands.definition(current),options:[.sortedKeys])
      if key == savedDefinition,externalChange {externalChange=false;error=""}
      if key != savedDefinition {
        if draft.signature == loadedSignature {select(blockID);return}
        externalChange=true;error="The saved chart changed while this draft was open. Reload the saved chart before updating, or retain these values as a new revision."
      }
      conflicts=(try? GarmentBlockSources.conflicts(current,in:session!.store!.project!)) ?? ["Could not inspect current source."]
      updateNeeded=(try? GarmentBlockSources.updateNeededSizes(current,in:session!.store!.project!)) ?? []
    }
  }
  func refreshPreview() {
    do {
      guard contextValid else{throw FormError.missing("Choose an open independent Canvas source.")}
      guard draft.signature != previewKey || proof == nil else{return}
      let proposed=try draft.block()
      let study=try GarmentBlockCommands.previewStudy(proposed),document=PDFDocument()
      for row in study.block.sizes {
        let ids=Set(study.block.bindings.filter{$0.sizeID==row.id}.map(\.elementID))
        let output=try SewingPatternOutput(source:study.artwork,selection:ids)
        guard let page=PDFDocument(data:try output.pdf(assets:session!.assets,dpi:150))?.page(at:0) else {
          throw FormError.invalid("The proposed physical size page could not be read.")
        }
        document.insert(page,at:document.pageCount)
      }
      guard let data=document.dataRepresentation(),data.count<=32*1024*1024 else {
        throw FormError.invalid("The proposed size pages exceed the 32 MiB review limit.")
      }
      proof=data
      resolved=try proposed.sizes.map{try proposed.resolved($0)};previewKey=draft.signature
      if !externalChange {error=""}
      refreshContext()
    }catch{self.error=error.localizedDescription;proof=nil;resolved=[]}
  }
  @discardableResult func apply(_ operation:String)->Bool {
    do {
      guard contextValid,let session,let store=session.store,let objectID else{throw FormError.missing("The source project is no longer open.")}
      if externalChange,operation != "create_revision" {throw FormError.invalid("Reload the saved chart before replacing it.")}
      let block=try draft.block()
      var args:[String:Any]=["object_id":objectID.uuidString,"command":"garment_block","operation":operation,
        "block":try GarmentBlockCommands.definition(block)]
      if let blockID {args["block_id"]=blockID.uuidString}
      let result=try store.engine.call("form_edit_artwork",arguments:args,source:"Studio") as! [String:Any]
      store.changed()
      if let raw=(result["block"] as? [String:Any])?["id"] as? String {select(UUID(uuidString:raw))}
      return true
    }catch{self.error=error.localizedDescription;return false}
  }
  @discardableResult func detach()->Bool {
    do {
      guard contextValid,let session,let store=session.store,let objectID,let blockID else{return false}
      _=try store.engine.call("form_edit_artwork",arguments:["object_id":objectID.uuidString,"command":"garment_block","operation":"detach","block_id":blockID.uuidString],source:"Studio")
      store.changed();select(nil);return true
    }catch{self.error=error.localizedDescription;return false}
  }
  func exportSize(_ sizeID:UUID) {
    guard contextValid,let session,let store=session.store,
      let block=blocks.first(where:{$0.id==blockID}),let row=block.sizes.first(where:{$0.id==sizeID}) else{return}
    let refs=block.bindings.filter{$0.sizeID==sizeID}
    guard refs.count==3,let owner=store.project?.objects.first(where:{$0.id==refs[0].objectID}) else{return}
    NSApp.keyWindow?.makeFirstResponder(nil)
    let panel=NSSavePanel();panel.allowedContentTypes=[.pdf]
    panel.nameFieldStringValue=(block.name+"-"+row.label+"-source.pdf").replacingOccurrences(of:"/",with:"-")
    guard panel.runModal() == .OK,let url=panel.url else{return}
    do {
      _=try store.exportSewingPattern(object:owner,arguments:["format":"pdf","path":url.path,"element_ids":refs.map{$0.elementID.uuidString}])
      store.toast("Garment size source exported")
    }catch{self.error=error.localizedDescription}
  }
  func reveal(_ sizeID:UUID) {
    guard let block=blocks.first(where:{$0.id==blockID}),let session,let store=session.store else{return}
    let refs=block.bindings.filter{$0.sizeID==sizeID}
    guard let owner=refs.first?.objectID,refs.allSatisfy({$0.objectID==owner}) else{return}
    session.activate(owner);session.choose(Set(refs.map(\.elementID)));store.activateDesignSurface(.artwork)
    DispatchQueue.main.async{session.canvas?.fit(all:false)}
  }
}

import CoreFoundation
import Foundation

/// Additive projections of the current document. The original no-argument
/// Project response stays intact; bounded projections never masquerade as it.
enum ProjectReadCommands {
  static let scopedByteLimit=4*1024*1024
  static let bridgeByteLimit=8*1024*1024
  static let sectionNames=["objects","recipes","materials","notes","history","camera","renderSettings","printSetups","swatches","textStyles","fontLibrary","textStories","publications","productionJobs","studioPresentation","decorationPreparations","garmentBlocks","collectionProduction"]
  static var properties:[String:Any] {[
    "view":["type":"string","enum":["full","summary","scoped"],"description":"Default full preserves the Project wire shape when it fits the existing 8 MiB bridge. summary returns identity/camera/counts and lightweight object metadata. scoped returns only requested sections. Summary/scoped envelopes are explicitly partial and at most 4 MiB."],
    "sections":["type":"array","items":["type":"string","enum":sectionNames],"minItems":1,"maxItems":8,"uniqueItems":true,"description":"Required for scoped; absent for full/summary. Arrays page independently in requested section order; scalar sections are returned whole or fail explicitly."],
    "object_ids":["type":"array","items":["type":"string"],"minItems":1,"maxItems":256,"uniqueItems":true,"description":"Summary/scoped objects only. Exact UUIDs, returned in project order; unknown IDs reject. Completeness refers to this selected set."],
    "offset":["type":"integer","minimum":0,"maximum":1000000,"description":"Zero-based start applied independently to requested array sections. Scalar sections are not paged."],
    "limit":["type":"integer","minimum":1,"maximum":128,"description":"Maximum records per array, default 64. The shared byte budget may return fewer whole records. Follow each section's next_offset separately; complete is true only when the whole selected section is in this response."],
    "expected_revision":["type":"string","maxLength":128,"description":"form_get_project only. Use the previous summary/scoped revision to reject edits, Undo, reopen or process changes between pages. A revision is opaque and session-local."]
  ]}
  struct Request {
    enum View:String {case full,summary,scoped}
    let view:View,sections:[String],objectIDs:Set<UUID>?,offset:Int,limit:Int,expectedRevision:String?
    init(_ arguments:[String:Any],opening:Bool=false)throws {
      guard Set(arguments.keys).isSubset(of:Set(ProjectReadCommands.properties.keys)) else{throw FormError.invalid("Unknown project-read argument.")}
      if let raw=arguments["view"] {
        guard let text=raw as? String,let value=View(rawValue:text) else{throw FormError.invalid("Use project view full, summary or scoped.")};view=value
      } else{view = .full}
      func integer(_ key:String,_ fallback:Int,_ range:ClosedRange<Int>)throws->Int {
        guard let raw=arguments[key] else{return fallback}
        guard let number=raw as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite,number.doubleValue.rounded()==number.doubleValue,range.contains(number.intValue),number.doubleValue==Double(number.intValue) else{throw FormError.invalid("Invalid project-read \(key).")}
        return number.intValue
      }
      offset=try integer("offset",0,0...1_000_000);limit=try integer("limit",64,1...128)
      if let raw=arguments["expected_revision"] {
        guard !opening,let value=raw as? String,!value.isEmpty,value.utf8.count<=128 else{throw FormError.invalid("expected_revision is a nonempty revision from form_get_project, up to 128 bytes; it is not an open-project option.")}
        expectedRevision=value
      } else{expectedRevision=nil}
      if let raw=arguments["object_ids"] {
        guard let values=raw as? [String],(1...256).contains(values.count),Set(values).count==values.count else{throw FormError.invalid("Provide 1–256 distinct object UUIDs.")}
        let ids=values.compactMap(UUID.init(uuidString:));guard ids.count==values.count,Set(ids).count==ids.count else{throw FormError.invalid("Invalid or duplicate object UUID.")};objectIDs=Set(ids)
      } else{objectIDs=nil}
      switch view {
      case .full:
        guard arguments["sections"]==nil,objectIDs==nil,arguments["offset"]==nil,arguments["limit"]==nil else{throw FormError.invalid("Use view:scoped with sections for filtered/full records, or view:summary for lightweight objects.")}
        sections=[]
      case .summary:
        guard arguments["sections"]==nil else{throw FormError.invalid("Summary includes lightweight objects. Use view:scoped to request other sections.")};sections=["objects"]
      case .scoped:
        guard let values=arguments["sections"] as? [String],(1...8).contains(values.count),Set(values).count==values.count,Set(values).isSubset(of:Set(ProjectReadCommands.sectionNames)) else{throw FormError.invalid("Scoped reads require 1–8 distinct supported sections.")}
        guard objectIDs==nil || values.contains("objects") else{throw FormError.invalid("object_ids requires the objects section.")};sections=values
      }
    }
  }
  private struct Section {
    var count:Int?
    var item:(Int)throws->Any
  }
  private static func array<T:Encodable>(_ values:[T])->Section {.init(count:values.count,item:{try jsonObject(values[$0])})}
  private static func optionalArray<T:Encodable>(_ values:[T]?)->Section {values.map(array) ?? scalar(Optional<Int>.none)}
  private static func scalar<T:Encodable>(_ value:T?)->Section {.init(count:nil,item:{_ in try value.map(jsonObject) ?? NSNull()})}
  private static func sections(_ project:Project,objects:[ProductObject])->[String:Section] {[
    "objects":array(objects),"recipes":array(project.recipes),"materials":array(project.materials),"notes":array(project.notes),"history":array(project.history),
    "camera":scalar(project.camera),"renderSettings":scalar(project.renderSettings),"printSetups":scalar(project.printSetups),
    "swatches":optionalArray(project.swatches),"textStyles":optionalArray(project.textStyles),"fontLibrary":scalar(project.fontLibrary),
    "textStories":optionalArray(project.textStories),"publications":optionalArray(project.publications),"productionJobs":optionalArray(project.productionJobs),
    "studioPresentation":scalar(project.studioPresentation),"decorationPreparations":optionalArray(project.decorationPreparations),
    "garmentBlocks":optionalArray(project.garmentBlocks),"collectionProduction":scalar(project.collectionProduction)
  ]}
  private static func summary(_ object:ProductObject)throws->[String:Any] {
    var value:[String:Any]=["id":object.id.uuidString,"name":object.name,"recipeID":object.recipeID,"parameters":object.parameters,
      "materialID":object.materialID,"position":try jsonObject(object.position),"rotation":object.rotation,"locked":object.locked,
      "designID":object.designID.uuidString,"relationship":object.relationship,"details_complete":false]
    value["color"]=object.color;value["groupID"]=object.groupID?.uuidString;value["parentIterationID"]=object.parentIterationID?.uuidString
    value["canvasWorkspace"]=object.canvasWorkspace;value["canvasSourceOnly"]=object.canvasSourceOnly;value["componentDefinition"]=object.componentDefinition
    value["artworkSourceID"]=object.artworkSourceID?.uuidString;value["artworkFit"]=object.artworkFit;value["asset"]=object.asset
    value["available_detail_fields"]=[("artwork",object.artwork != nil),("cloth",object.cloth != nil),("textile",object.textile != nil),
      ("clothAttachment",object.clothAttachment != nil),("patternAssembly",object.patternAssembly != nil),("patternAssemblyAttachment",object.patternAssemblyAttachment != nil),
      ("meshAsset",object.meshAsset != nil),("cadModel",object.cadModel != nil),("cadRepresentation",object.cadRepresentation != nil),("paperConstruction",object.paperConstruction != nil),
      ("sheetAssembly",object.sheetAssembly != nil),("librarySelection",object.librarySelection != nil),("surfaceArtworkBindings",object.surfaceArtworkBindings != nil),
      ("physicalArtworkIntents",object.physicalArtworkIntents != nil),("artworkParameterBindings",object.artworkParameterBindings != nil),
      ("paperTemplateReference",object.paperTemplateReference != nil),("canvasProjectionPositions",object.canvasProjectionPositions != nil)].filter{$0.1}.map{$0.0}
    return value
  }
  private static func size(_ value:Any)throws->Int {try JSONSerialization.data(withJSONObject:value,options:.fragmentsAllowed).count}
  static func response(project:Project,revision:String,request:Request)throws->Any {
    if let expected=request.expectedRevision,expected != revision {throw FormError.invalid("Project read revision changed. Restart from view:summary before reading more pages.")}
    if let ids=request.objectIDs,!ids.isSubset(of:Set(project.objects.map(\.id))) {throw FormError.missing("One or more requested object IDs are absent from this project.")}
    if request.view == .full {
      let full=try jsonObject(project)
      guard try size(["result":full])+1<=bridgeByteLimit else{throw FormError.invalid("The full project exceeds the existing 8 MiB bridge response limit. Use form_get_project or form_open_project with view:summary; use view:scoped, sections and object_ids for full individual records.")}
      return full
    }
    let selected=project.objects.filter{request.objectIDs?.contains($0.id) ?? true}
    var available=sections(project,objects:selected)
    if request.view == .summary {available["objects"] = .init(count:selected.count,item:{try summary(selected[$0])})}
    var metadata:[String:Any]=["id":project.id.uuidString,"name":project.name,"subtitle":project.subtitle,"schemaVersion":project.schemaVersion,
      "createdAt":ISO8601DateFormatter().string(from:project.createdAt),"updatedAt":ISO8601DateFormatter().string(from:project.updatedAt),"unit":project.unit,"camera":try jsonObject(project.camera)]
    metadata["conversationReference"]=project.conversationReference
    var values:[String:Any]=[:],pages:[String:Any]=[:]
    func page(_ total:Int,_ returned:Int)->[String:Any] {
      let next=request.offset+returned,more=next<total
      return ["offset":request.offset,"limit":request.limit,"returned":returned,"total":total,"has_more":more,
        "next_offset":more ? next as Any:NSNull(),"complete":request.offset==0 && returned==total]
    }
    for name in request.sections {
      let section=available[name]!
      if let count=section.count {
        guard request.offset<=count else{throw FormError.invalid("Offset exceeds the \(name) section count \(count).")}
        values[name]=[Any]();pages[name]=page(count,0)
      } else {values[name]=try section.item(0);pages[name]=["complete":true,"kind":"scalar"]}
    }
    guard request.offset==0 || request.sections.contains(where:{available[$0]?.count != nil}) else{throw FormError.invalid("Scalar sections do not accept a nonzero offset.")}
    var result:[String:Any]=["view":request.view.rawValue,"revision":revision,"project":metadata,"sections":values,"pages":pages,
      "response_complete":false,"omitted_sections":sectionNames.filter{!request.sections.contains($0)},
      "object_count":project.objects.count,"selected_object_count":selected.count,"section_counts":available.compactMapValues(\.count),"response_byte_limit":scopedByteLimit]
    // Reserve space for page metadata changes. Admit whole records only; callers
    // follow each section's returned cursor instead of inferring completeness.
    let initial=try size(result),budget=scopedByteLimit-65_536
    guard initial<=budget else{throw FormError.invalid("Requested scalar sections exceed the 4 MiB project-read budget. Request fewer sections or their existing domain-specific get operation.")}
    var used=initial
    for name in request.sections {
      guard let section=available[name],let total=section.count else{continue}
      var rows=[Any]()
      for index in request.offset..<min(total,request.offset+request.limit) {
        let item=try section.item(index),bytes=try size(item)+1
        guard bytes<=budget-initial else{throw FormError.invalid("A record in section \(name) with the requested scalar sections exceeds the 4 MiB project-read budget. Request that section separately, or use summary metadata and its existing domain-specific read operation.")}
        if used+bytes>budget {break}
        rows.append(item);used+=bytes
      }
      values[name]=rows;pages[name]=page(total,rows.count)
    }
    result["sections"]=values;result["pages"]=pages
    guard try size(result)<=scopedByteLimit else{throw FormError.invalid("Requested project projection exceeds the 4 MiB response budget.")}
    return result
  }
}

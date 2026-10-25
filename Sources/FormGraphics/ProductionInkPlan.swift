import AppKit
import FormCore

public struct InkPrintPage {
  public var id:UUID?,name:String,artwork:Artwork,width:Double,height:Double
  public init(id:UUID?=nil,name:String,artwork:Artwork,width:Double,height:Double) {self.id=id;self.name=name;self.artwork=artwork;self.width=width;self.height=height}
}
public enum InkOutputMode:String {case preview,composite,plates,preflight}

struct InkClip {var path:CGPath,evenOdd:Bool}
enum InkPaint {case process([Double]);case spot(ProductionInk)}
struct InkPrimitive {var path:CGPath,evenOdd:Bool,paint:InkPaint,clips:[InkClip]}
struct InkPlannedPage {var source:InkPrintPage,primitives:[InkPrimitive]}

@MainActor final class ProductionInkPlan {
  var pages:[InkPlannedPage]=[]
  var spots:[String:ProductionInk]=[:]
  var profile:ICCOutputProfile?
  var issues:[[String:Any]]=[]
  var primitiveCount=0
  let project:Project,assets:URL
  init(project:Project,pages:[InkPrintPage],assets:URL) {
    self.project=project;self.assets=assets
    guard !pages.isEmpty,pages.count<=200 else{issues=[["severity":"error","message":"Choose 1–200 physical pages for production inks."]];return}
    do {try project.validateArtworkLinks()}catch{issue(error.localizedDescription);return}
    for page in pages {
      guard [page.width,page.height].allSatisfy({$0.isFinite && $0>0 && $0<=100000}) else{issue("A physical ink page has invalid dimensions.",page:page);continue}
      guard let reference=page.artwork.outputColorProfile,reference.model=="CMYK" else{issue("Assign the intended portable CMYK output profile before exporting production inks.",page:page);continue}
      if let profile,profile.reference.sha256 != reference.sha256 {issue("All production pages require the same output profile identity; choose one explicitly.",page:page);continue}
      do {if profile==nil {profile=try ICCOutputProfile(reference:reference,assets:assets)}
        else {_ = try ICCOutputProfile(reference:reference,assets:assets)}
      }catch{issue(error.localizedDescription,page:page);continue}
      do {try prepare(page)}catch{issue(error.localizedDescription,page:page)}
    }
  }
  func issue(_ text:String,page:InkPrintPage?=nil,element:ArtworkElement?=nil,severity:String="error") {
    var value:[String:Any]=["severity":severity,"message":text]
    if let page {value["page"]=page.name;if let id=page.id {value["object_id"]=id.uuidString}}
    if let element {value["element_id"]=element.id.uuidString;value["element"]=element.title}
    issues.append(value)
  }
  private func paint(_ color:String,swatchID:UUID?,page:InkPrintPage) throws -> InkPaint {
    guard let profile else{throw FormError.invalid("Production output has no verified CMYK profile.")}
    if let ink=project.productionInk(swatchID) {
      guard ink.profile.sha256==profile.reference.sha256 else{throw FormError.invalid("An assigned ink uses a different profile identity on \(page.name). Choose matching ink/output profiles explicitly.")}
      if ink.kind == .spot {spots[ink.spotName!]=ink;return .spot(ink)}
      return .process(ink.components.values)
    }
    return .process(try profile.processComponents(color))
  }
  private func prepare(_ page:InkPrintPage) throws {
    let geometry=try PhysicalVectorPlan(artwork:page.artwork,width:page.width,height:page.height,assets:assets)
    for value in geometry.issues {
      var item:[String:Any]=["severity":"error","message":value.message,"page":page.name]
      if let id=page.id {item["object_id"]=id.uuidString}
      if let id=value.elementID {item["element_id"]=id.uuidString};if let title=value.title {item["element"]=title}
      issues.append(item)
    }
    var primitives:[InkPrimitive]=[]
    for value in geometry.paints {
      primitiveCount+=1;guard primitiveCount<=100000 else{throw FormError.invalid("Production ink output supports at most 100,000 vector paints per export.")}
      primitives.append(.init(path:value.path,evenOdd:value.evenOdd,paint:try paint(value.color,swatchID:value.swatchID,page:page),clips:value.clips.map{.init(path:$0.path,evenOdd:$0.evenOdd)}))
    }
    pages.append(.init(source:page,primitives:primitives))
  }
  var colorants:[String] {["Cyan","Magenta","Yellow","Black"]+spots.keys.sorted()}
  var canExport:Bool {!pages.isEmpty && !issues.contains{$0["severity"] as? String=="error"}}
  var report:[String:Any] {
    var value:[String:Any]=["can_export":canExport,"can_export_composite":canExport,"can_export_plates":canExport && pages.count*colorants.count<=1000,
      "issues":issues,"physical_pages":pages.count,"plate_pages":pages.count*colorants.count,"colorants":colorants,"vector_paints":primitiveCount,
      "source_color_space":"sRGB preview plus declared profile-pinned inks","text_output":"shared shaped outlines","overprint":false,"plates":"positive unscreened digital ink maps; no physical coverage, screening, trapping or PDF/X certification"]
    if let profile {value["output_profile"]=(try? jsonObject(profile.reference)) ?? NSNull()}
    return value
  }
}

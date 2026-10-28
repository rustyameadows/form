import AppKit
import FormCore
import FormGraphics
import SwiftUI

/// Local strings are independent drafts; no source writes until Apply.
@MainActor final class ArtworkPageSetupDraft:ObservableObject {
  weak var store:StudioStore?
  let projectID:UUID?,objectID:UUID
  @Published var bleed=""
  @Published var safe=""
  @Published var error=""
  var focused=Set<String>()
  private var committedBleed="",committedSafe=""
  @Published private(set) var unit:PhysicalUnit = .mm
  init(store:StudioStore,objectID:UUID){self.store=store;projectID=store.project?.id;self.objectID=objectID;synchronize()}
  func synchronize() {
    guard let store,let project=store.project,project.id==projectID,let object=try? ArtworkPageSetup.source(project,objectID:objectID),let art=object.artwork else{error="The independent rectangular source frame is unavailable or locked.";return}
    if bleed==committedBleed,safe==committedSafe {unit=art.unit ?? .mm}
    func string(_ value:Double)->String {(value/unit.millimeters).formatted(.number.precision(.fractionLength(0...12)).grouping(.never))}
    if bleed==committedBleed {bleed=string(art.bleed);committedBleed=bleed}
    if safe==committedSafe {safe=art.safeInset.map(string) ?? "";committedSafe=safe}
  }
  private func parse(_ value:String)throws->Double {
    guard value.utf8.count<=128 else{throw FormError.invalid("Keep each physical input within 128 bytes.")}
    let result=try unit.parse(value);guard result.isFinite else{throw FormError.invalid("Use finite physical units.")};return result
  }
  @discardableResult func apply()->Bool {
    do {
      guard let store,let project=store.project,project.id==projectID else{throw FormError.missing("Reopen this page's project before applying its setup.")}
      let before=try ArtworkPageSetup.source(project,objectID:objectID),art=before.artwork!
      let b=bleed==committedBleed ? art.bleed:try parse(bleed)
      let inset:Double?=safe==committedSafe ? art.safeInset:safe.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil:try parse(safe)
      let args:[String:Any]=["object_id":objectID.uuidString,"command":"page_setup","bleed":b,"safe_inset":inset as Any? ?? NSNull()]
      var mirror=project;try ArtworkPageSetup.apply(in:&mirror,objectID:objectID,arguments:args)
      guard store.artworkSession.canvas?.hasMarkedTextInput != true else{throw FormError.invalid("Finish marked text input before applying page setup.")}
      store.finishArtworkEditing()
      guard let current=store.project,current.id==projectID else{throw FormError.invalid("The page's project changed during input handoff. Review its setup again.")}
      let rebound=try ArtworkPageSetup.source(current,objectID:objectID)
      guard rebound.artworkSize==before.artworkSize else{throw FormError.invalid("Frame dimensions changed during input handoff. Review the page setup against its new dimensions.")}
      _ = try store.engine.call("form_edit_artwork",arguments:args,source:"Studio")
      store.metadataRecordsChanged();committedBleed=bleed;committedSafe=safe;error="";return true
    }catch{self.error=error.localizedDescription;return false}
  }
}

@MainActor final class ArtworkPageReviewModel:ObservableObject {
  weak var store:StudioStore?
  let projectID:UUID?,objectID:UUID
  @Published var area=ArtworkPageArea.bleed
  @Published var cropMarks=false
  @Published var gap="1"
  @Published var length="3"
  @Published var previewInks=false
  @Published var referenceGuides=true
  @Published var proof:Data?
  @Published private(set) var warnings:[String]=[]
  @Published var geometry:ArtworkPageGeometry?
  @Published var error=""
  private var sourceKey:Data?
  private var reviewedOptions:Data?
  init(store:StudioStore,objectID:UUID){self.store=store;projectID=store.project?.id;self.objectID=objectID}
  var identity:String {PhysicalDocumentController.key(project:projectID,object:objectID,kind:"physical-page-setup")}
  func arguments()throws->[String:Any] {
    guard gap.utf8.count<=128,length.utf8.count<=128,let g=Double(gap),let l=Double(length),g.isFinite,l.isFinite else{throw FormError.invalid("Enter bounded finite millimeter numbers for crop-mark gap and length.")}
    var args:[String:Any]=["object_id":objectID.uuidString,"format":"pdf","page_output":["area":area.rawValue,"crop_marks":cropMarks,"mark_gap_mm":g,"mark_length_mm":l]]
    if previewInks {args["ink_output"]="preview"};return args
  }
  private func optionSignature()throws->Data {
    var value=try arguments();value["reference_guides"]=referenceGuides
    return try JSONSerialization.data(withJSONObject:value,options:.sortedKeys)
  }
  var matchesReview:Bool {
    guard proof != nil,store?.project?.id==projectID,let current=try? optionSignature() else{return false}
    return reviewedOptions==current
  }
  func refresh() {
    do {
      guard let store,store.project?.id==projectID else{throw FormError.missing("This page's project is no longer active.")}
      let args=try arguments(),(object,art,g,assets,_,dpi)=try store.pageOutputSource(objectID:objectID,arguments:args)
      // renderCacheData includes derived linked-story/component source that
      // ordinary source Codable intentionally omits.
      var key=try art.renderCacheData()
      key.append(try JSONSerialization.data(withJSONObject:g.metadata,options:.sortedKeys))
      key.append(try JSONEncoder.form.encode(art.outputColorProfile))
      key.append(Data("reference:\(referenceGuides)/font:\(GeometryFactory.fontRevision)".utf8))
      guard key.count<=16_000_000 else{throw FormError.invalid("This live page review exceeds its 16 MB source-signature work limit.")}
      if sourceKey != key || proof==nil {proof=try ArtworkPagePDF.pdf(art,geometry:g,assets:assets,dpi:dpi,referenceGuides:referenceGuides,title:object.name);sourceKey=key}
      geometry=g;reviewedOptions=try optionSignature()
      let notices=store.artworkPageWarnings(art),keys=["font_warnings","optical_sizing_warnings","character_position_warnings","small_caps_warnings"]
      var seen=Set<String>();warnings=keys.flatMap{notices[$0] ?? []}.filter{seen.insert($0).inserted};error=""
    }catch{proof=nil;geometry=nil;reviewedOptions=nil;warnings=[];self.error=error.localizedDescription}
  }
  @discardableResult func export(path:URL)->Bool {
    do {
      guard let store,store.project?.id==projectID else{throw FormError.missing("This page's project is no longer active.")}
      guard matchesReview else{throw FormError.invalid("Refresh the page review after changing output options.")}
      var args=try arguments();args["path"]=path.path
      _ = try store.exportArtworkPage(objectID:objectID,arguments:args);error="";return true
    }catch{self.error=error.localizedDescription;return false}
  }
}

import AppKit
import FormCore
import SwiftUI

/// The rendered document owns the commit, even when another project has reused
/// its publication UUID. A single-axis field reads the other current axis only
/// after checking that ownership, so a stale field cannot undo a newer trim edit.
struct PublicationTrimTarget:Hashable {
  let projectID:UUID,publicationID:UUID
  @MainActor @discardableResult
  func resize(using session:ArtworkSession,width:Double?=nil,height:Double?=nil)throws->Bool {
    guard let store=session.store,let current=store.project,current.id==projectID,
      let document=current.publications?.first(where:{$0.id==publicationID}),
      let first=document.pages.first.flatMap({page in current.objects.first{$0.id==page.objectID}}),
      width != nil || height != nil else{return false}
    let width=width ?? first.artworkSize.x,height=height ?? first.artworkSize.y
    let arguments:[String:Any]=["command":"resize_pages","publication_id":publicationID.uuidString,"width":width,"height":height]
    guard session.canvas?.activeTextView?.hasMarkedText() != true,
      session.canvas?.storyEditor?.views.contains(where:{$0.hasMarkedText()}) != true else {
      throw FormError.invalid("Finish the current text input before resizing publication pages.")
    }
    // Reject invalid bounds/crops before ending a native editing session. The
    // public command validates again against the final committed source.
    var proposal=current
    try PublicationCommands.resizePages(in:&proposal,publicationID:publicationID,width:width,height:height)
    session.canvas?.finishText()
    guard store.project?.id==projectID else{return false}
    _=try store.engine.call("form_publication",arguments:arguments,source:"Studio")
    store.changed();session.objectWillChange.send();session.canvas?.synchronize()
    return true
  }
}

struct PublicationTrimControls:View {
  @ObservedObject var session:ArtworkSession
  let project:Project,document:PublicationDocument
  var body:some View {
    if let page=document.pages.first.flatMap({entry in project.objects.first{$0.id==entry.objectID}}) {
      let target=PublicationTrimTarget(projectID:project.id,publicationID:document.id)
      HStack(spacing:10) {
        Text("Trim").foregroundStyle(Palette.secondary)
        ArtworkUnitField("W",value:page.artworkSize.x,unit:.mm,accessibilityName:"Publication trim width"){value in
          _=try target.resize(using:session,width:value)
        }.accessibilityIdentifier("publication-trim-width")
        ArtworkUnitField("H",value:page.artworkSize.y,unit:.mm,accessibilityName:"Publication trim height"){value in
          _=try target.resize(using:session,height:value)
        }.accessibilityIdentifier("publication-trim-height")
      }.font(InspectorStyle.labelFont)
        .help("Resize every page and its folded parent sheets together. Existing artwork keeps its physical scale and position.")
        .accessibilityIdentifier("publication-trim-controls").id(target)
    }
  }
}

import AppKit
import FormCore
import SwiftUI

/// Publication navigation is a lens on the existing Canvas, not another surface.
extension StudioStore {
  var publicationPagesAreShown:Bool {
    environment == .form && !showingHome && !canvasFindVisible && artworkSession.publicationWorkspace.isVisible
      && (mode == .artwork || surfaceLayout != .single)
  }
  func showPublicationPages(_ id:UUID?=nil) {
    guard project != nil else{return}
    if environment != .form {showEnvironment(.form)}
    if surfaceLayout == .split {
      showingHome=false;activateDesignSurface(.artwork);designSurfaceHost?.refresh()
    }else{showSurface(.artwork,ensureCanvasIfNeeded:false)}
    canvasFindVisible=false
    artworkSession.publicationWorkspace.open(id)
  }
  func togglePublicationPages() {
    if publicationPagesAreShown {
      artworkSession.publicationWorkspace.close()
    }else{showPublicationPages()}
  }
}

extension PublicationWorkspaceController {
  func showSettings() {
    guard let document else{return}
    if currentPageID==nil,let page=document.pages.first {focusPage(page.objectID)}
    if let session {NotificationCenter.default.post(name:.formShowCanvasInspector,object:session,userInfo:["publication_settings":true])}
  }
}

struct PublicationPagesButton:View {
  @EnvironmentObject private var store:StudioStore
  @ObservedObject var controller:PublicationWorkspaceController
  var body:some View {
    let shown=store.publicationPagesAreShown
    Button {store.togglePublicationPages()} label:{
      Label("Pages",systemImage:"book.pages").font(.system(size:11,weight:.medium))
        .padding(.horizontal,8).frame(height:28)
        .background(shown ? Palette.accent.opacity(0.09):.clear,in:RoundedRectangle(cornerRadius:6))
    }.buttonStyle(.plain).foregroundStyle(shown ? Palette.accent:Palette.secondary)
      .help("Publication pages · ⇧⌘P").accessibilityLabel("Publication pages")
      .accessibilityValue(shown ? "Shown":"Hidden")
      .accessibilityIdentifier("publication-pages-navigation")
  }
}

struct PublicationNavigationPosition {
  let index:Int?
  let count:Int
  let title:String
  init(document:PublicationDocument,selectedPageID:UUID?,spreads:Bool) {
    let groups=spreads ? document.spreads().map(\.pages):document.pages.map{[$0]}
    index=groups.firstIndex{$0.contains{$0.objectID==selectedPageID}}
    count=groups.count
    title=index.map{groups[$0].compactMap{document.pageLabel(for:$0.objectID)}.joined(separator:"–")} ?? "Choose a page"
  }
  func canNavigate(_ delta:Int)->Bool {index.map{(0..<count).contains($0+delta)} ?? false}
  static func resolve(_ query:String,in document:PublicationDocument)->UUID? {
    let value=query.trimmingCharacters(in:.whitespacesAndNewlines)
    guard !value.isEmpty else{return nil}
    // Printed labels take precedence: entering18 means folio18 even when covers
    // put it at logical page20. Ordinal lookup also makes unlabelled pages usable.
    if let page=document.pages.first(where:{document.pageLabel(for:$0.objectID)?.localizedCaseInsensitiveCompare(value) == .orderedSame}) {return page.objectID}
    if let ordinal=Int(value),ordinal>0,document.pages.indices.contains(ordinal-1) {return document.pages[ordinal-1].objectID}
    return nil
  }
}

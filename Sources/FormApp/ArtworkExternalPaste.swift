import AppKit
import FormCore
import FormGraphics
import Foundation
import SwiftUI

/// A value snapshot: no pasteboard access is performed by background decoders.
enum ExternalArtworkClipboard: Sendable {
  case figma(String)
  case svg(Data)

  @MainActor static func read(_ board:NSPasteboard)throws->Self {
    let maximum=16*1024*1024
    if let data=board.data(forType:.html) {
      guard data.count<=maximum else{throw FormError.invalid("Clipboard HTML exceeds the 16 MiB import limit.")}
      guard let html=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.utf16) else{throw FormError.invalid("Clipboard HTML has an unsupported text encoding.")}
      if html.contains("(figma)") || html.contains("(figmeta)") {return .figma(html)}
    }
    for type in ["public.svg-image","image/svg+xml","com.adobe.svg"] {
      if let data=board.data(forType:.init(type)) {
        guard data.count<=10_000_000 else{throw FormError.invalid("Clipboard SVG exceeds the 10 MB import limit.")}
        return .svg(data)
      }
    }
    if let data=board.data(forType:.string) {
      guard data.count<=maximum else{throw FormError.invalid("Clipboard text exceeds the artwork import limit.")}
      if let text=String(data:data,encoding:.utf8) {
        let head=text.trimmingCharacters(in:.whitespacesAndNewlines)
        if head.hasPrefix("<svg") || head.hasPrefix("<?xml") && head.contains("<svg") {
          guard data.count<=10_000_000 else{throw FormError.invalid("Clipboard SVG exceeds the 10 MB import limit.")}
          return .svg(data)
        }
      }
    }
    throw FormError.invalid("The clipboard does not contain supported editable artwork.")
  }
}

struct ExternalArtworkPasteCandidate: Sendable {
  var bundle:ArtworkTransferBundle
  var bounds:Rect2
  var issues:[String]
  var application:String

  static func figma(_ html:String)throws->Self {
    let document=try FigmaClipboardDecoder.decode(html:html)
    let result=try FigmaArtworkImporter.read(document)
    try Task.checkCancellation()
    let errors=result.issues.filter{$0.severity=="error"}
    guard errors.isEmpty else{throw FormError.invalid("Figma paste could not preserve all visible content: "+errors.prefix(3).map(\.message).joined(separator:" "))}
    let notes=result.issues.map{String("\($0.feature): \($0.message)".prefix(2000))}
    var art=result.artwork,assets=result.assets
    let bytes=Data(html.utf8),name=ArtworkTransferBundle.portableName(digest:ArtworkTransferBundle.digest(bytes),extension:"figma")
    assets[name]=bytes
    art.imports=(art.imports ?? [])+[.init(asset:name,name:"Figma clipboard",width:max(0.001,result.bounds.width),height:max(0.001,result.bounds.height),issues:Array(notes.prefix(500)),elementIDs:art.elements.map(\.id),format:"figma")]
    let bundle=try ArtworkTransferBundle.external(artwork:art,selection:result.selectedRootIDs,assets:assets,components:result.components,application:"Figma")
    return .init(bundle:bundle,bounds:result.bounds,issues:notes,application:"Figma")
  }

  @MainActor static func svg(_ data:Data)throws->Self {
    let result=try SVGImporter.read(data,name:"Pasted SVG")
    // SVG warnings can include omitted visible content. Preserve the existing
    // file import's review requirement rather than silently accepting that loss.
    guard !result.hasWarnings else{throw FormError.invalid("This SVG needs fidelity review: "+result.issues.filter{$0.severity=="warning"}.prefix(3).map(\.summary).joined(separator:" ")+" Use Import SVG to review it.")}
    var art=result.artwork,assets=result.assets
    let name="source-"+ArtworkTransferBundle.digest(data)+".svg"
    assets[name]=data
    let notes=result.issues.map(\.summary)
    art.imports=(art.imports ?? [])+[.init(asset:name,name:"Pasted SVG",width:result.width,height:result.height,issues:notes,elementIDs:art.elements.map(\.id),format:"svg")]
    let roots=Set(art.elements.filter{$0.parentID==nil}.map(\.id))
    return .init(bundle:try .external(artwork:art,selection:roots,assets:assets,application:"SVG"),bounds:.init(0,0,result.width,result.height),issues:notes,application:"SVG")
  }
}

extension ArtworkSession {
  func pasteExternalArtwork(from board:NSPasteboard) {
    guard let store,let objectID,let project=store.project else{return}
    let input:ExternalArtworkClipboard
    do{input=try .read(board)}catch{lastTransferError=error.localizedDescription;store.toast(error.localizedDescription,symbol:"exclamationmark.triangle");return}
    let projectID=project.id,epoch=store.artworkTransferProjectEpoch,scope=scopeID,projection=activeProjection
    let frame=activeCanvasFrame
    let center:Point2
    if let canvas {
      var visible=canvas.unobscuredVisibleCanvasRect
      if let frame,!frame.isWorkspace {
        let overlap=visible.intersection(frame.rect)
        visible=overlap.isNull || overlap.isEmpty ? frame.rect:overlap
      }
      center = .init(visible.midX-(frame?.rect.minX ?? 0),visible.midY-(frame?.rect.minY ?? 0))
    }else{center = .init((frame?.rect.width ?? 200)/2,(frame?.rect.height ?? 140)/2)}
    cancelArtworkTransfer();let token=UUID();transferGeneration=token;transferInFlight=true;lastTransferError=nil;lastTransferResult=nil
    transferTask=Task { [weak self,weak store] in
      guard let self,let store else{return}
      defer{if self.transferGeneration==token{self.transferInFlight=false}}
      @MainActor func validateContext()throws {
        try Task.checkCancellation()
        guard self.transferGeneration==token,self.objectID==objectID,self.scopeID==scope,self.activeProjection==projection,
          store.project?.id==projectID,store.artworkTransferProjectEpoch==epoch else{throw CancellationError()}
      }
      do {
        let candidate:ExternalArtworkPasteCandidate
        switch input {
        case .figma(let html):
          let job=Task.detached(priority:.userInitiated){try ExternalArtworkPasteCandidate.figma(html)}
          candidate=try await withTaskCancellationHandler(operation:{try await job.value},onCancel:{job.cancel()})
        case .svg(let data):candidate=try ExternalArtworkPasteCandidate.svg(data)
        }
        try validateContext()
        let offset=Point2(center.x-candidate.bounds.center.x,center.y-candidate.bounds.center.y)
        let prepared=try store.prepareArtworkTransfer(candidate.bundle,objectID:objectID,scopeID:scope,offset:offset,sourceTransform:projection?.sourceToLocal.inverse)
        var result=try await store.importArtworkTransfer(prepared,source:"Studio",validateContext:validateContext)
        try validateContext()
        result["source_application"]=candidate.application;result["import_notes"]=candidate.issues
        self.lastTransferResult=result
        if let raw=result["selected_elements"] as? [String]{self.choose(Set(raw.compactMap(UUID.init(uuidString:))))}
        store.changed()
        store.toast(candidate.issues.isEmpty ? "Pasted \(candidate.application) artwork":"Pasted \(candidate.application) artwork · \(candidate.issues.count) import notes",symbol:candidate.issues.isEmpty ? "doc.on.clipboard":"info.circle")
      }catch{
        guard self.transferGeneration==token else{return}
        self.lastTransferError=error.localizedDescription
        if !(error is CancellationError){store.toast(error.localizedDescription,symbol:"exclamationmark.triangle")}
      }
    }
  }
}

struct ArtworkImportNotes:View {
  @ObservedObject var session:ArtworkSession
  private var sources:[ArtworkImport] {
    (session.sourceArtwork.imports ?? []).filter{source in
      !source.issues.isEmpty && (session.selection.isEmpty || source.elementIDs.map{!Set($0).isDisjoint(with:session.selection)} ?? true)
    }
  }
  var body:some View {
    if !sources.isEmpty {
      DisclosureGroup("Import notes (\(sources.reduce(0){$0+$1.issues.count}))") {
        VStack(alignment:.leading,spacing:8) {
          ForEach(sources){source in
            Text(source.name).font(.caption.bold())
            ForEach(Array(source.issues.enumerated()),id:\.offset){_,note in Text(note).font(.caption).fixedSize(horizontal:false,vertical:true)}
          }
        }.textSelection(.enabled)
      }.font(InspectorStyle.captionFont)
    }
  }
}

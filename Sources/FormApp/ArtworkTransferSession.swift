import AppKit
import FormCore

@MainActor enum ArtworkTransferPasteboard {
  static let type=NSPasteboard.PasteboardType("studio.form.artwork")
}

extension ArtworkSession {
  func cancelArtworkTransfer() {
    transferGeneration=UUID()
    transferTask?.cancel()
    transferTask=nil
    transferInFlight=false
  }
  @discardableResult func copyArtwork()->Bool {
    guard let store,let objectID,!selection.isEmpty else{return false}
    do {
      var bundle=try store.captureArtworkTransfer(objectID:objectID,ids:selection)
      if let projection=activeProjection {bundle.metadata.artwork=projection.display(bundle.metadata.artwork)}
      let data=try bundle.encoded()
      // Everything is captured/validated before pasteboard ownership changes.
      let board=transferPasteboard ?? .general
      let success:Bool
      if let publisher=transferPasteboardPublisher {success=try publisher(board,data,ArtworkTransferPasteboard.type)}else{
        let item=NSPasteboardItem();guard item.setData(data,forType:ArtworkTransferPasteboard.type) else{throw FormError.invalid("Could not prepare the portable clipboard item.")}
        board.clearContents();success=board.writeObjects([item])
      }
      guard success else{throw FormError.invalid("The clipboard did not accept the artwork; its source was preserved.")}
      lastTransferError=nil;return true
    }catch{lastTransferError=error.localizedDescription;store.toast(error.localizedDescription,symbol:"exclamationmark.triangle");return false}
  }
  func cutArtwork() {
    guard let store,let before=store.project,let objectID else{return}
    guard let object=before.objects.first(where:{$0.id==objectID}),!object.locked,!before.artworkOwner(object).locked else {
      lastTransferError="Choose an unlocked artwork source before cutting."
      store.toast(lastTransferError!,symbol:"exclamationmark.triangle");return
    }
    let selected=selection,projection=activeProjection
    guard copyArtwork() else{return}
    do {
      var compare=store.project;compare?.camera=before.camera
      guard compare==before,self.objectID==objectID,selection==selected,activeProjection==projection else{throw FormError.invalid("The source changed during clipboard publication. Nothing was cut.")}
      try store.engine.edit("Cut artwork",source:"Studio") {project in
        guard let object=project.objects.first(where:{$0.id==objectID}),var art=project.editableArtwork(object) else{throw FormError.missing("The cut source is unavailable.")}
        let all=art.descendants(of:selected)
        let masks=Set(art.elements.filter{all.contains($0.id)}.compactMap(\.clipID)).subtracting(all)
        var deletion=selected
        for mask in masks where art.elements.filter({$0.clipID==mask}).allSatisfy({all.contains($0.id)}) {deletion.insert(mask)}
        _ = try ArtworkCommands.apply("delete",to:&art,ids:deletion);try project.setArtwork(art,for:object.id,recordingStyleOverrides:false)
      }
      choose([]);store.changed();lastTransferError=nil
    }catch{lastTransferError=error.localizedDescription;store.toast(error.localizedDescription,symbol:"exclamationmark.triangle")}
  }
  func pasteArtwork() {
    guard let store,let objectID else{return}
    // Tests inject a private board. Native user actions use the ordinary board.
    let board=transferPasteboard ?? .general
    guard let data=board.data(forType:ArtworkTransferPasteboard.type) else{return}
    let projection=activeProjection
    let prepared:PreparedArtworkTransfer
    do {prepared=try store.prepareArtworkTransfer(ArtworkTransferBundle.decode(data),objectID:objectID,scopeID:scopeID,sourceTransform:projection?.sourceToLocal.inverse)}catch{lastTransferError=error.localizedDescription;store.toast(error.localizedDescription,symbol:"exclamationmark.triangle");return}
    cancelArtworkTransfer();let token=UUID();transferGeneration=token;transferInFlight=true;lastTransferError=nil;lastTransferResult=nil
    transferTask=Task { [weak self,weak store] in
      guard let self,let store else{return}
      defer{if self.transferGeneration==token {self.transferInFlight=false}}
      do {
        let result=try await store.importArtworkTransfer(prepared,source:"Studio",validateContext:{[weak self] in
          guard let self,self.transferGeneration==token,self.objectID==prepared.objectID,self.scopeID==prepared.scopeID,self.activeProjection==projection else{throw CancellationError()}
        })
        guard self.transferGeneration==token,self.objectID==prepared.objectID,self.scopeID==prepared.scopeID,store.project?.id==prepared.projectID,store.artworkTransferProjectEpoch==prepared.projectEpoch else{return}
        self.lastTransferResult=result
        if let raw=result["selected_elements"] as? [String] {self.choose(Set(raw.compactMap(UUID.init(uuidString:))))}
        store.changed();store.toast("Pasted artwork",symbol:"doc.on.clipboard")
      }catch{
        guard self.transferGeneration==token else{return}
        self.lastTransferError=error.localizedDescription;store.toast(error.localizedDescription,symbol:"exclamationmark.triangle")
      }
    }
  }
}

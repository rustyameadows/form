import AppKit
import Combine
import SwiftUI

/// One project-owned review window. Opening it never selects a controller run
/// or replaces the composing view and its native text editor.
@MainActor final class StudioImageReviewPresenter:NSObject,ObservableObject,NSWindowDelegate {
  static let windowIdentifier=NSUserInterfaceItemIdentifier("lab.studio.imageReview")
  private(set) var window:NSWindow?
  private var scopeSubscription:AnyCancellable?

  func show(controller:StudioImageGenerationController,library:StudioAssetLibrary,runID:UUID,assetID:UUID?,onUseInCanvas:((UUID)->Void)?=nil) {
    guard let run=controller.history.first(where:{$0.id==runID && $0.capture.projectID==controller.projectID}),
      controller.store?.project?.id==run.capture.projectID,controller.store?.showingHome==false,
      library.projectID==nil || library.projectID==run.capture.projectID,
      assetID.map({run.outputAssetIDs.contains($0) && library.asset(id:$0)?.metadata.projectID==run.capture.projectID}) ?? true else{return}
    let created=window==nil
    let target=window ?? NSWindow(contentRect:.init(x:0,y:0,width:980,height:740),
      styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
    target.identifier=Self.windowIdentifier;target.isReleasedWhenClosed=false;target.delegate=self
    target.representedURL=assetID.flatMap{library.asset(id:$0)}.flatMap{try? library.fileURL(for:$0)}
    target.title=assetID.flatMap{library.asset(id:$0)?.name} ?? run.capture.scene.name
    target.contentMinSize = .init(width:640,height:440)
    target.contentViewController=NSHostingController(rootView:StudioImageReviewWindowContent(
      controller:controller,library:library,runID:runID,assetID:assetID,onUseInCanvas:onUseInCanvas,
      onClose:{[weak self] in self?.close()}).labInterface())
    window=target
    let owner=run.capture.projectID
    scopeSubscription=controller.store?.objectWillChange.sink{[weak self,weak store=controller.store] _ in
      DispatchQueue.main.async {
        if store?.project?.id != owner || store?.showingHome==true {self?.close()}
      }
    }
    if created {target.center()}
    // Keep the prompt editor's first responder and the main window's key state.
    target.orderFront(nil)
  }
  func close() {
    scopeSubscription=nil
    guard let target=window else{return}
    window=nil;target.delegate=nil;target.contentViewController=nil;target.close()
  }
  func windowWillClose(_ notification:Notification) {
    guard let target=notification.object as? NSWindow,target===window else{return}
    scopeSubscription=nil
    window=nil;target.delegate=nil;target.contentViewController=nil
  }
}

@MainActor private struct StudioImageReviewWindowContent:View {
  @ObservedObject var controller:StudioImageGenerationController
  @ObservedObject var library:StudioAssetLibrary
  let runID:UUID
  @State private var selectedAssetID:UUID?
  var onUseInCanvas:((UUID)->Void)?
  var onClose:()->Void
  init(controller:StudioImageGenerationController,library:StudioAssetLibrary,runID:UUID,assetID:UUID?,onUseInCanvas:((UUID)->Void)?,onClose:@escaping()->Void) {
    self.controller=controller;self.library=library;self.runID=runID
    self.onUseInCanvas=onUseInCanvas;self.onClose=onClose;_selectedAssetID=State(initialValue:assetID)
  }
  var body:some View {
    VStack(spacing:16) {
      HStack {StudioDemoBadge();Spacer();AppCloseButton("Close image preview",keyEquivalent:"\u{1b}",action:onClose)}
      StudioImageResultReview(controller:controller,library:library,selectedAssetID:$selectedAssetID,runID:runID,
        onIterate:{controller.iterate(resultAssetID:$0)},onRegenerate:{
          controller.selectRun(runID);Task{await controller.retry()}
        },onUseInCanvas:onUseInCanvas)
    }.padding(20).background(Palette.paper)
      .onChange(of:controller.store?.project?.id){_,id in if id != controller.projectID {onClose()}}
  }
}

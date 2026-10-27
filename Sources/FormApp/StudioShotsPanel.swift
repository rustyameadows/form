import AppKit
import FormCore
import SwiftUI

/// Geometry observations support actual pointer tests of dynamic button rows.
/// Reading these anchors cannot invoke an action or change layout/focus.
struct StudioShotControlAnchors:PreferenceKey {
  static let defaultValue:[String:Anchor<CGRect>]=[:]
  static func reduce(value:inout [String:Anchor<CGRect>],nextValue:()->[String:Anchor<CGRect>]) {value.merge(nextValue()){_,new in new}}
}

struct StudioShotsPanel:View {
  @ObservedObject var controller:StudioShotController
  @EnvironmentObject var store:StudioStore
  var body:some View {
    VStack(alignment:.leading,spacing:9) {
      SectionLabel("SAVED SHOTS")
      Menu(controller.editingID.flatMap{id in controller.shots.first{$0.id==id}?.name} ?? "Recall a saved shot") {
        ForEach(controller.shots) {shot in Button(shot.name){controller.perform{try controller.recall(shot.id)}}}
      }.disabled(controller.shots.isEmpty).accessibilityLabel("Saved Studio shots")
      TextField("Shot name",text:$controller.name).textFieldStyle(.roundedBorder).accessibilityLabel("Studio shot name")
      Picker("Subjects",selection:$controller.visibilityMode) {
        Text("Whole project").tag("project")
        if controller.editingID != nil {Text("Saved object IDs").tag("saved")}
        Text("Selected objects").tag("selection")
      }.font(.system(size:11))
      Text(controller.subjectSummary).font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      Picker("Lighting",selection:$controller.lighting) {Text("Classic").tag("classic-v1");Text("Soft side").tag("soft-side-v1");Text("Rim").tag("rim-v1")}.accessibilityLabel("Studio lighting")
      HStack {TextField("Width",text:$controller.width).accessibilityLabel("Shot output width").anchorPreference(key:StudioShotControlAnchors.self,value:.bounds){["width":$0]};Text("×");TextField("Height",text:$controller.height).accessibilityLabel("Shot output height");Text("px")}.textFieldStyle(.roundedBorder).font(.system(size:11))
      HStack(spacing:6) {Button(controller.editingID == nil ? "Capture shot":"New shot"){controller.perform{try controller.save(capture:true)}}.accessibilityLabel("Capture Studio shot").anchorPreference(key:StudioShotControlAnchors.self,value:.bounds){["capture":$0]}
        if let id=controller.editingID {Button("Update"){controller.perform{try controller.save(capture:false)}}.accessibilityLabel("Update Studio shot").anchorPreference(key:StudioShotControlAnchors.self,value:.bounds){["update":$0]};Menu("More") {Button("Rename"){controller.perform{try controller.rename(id)}};Button("Delete",role:.destructive){controller.perform{try controller.delete(id)}}}.accessibilityLabel("Saved shot actions")}
      }.font(.system(size:11))
      if controller.reviewingID != nil {Button("Leave reference frame"){controller.leaveReview()}.font(.system(size:10));Text("Camera and option changes remain a draft until Update.").font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
      if controller.editingID != nil && controller.reviewingID == nil {Text("Saved definition selected. Recall activates its frame; Update saves the current view.").font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
      Button("Preview output"){NSApp.keyWindow?.makeFirstResponder(nil);controller.requestPreview()}.accessibilityLabel("Preview Studio output")
      if controller.busy {ProgressView().controlSize(.small)}
      if let image=controller.preview {Image(nsImage:image).resizable().aspectRatio(contentMode:.fit).frame(maxHeight:150).accessibilityLabel("Complete Studio output preview")}
      if let error=controller.error {Text(error).font(.system(size:10)).foregroundStyle(Palette.ink).fixedSize(horizontal:false,vertical:true)}
      Button("Export shot folder (PNG + record)"){controller.exportDialog()}.font(.system(size:11,weight:.semibold)).accessibilityLabel("Export shot folder PNG and record").anchorPreference(key:StudioShotControlAnchors.self,value:.bounds){["export":$0]}
      if let path=controller.lastExport {Text(path.lastPathComponent).font(.system(size:10)).textSelection(.enabled)}
    }.onReceive(NotificationCenter.default.publisher(for:NSControl.textDidEndEditingNotification)){_ in
      DispatchQueue.main.async {controller.reconcile()}
    }.onChange(of:store.studioPreset){_,_ in controller.invalidatePreview()}.onChange(of:store.engine.selection){_,_ in if controller.visibilityMode=="selection" {controller.invalidatePreview()}}.onAppear{controller.reconcile()}.onChange(of:store.project?.id){_,_ in controller.reconcile()}.onChange(of:store.revision){_,_ in controller.reconcile()}
  }
}
/// Only an explicitly recalled shot activates this layout. Ordinary Table and
/// Studio retain their original full-size NSView and navigation event boundary.
struct StudioFramedTable:View {
  @EnvironmentObject var store:StudioStore
  @ObservedObject var controller:StudioShotController
  var body:some View {
    GeometryReader {g in
      if store.mode == .studio,let aspect=controller.referenceAspect {
        let w=max(1,g.size.width-344),h=max(1,g.size.height-140)
        let width=min(w,h*aspect),height=width/aspect
        ZStack(alignment:.topLeading) {
          Color(nsColor:.windowBackgroundColor)
          TableCanvas().frame(width:width,height:height).overlay(Rectangle().stroke(.secondary.opacity(0.35),lineWidth:1)).position(x:24+w/2,y:70+h/2)
        }
      } else {TableCanvas()}
    }.onChange(of:store.mode){_,mode in if mode != .studio {controller.leaveReview()}}
  }
}

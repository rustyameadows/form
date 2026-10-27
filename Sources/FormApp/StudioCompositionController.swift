import AppKit
import Combine
import FormCore
import SwiftUI

@MainActor final class StudioCompositionController:ObservableObject {
  weak var store:StudioStore?
  @Published private(set) var draft:StudioComposition?
  @Published var selectedInstanceID:UUID?
  @Published var error:String?
  @Published var time=0.0
  @Published private(set) var playing=false
  @Published private(set) var busy=false
  @Published private(set) var progress=0.0
  @Published private(set) var lastOutput:URL?
  let stage=TableSceneController()
  let renderer=StudioShotRenderer()
  private var owner:UUID?,baseline:StudioComposition?
  private var playback:Task<Void,Never>?,exportTask:Task<Void,Never>?,prepareTask:Task<Void,Never>?
  private var generation=0
  private var mediaExportActive=false
  private var undoDrafts:[StudioComposition]=[],redoDrafts:[StudioComposition]=[]
  private var baselineWasSaved=false
  init(store:StudioStore){self.store=store}
  var scenes:[StudioComposition]{store?.project?.studioPresentation?.scenes ?? []}
  var dirty:Bool{draft != baseline}
  var canUndoDraft:Bool{!undoDrafts.isEmpty && !busy}
  var canRedoDraft:Bool{!redoDrafts.isEmpty && !busy}
  var selected:StudioInstance?{draft?.instances.first{$0.id==selectedInstanceID}}
  var products:[ProductObject]{store?.project?.objects.filter{!$0.isCanvasWorkspace && $0.recipeID != "reference"} ?? []}
  func reconcile() {
    guard let project=store?.project else{reset();return}
    if owner != project.id {reset();owner=project.id;draft=scenes.first ?? .fromProject(project);baseline=draft;baselineWasSaved=scenes.contains{$0.id==draft?.id};sync();return}
    if !dirty,baselineWasSaved,!scenes.contains(where:{$0.id==baseline?.id}) {draft=scenes.first ?? .fromProject(project);baseline=draft;baselineWasSaved=scenes.contains{$0.id==draft?.id};undoDrafts=[];redoDrafts=[]}
    if !dirty,let id=draft?.id,let saved=scenes.first(where:{$0.id==id}),saved != baseline {draft=saved;baseline=saved}
    if let id=selectedInstanceID,draft?.instances.contains(where:{$0.id==id}) != true {selectedInstanceID=nil}
    sync()
  }
  func reset(){stop();exportTask?.cancel();prepareTask?.cancel();owner=nil;draft=nil;baseline=nil;selectedInstanceID=nil;lastOutput=nil;error=nil;generation+=1;renderer.clear();undoDrafts=[];redoDrafts=[];baselineWasSaved=false}
  func load(_ id:UUID,discard:Bool=false) {
    guard !busy else{return}
    guard !dirty || discard else{error="Save this scene or discard its draft before choosing another scene.";return}
    guard let scene=scenes.first(where:{$0.id==id}) else{return}
    stop();draft=scene;baseline=scene;baselineWasSaved=true;undoDrafts=[];redoDrafts=[];selectedInstanceID=nil;time=0;error=nil;sync()
  }
  func newScene(discard:Bool=false) {
    guard !busy,let project=store?.project else{return}
    guard !dirty || discard else{error="Save this scene or discard its draft before creating another.";return}
    stop();draft = .fromProject(project,name:"Still life \(scenes.count+1)");baseline=draft;baselineWasSaved=false;undoDrafts=[];redoDrafts=[];time=0;selectedInstanceID=nil;sync()
  }
  func discard(){if let id=draft?.id,scenes.contains(where:{$0.id==id}){load(id,discard:true)}else{newScene(discard:true)};error=nil}
  func change(_ body:(inout StudioComposition)->Void) {
    guard !busy,var value=draft else{return};stop();body(&value);guard value != draft else{return};rememberDraft();draft=value;time=0;error=nil;sync()
  }
  private func rememberDraft(){if let draft {undoDrafts.append(draft);if undoDrafts.count>80{undoDrafts.removeFirst()};redoDrafts=[];store?.objectWillChange.send()}}
  func undoDraft()->Bool {guard !busy,let value=undoDrafts.popLast(),let draft else{return false};stop();redoDrafts.append(draft);self.draft=value;time=0;sync();return true}
  func redoDraft()->Bool {guard !busy,let value=redoDrafts.popLast(),let draft else{return false};stop();undoDrafts.append(draft);self.draft=value;time=0;sync();return true}
  func changeInstance(_ body:(inout StudioInstance)->Void) {guard let id=selectedInstanceID else{return};change{scene in if let i=scene.instances.firstIndex(where:{$0.id==id}){body(&scene.instances[i])}}}
  func add(_ object:ProductObject) {
    change{scene in
      let count=scene.instances.filter{$0.sourceObjectID==object.id}.count
      let instance=StudioInstance(name:object.name+" \(count+1)",sourceObjectID:object.id,positionMM:.init(Double(count)*(object.footprintWidth+25),0,0))
      scene.instances.append(instance);selectedInstanceID=instance.id
    }
  }
  func addShelf(){change{scene in let prop=StudioInstance(name:"Shelf / riser",prop:.init(),positionMM:.init(0,0,0));scene.instances.append(prop);selectedInstanceID=prop.id}}
  func duplicateInstance(){guard var instance=selected else{return};instance.id=UUID();instance.name+=" copy";instance.positionMM.x+=80;change{$0.instances.append(instance)};selectedInstanceID=instance.id}
  func removeInstance(){guard let id=selectedInstanceID else{return};change{$0.instances.removeAll{$0.id==id}};selectedInstanceID=nil}
  func save() {
    NSApp.keyWindow?.makeFirstResponder(nil)
    do {
      guard let store,let draft else{return};try draft.validate()
      let result=try store.engine.call("form_studio_scene",arguments:["command":"save","scene":try jsonObject(draft)],source:"Studio")
      let saved=try JSONDecoder.form.decode(StudioComposition.self,from:JSONSerialization.data(withJSONObject:result))
      self.draft=saved;baseline=saved;baselineWasSaved=true;undoDrafts=[];redoDrafts=[];store.metadataRecordsChanged();error=nil;store.toast("Scene saved")
    }catch{self.error=error.localizedDescription}
  }
  func duplicateScene(){guard let store,let draft,scenes.contains(where:{$0.id==draft.id}),!dirty else{error="Save the scene before duplicating it.";return};do{let result=try store.engine.call("form_studio_scene",arguments:["command":"duplicate","scene_id":draft.id.uuidString],source:"Studio");let value=try JSONDecoder.form.decode(StudioComposition.self,from:JSONSerialization.data(withJSONObject:result));self.draft=value;baseline=value;store.metadataRecordsChanged();sync()}catch{self.error=error.localizedDescription}}
  func deleteScene(){guard let store,let id=draft?.id,scenes.contains(where:{$0.id==id}) else{return};do{_ = try store.engine.call("form_studio_scene",arguments:["command":"delete","scene_id":id.uuidString],source:"Studio");draft=nil;baseline=nil;owner=nil;store.metadataRecordsChanged();reconcile()}catch{self.error=error.localizedDescription}}
  func cameraEdited() {
    guard !playing,!busy,var value=draft else{return}
    value.camera=stage.camera;if value != draft {rememberDraft();draft=value};time=0;objectWillChange.send()
  }
  func frameScene(){stop();stage.fitAll();cameraEdited()}
  func captureEnd(){change{$0.motion.endCamera=stage.camera;$0.motion.mode = .between}}
  func captureStart(){let camera=stage.camera;change{$0.camera=camera;$0.motion.startCamera=camera};time=0}
  func scrub(_ fraction:Double) {stop();time=max(0,min(1,fraction));applyTime()}
  private func applyTime(){guard let draft else{return};do{stage.camera=try draft.motion.camera(start:draft.camera,fraction:time);stage.updateCamera();error=nil}catch{self.error=error.localizedDescription}}
  func play() {
    guard !playing,!busy,let draft else{return}
    do{try draft.validate()}catch{self.error=error.localizedDescription;return}
    playing=true;let started=Date(),duration=draft.motion.seconds;time=0
    playback=Task{[weak self] in
      while !Task.isCancelled,let self,self.playing {
        self.time=min(1,Date().timeIntervalSince(started)/duration);self.applyTime()
        if self.time>=1 {self.playing=false;break}
        try? await Task.sleep(nanoseconds:33_333_333)
      }
    }
  }
  func stop(){playback?.cancel();playback=nil;playing=false}
  func sync() {
    guard let store,let project=store.project,let draft else{return}
    do {
      let resolved=try draft.resolved(in:project)
      let assets=store.repository.url(for:project.id).appendingPathComponent("Assets")
      stage.sync(resolved.project,selection:Set(selectedInstanceID.map{[$0]} ?? []),isolated:resolved.visible,showGrid:false,studio:true,preset:draft.surface,assets:assets,renderObjectIDs:resolved.visible)
      stage.camera=time>0 ? ((try? draft.motion.camera(start:draft.camera,fraction:time)) ?? draft.camera):draft.camera;stage.updateCamera();stage.applyShotLighting(draft.lighting,studio:true)
      prepareTask?.cancel();generation+=1;let token=generation
      if resolved.project.objects.contains(where:{!$0.isCanvasWorkspace && ($0.meshAsset != nil || $0.cadRepresentation != nil)}) {
        prepareTask=Task{[weak self] in
          do {guard let self else{return};try await self.stage.prepareExternalForCapture(project:resolved.project,assets:assets);guard !Task.isCancelled,self.generation==token else{return};self.stage.renderScene()}catch{if !Task.isCancelled,self?.generation==token{self?.error=error.localizedDescription}}
        }
      }
    }catch{
      self.error=error.localizedDescription
      stage.sync(project,selection:[],isolated:[],showGrid:false,studio:true,preset:draft.surface,assets:store.repository.url(for:project.id).appendingPathComponent("Assets"),renderObjectIDs:[])
    }
  }
  func exportDialog(video:Bool) {
    NSApp.keyWindow?.makeFirstResponder(nil)
    guard let draft,!busy else{return}
    let panel=NSSavePanel();panel.title=video ? "Export camera video · MP4 + record":"Export scene image · PNG + record";panel.nameFieldStringValue=draft.name+(video ? ".motion":".render");panel.message="Choose a new output folder. Existing destinations are preserved.";panel.canCreateDirectories=true
    guard panel.runModal() == .OK,let url=panel.url else{return}
    stop();busy=true;progress=0;error=nil
    exportTask=Task{[weak self] in
      guard let self else{return};defer{self.busy=false}
      do{self.lastOutput=try await self.export(draft,to:url,video:video);self.store?.toast(video ? "Camera video exported":"Scene image exported")}catch{self.error=error is CancellationError ? "Export cancelled; no output delivered.":error.localizedDescription}
    }
  }
  func cancelExport(){exportTask?.cancel()}
  func export(_ scene:StudioComposition,to destination:URL,video:Bool)async throws->URL {
    guard !mediaExportActive else{throw FormError.invalid("Finish or cancel the active Studio scene export first.")}
    mediaExportActive=true;defer{mediaExportActive=false}
    guard let store,let project=store.project else{throw FormError.missing("Open a project.")}
    let sources=scene.instances.filter(\.visible).compactMap(\.sourceObjectID)
    if !sources.isEmpty {var check=scene.shot();check.visibility = .init(mode:.objects,objectIDs:Array(Set(sources)));try store.studioShots.runtimePreflight(project,check)}
    let root=store.repository.root.standardizedFileURL.resolvingSymlinksInPath().path
    let path=destination.standardizedFileURL.resolvingSymlinksInPath().path
    let exports=store.repository.url(for:project.id).appendingPathComponent("Exports").standardizedFileURL.resolvingSymlinksInPath().path
    guard !path.hasPrefix(root+"/") || path.hasPrefix(exports+"/") else{throw FormError.invalid("Export into this project's Exports folder or an independent destination.")}
    let assets=store.repository.url(for:project.id).appendingPathComponent("Assets"),digest=try project.studioDesignDigest()
    let stillCurrent:()->Bool = {[weak store] in store?.project?.id==project.id && (try? store?.project?.studioDesignDigest())==digest}
    return try await StudioSceneMedia.export(project:project,scene:scene,assets:assets,renderer:renderer,to:destination,video:video,isCurrent:stillCurrent,progress:{[weak self] value in self?.progress=value})
  }
}

struct StudioCompositionViewport:NSViewRepresentable {
  @ObservedObject var controller:StudioCompositionController
  func makeNSView(context:Context)->TableSceneView {
    let view=TableSceneView(frame:.zero);view.clipsToBounds=true;view.controller=controller.stage;controller.stage.view=view
    view.setAccessibilityLabel("Studio composition stage · drag to orbit, Shift-drag to pan")
    view.onCameraInteraction={[weak controller] in controller?.cameraEdited()}
    view.onObjectPick={[weak controller] id in if controller?.draft?.instances.contains(where:{$0.id==id})==true{controller?.selectedInstanceID=id;controller?.sync()}}
    return view
  }
  func updateNSView(_ view:TableSceneView,context:Context){}
  static func dismantleNSView(_ view:TableSceneView,coordinator:()){view.cancelPointerInteraction();view.onCameraInteraction=nil;view.onObjectPick=nil}
}

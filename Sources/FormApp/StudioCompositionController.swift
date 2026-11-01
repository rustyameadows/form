import AppKit
import Combine
import FormCore
import SwiftUI
import simd

enum StudioCompositionTool:String,CaseIterable {case orbit,move,lift,rotate}

@MainActor final class StudioCompositionController:ObservableObject {
  weak var store:StudioStore?
  @Published private(set) var draft:StudioComposition?
  @Published var selectedInstanceID:UUID?
  @Published private(set) var selectionRequest=0
  @Published var tool:StudioCompositionTool = .move {didSet{if oldValue != tool {cancelStagePointer();if let view=stage.view {view.window?.invalidateCursorRects(for:view)}}}}
  @Published var gizmoVisible=true {didSet{if oldValue != gizmoVisible {cancelStagePointer();gizmoCache=nil;stage.view?.redrawPresentationOverlay()}}}
  @Published var error:String?
  @Published var time=0.0
  @Published private(set) var playing=false
  @Published private(set) var busy=false
  @Published private(set) var progress=0.0
  @Published private(set) var lastOutput:URL?
  @Published private(set) var pendingSceneID:UUID?
  let stage=TableSceneController()
  let renderer=StudioShotRenderer()
  let thumbnails=StudioSceneThumbnailCache()
  private let resolutionCache=StudioCompositionResolutionCache()
  private struct StageInput:Equatable {
    let sourceRevision:Int,instances:[StudioInstance],surface:String,assets:String,fontRevision:Int
  }
  private var stageInput:StageInput?
  private var appliedLighting:String?
  private(set) var stageSyncCount=0
  var resolutionBuildCount:Int {resolutionCache.builds}
  private var owner:UUID?,baseline:StudioComposition?
  private var playback:Task<Void,Never>?,exportTask:Task<Void,Never>?,prepareTask:Task<Void,Never>?
  private var generation=0
  private var sceneSelectionGeneration=0
  private var mediaExportActive=false
  private var undoDrafts:[StudioComposition]=[],redoDrafts:[StudioComposition]=[]
  private var baselineWasSaved=false
  private var emptyBaseline=false
  private var renderOwners:[UUID:UUID]=[:]
  private var gizmoCache:(generation:Int,camera:CameraState,viewport:CGSize,selection:UUID,builds:Int,value:StudioTransformGizmo)?
  private struct InstanceGesture {
    let projectID:UUID,sceneID:UUID,instanceID:UUID
    let before:StudioComposition,tool:StudioCompositionTool,down:NSPoint
    let initial:Vector3,yaw:Double,planeHeight:Double,planeNormal:Vector3,planeOrigin:Vector3
    let planeDown:Vector3?,heightPerPoint:Double,groundRight:Vector3,groundUp:Vector3
    var gizmo:StudioTransformGizmo?=nil
    var handle:StudioTransformGizmo.Handle?=nil
    var initialAxis:Double?=nil
    var lastAngle:Double?=nil
    var angularDelta=0.0
  }
  private var instanceGesture:InstanceGesture?
  init(store:StudioStore){self.store=store;stage.showsStudioSelection=true}
  var scenes:[StudioComposition]{store?.project?.studioPresentation?.scenes ?? []}
  var contextProjectID:UUID? {owner}
  var contextWasSaved:Bool {baselineWasSaved}
  var dirty:Bool{draft != baseline}
  var canUndoDraft:Bool{!undoDrafts.isEmpty && !busy}
  var canRedoDraft:Bool{!redoDrafts.isEmpty && !busy}
  var selected:StudioInstance?{draft?.instances.first{$0.id==selectedInstanceID}}
  var products:[ProductObject]{store?.project?.objects.filter{$0.hasTablePresentation && $0.recipeID != "reference"} ?? []}
  func reconcile() {
    cancelStagePointer()
    guard let project=store?.project else{reset();return}
    if owner != project.id {reset();owner=project.id;draft=scenes.first ?? .fromProject(project);baseline=draft;baselineWasSaved=scenes.contains{$0.id==draft?.id};sync();return}
    if !dirty,baselineWasSaved,!scenes.contains(where:{$0.id==baseline?.id}) {draft=scenes.first ?? .fromProject(project);baseline=draft;baselineWasSaved=scenes.contains{$0.id==draft?.id};undoDrafts=[];redoDrafts=[]}
    if !dirty,let id=draft?.id,let saved=scenes.first(where:{$0.id==id}),saved != baseline {draft=saved;baseline=saved}
    if let id=selectedInstanceID,draft?.instances.contains(where:{$0.id==id}) != true {selectedInstanceID=nil}
    sync()
  }
  func reset(){cancelStagePointer();stop();exportTask?.cancel();prepareTask?.cancel();owner=nil;draft=nil;baseline=nil;selectedInstanceID=nil;pendingSceneID=nil;lastOutput=nil;error=nil;generation+=1;sceneSelectionGeneration+=1;renderer.clear();thumbnails.reset();resolutionCache.reset();stageInput=nil;appliedLighting=nil;undoDrafts=[];redoDrafts=[];baselineWasSaved=false;emptyBaseline=false;renderOwners=[:]}
  /// Selection may arrive before the workspace's onAppear reconciliation. The
  /// recalled scene must already belong to this project when that happens.
  private func adoptProject() -> Bool {
    guard let project=store?.project else{reset();return false}
    if owner != project.id {reset();owner=project.id}
    return true
  }
  func requestScene(_ id:UUID) {
    guard !busy,adoptProject(),scenes.contains(where:{$0.id==id}) else{return}
    cancelStagePointer()
    sceneSelectionGeneration+=1
    let token=sceneSelectionGeneration,projectID=owner,currentID=draft?.id
    // Commit the old scene's numeric drafts synchronously before focus loss can
    // rebind those controls to the destination. A row click must not be queued
    // behind background captures just to wait for a SwiftUI focus update.
    NotificationCenter.default.post(name:.formCommitArtworkFields,object:nil)
    NSApp.keyWindow?.makeFirstResponder(nil)
    guard !busy,sceneSelectionGeneration==token,
      store?.project?.id==projectID,currentID==nil || draft?.id==currentID else{return}
    guard id != draft?.id else {
      // A failed external/solid preparation is retryable without changing the
      // saved scene or dirtying its draft. Healthy current-scene clicks are free.
      if !dirty,stageInput==nil {sync()}
      return
    }
    if dirty {pendingSceneID=id;return}
    load(id)
  }
  func cancelSceneSelection(){pendingSceneID=nil}
  func discardAndLoadScene(_ id:UUID){load(id,discard:true)}
  func saveAndLoadScene(_ id:UUID) {
    guard scenes.contains(where:{$0.id==id}) else{pendingSceneID=nil;error="That saved scene is no longer available. Your current draft was kept.";return}
    save()
    guard error==nil,!dirty else{return}
    load(id)
  }
  func load(_ id:UUID,discard:Bool=false) {
    guard !busy,adoptProject() else{return}
    cancelStagePointer()
    guard !dirty || discard else{error="Save this scene or discard its draft before choosing another scene.";return}
    guard let scene=scenes.first(where:{$0.id==id}) else{error="That saved scene is no longer available. Your current draft was kept.";return}
    sceneSelectionGeneration+=1
    stop();draft=scene;baseline=scene;baselineWasSaved=true;emptyBaseline=false;undoDrafts=[];redoDrafts=[];selectedInstanceID=nil;pendingSceneID=nil;time=0;error=nil;sync()
  }
  func newScene(discard:Bool=false) {
    guard !busy,adoptProject(),let project=store?.project else{return}
    cancelStagePointer()
    guard !dirty || discard else{error="Save this scene or discard its draft before creating another.";return}
    sceneSelectionGeneration+=1
    stop();draft = .fromProject(project,name:"Still life \(scenes.count+1)");baseline=draft;baselineWasSaved=false;emptyBaseline=false;undoDrafts=[];redoDrafts=[];time=0;selectedInstanceID=nil;pendingSceneID=nil;error=nil;sync()
  }
  func newEmptyScene(discard:Bool=false) {
    guard !busy,adoptProject(),let project=store?.project else{return}
    cancelStagePointer()
    guard !dirty || discard else{error="Save this scene or discard its draft before creating another.";return}
    sceneSelectionGeneration+=1;stop()
    draft=StudioComposition(name:"Still life \(scenes.count+1)",camera:project.camera)
    baseline=draft;baselineWasSaved=false;emptyBaseline=true;undoDrafts=[];redoDrafts=[];time=0;selectedInstanceID=nil;pendingSceneID=nil;error=nil;sync()
  }
  func discard(){if let id=draft?.id,scenes.contains(where:{$0.id==id}){load(id,discard:true)}else if emptyBaseline{newEmptyScene(discard:true)}else{newScene(discard:true)};error=nil}
  func change(_ body:(inout StudioComposition)->Void) {
    guard !busy else{return};cancelStagePointer();guard var value=draft else{return};stop();body(&value);guard value != draft else{return};rememberDraft();draft=value;time=0;error=nil;sync()
  }
  private func rememberDraft(){if let draft {undoDrafts.append(draft);if undoDrafts.count>80{undoDrafts.removeFirst()};redoDrafts=[];store?.objectWillChange.send()}}
  func undoDraft()->Bool {guard !busy else{return false};cancelStagePointer();guard let value=undoDrafts.popLast(),let draft else{return false};stop();redoDrafts.append(draft);self.draft=value;time=0;sync();return true}
  func redoDraft()->Bool {guard !busy else{return false};cancelStagePointer();guard let value=redoDrafts.popLast(),let draft else{return false};stop();undoDrafts.append(draft);self.draft=value;time=0;sync();return true}
  func selectInstance(_ id:UUID?) {
    guard !busy,id==nil || draft?.instances.contains(where:{$0.id==id})==true else{return}
    finishStageEditing()
    cancelStagePointer();selectedInstanceID=id;if id != nil {selectionRequest &+= 1};sync()
  }
  func selectRenderedInstance(_ renderID:UUID?) {selectInstance(renderID.flatMap{renderOwners[$0]})}
  func focusSelected() {
    finishStageEditing()
    guard !busy,let id=selectedInstanceID else{return}
    cancelStagePointer();stop()
    let ids=Set(renderOwners.compactMap{$0.value==id ? $0.key:nil})
    guard !ids.isEmpty else{return}
    stage.frameObjects(ids:ids);cameraEdited()
  }
  func changeInstance(_ body:(inout StudioInstance)->Void) {guard let id=selectedInstanceID else{return};changeInstance(id:id,body)}
  func changeInstance(id:UUID,_ body:(inout StudioInstance)->Void) {change{scene in if let i=scene.instances.firstIndex(where:{$0.id==id}){body(&scene.instances[i])}}}
  func add(_ object:ProductObject) {
    change{scene in
      let count=scene.instances.filter{$0.sourceObjectID==object.id}.count
      let instance=StudioInstance(name:object.name+" \(count+1)",sourceObjectID:object.id,positionMM:.init(Double(count)*(object.footprintWidth+25),0,0))
      scene.instances.append(instance);selectedInstanceID=instance.id
    }
  }
  func addShelf(){change{scene in let prop=StudioInstance(name:"Shelf / riser",prop:.init(),positionMM:.init(0,0,0));scene.instances.append(prop);selectedInstanceID=prop.id}}
  func duplicateInstance(){guard !busy else{return};finishStageEditing();cancelStagePointer();guard var instance=selected else{return};instance.id=UUID();instance.name+=" copy";instance.positionMM.x+=80;change{$0.instances.append(instance);selectedInstanceID=instance.id;selectionRequest &+= 1}}
  func removeInstance(){guard let id=selectedInstanceID else{return};change{$0.instances.removeAll{$0.id==id}};selectedInstanceID=nil}
  func save() {
    cancelStagePointer()
    NSApp.keyWindow?.makeFirstResponder(nil)
    do {
      guard let store,let draft else{return};try draft.validate()
      let result=try store.engine.call("form_studio_scene",arguments:["command":"save","scene":try jsonObject(draft)],source:"Studio")
      let saved=try JSONDecoder.form.decode(StudioComposition.self,from:JSONSerialization.data(withJSONObject:result))
      self.draft=saved;baseline=saved;baselineWasSaved=true;undoDrafts=[];redoDrafts=[];store.metadataRecordsChanged();error=nil;store.toast("Scene saved")
    }catch{self.error=error.localizedDescription}
  }
  func duplicateScene(){guard let store,let draft,scenes.contains(where:{$0.id==draft.id}),!dirty else{error="Save the scene before duplicating it.";return};do{let result=try store.engine.call("form_studio_scene",arguments:["command":"duplicate","scene_id":draft.id.uuidString],source:"Studio");let value=try JSONDecoder.form.decode(StudioComposition.self,from:JSONSerialization.data(withJSONObject:result));stop();self.draft=value;baseline=value;baselineWasSaved=true;undoDrafts=[];redoDrafts=[];selectedInstanceID=nil;time=0;error=nil;store.metadataRecordsChanged();sync()}catch{self.error=error.localizedDescription}}
  func deleteScene(){guard let store,let id=draft?.id,scenes.contains(where:{$0.id==id}) else{return};do{_ = try store.engine.call("form_studio_scene",arguments:["command":"delete","scene_id":id.uuidString],source:"Studio");draft=nil;baseline=nil;owner=nil;store.metadataRecordsChanged();reconcile()}catch{self.error=error.localizedDescription}}
  func cameraEdited() {
    guard !playing,!busy,var value=draft else{return}
    var camera=stage.camera
    // Native layout owns viewportAspect; output framing belongs to pixels.
    // A zero-delta scroll or a rounded viewport must not dirty a saved scene.
    camera.viewportAspect=value.camera.viewportAspect
    value.camera=camera;if value != draft {rememberDraft();draft=value};time=0;objectWillChange.send()
  }
  func frameScene(){finishStageEditing();cancelStagePointer();guard !busy,draft?.instances.contains(where:{$0.visible})==true else{return};stop();stage.fitAll();cameraEdited()}
  func captureEnd(){change{$0.motion.endCamera=stage.camera;$0.motion.mode = .between}}
  func captureStart(){let camera=stage.camera;change{$0.camera=camera;$0.motion.startCamera=camera};time=0}
  func scrub(_ fraction:Double) {cancelStagePointer();stop();time=max(0,min(1,fraction));applyTime()}
  private func applyTime(){guard let draft else{return};do{stage.camera=try draft.motion.camera(start:draft.camera,fraction:time);stage.updateCamera();error=nil}catch{self.error=error.localizedDescription}}
  func play() {
    cancelStagePointer()
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
  private func cancelStagePointer() {
    if let view=stage.view {view.cancelPointerInteraction()} else {cancelPresentationInteraction()}
  }
  private func finishStageEditing() {
    guard let view=stage.view,let window=view.window else{return}
    if let editor=window.firstResponder as? NSTextView,editor.isFieldEditor {
      editor.doCommand(by:#selector(NSResponder.insertNewline(_:)))
    }
    window.makeFirstResponder(view)
  }
  func sync() {
    guard let store,let project=store.project,let draft else{return}
    let assets=store.repository.url(for:project.id).appendingPathComponent("Assets")
    do {try draft.validate()} catch {
      prepareTask?.cancel();prepareTask=nil;generation+=1;stageInput=nil;renderOwners=[:]
      self.error=error.localizedDescription
      stage.sync(project,selection:[],isolated:[],showGrid:false,studio:true,preset:draft.surface,assets:assets,renderObjectIDs:[])
      stageSyncCount &+= 1;return
    }
    let input=StageInput(sourceRevision:resolutionCache.synchronize(project),instances:draft.instances,
      surface:draft.surface,assets:assets.standardizedFileURL.path,fontRevision:GeometryFactory.fontRevision)
    if stageInput==input {
      // Selection and camera edits do not change geometry. In particular, keep
      // an in-flight solid/model preparation alive while the user picks a copy.
      stage.updateSelection(Set(selectedInstanceID.map{[$0]} ?? []),studio:true)
      applyPresentation(draft)
      return
    }
    // Invalidate before resolution: a failed new scene cannot publish an older
    // asynchronous preparation into its preview.
    prepareTask?.cancel();prepareTask=nil;generation+=1;let token=generation
    stageInput=nil
    if draft.instances.allSatisfy({!$0.visible}) {
      renderOwners=[:];error=nil
      stage.sync(project,selection:[],isolated:[],showGrid:false,studio:true,preset:draft.surface,assets:assets,renderObjectIDs:[])
      stageSyncCount &+= 1;stageInput=input;applyPresentation(draft,forceLighting:true)
      return
    }
    do {
      let resolved=try resolutionCache.resolve(draft,in:project)
      let objects=Dictionary(uniqueKeysWithValues:resolved.project.objects.map{($0.id,$0)})
      let roots=Set(draft.instances.map(\.id))
      renderOwners=[:]
      for renderID in resolved.visible {
        var current=renderID,visited=Set<UUID>()
        while visited.insert(current).inserted {
          if roots.contains(current) {renderOwners[renderID]=current;break}
          guard let object=objects[current],let parent=object.textile?.attachment?.garmentID ?? object.clothAttachment?.surfaceObjectID ?? object.patternAssemblyAttachment?.surfaceObjectID else{break}
          current=parent
        }
      }
      stage.sync(resolved.project,selection:Set(selectedInstanceID.map{[$0]} ?? []),isolated:resolved.visible,showGrid:false,studio:true,preset:draft.surface,assets:assets,renderObjectIDs:resolved.visible,deferSolidConstruction:true)
      stageSyncCount &+= 1;stageInput=input;applyPresentation(draft,forceLighting:true)
      if resolved.project.objects.contains(where:{resolved.visible.contains($0.id) && ($0.meshAsset != nil || $0.cadRepresentation != nil || resolved.project.recipe($0.recipeID)?.solid != nil)}) {
        prepareTask=Task{[weak self] in
          do {
            let solids=try await SolidRecipeGeometry.prepareFullSources(project:resolved.project,objectIDs:resolved.visible)
            guard let self,!Task.isCancelled,self.generation==token,let current=self.draft else{return}
            self.stage.sync(resolved.project,selection:Set(self.selectedInstanceID.map{[$0]} ?? []),isolated:resolved.visible,showGrid:false,studio:true,preset:current.surface,assets:assets,renderObjectIDs:resolved.visible,solidSurfaces:solids,deferSolidConstruction:true)
            self.stageSyncCount &+= 1;self.applyPresentation(current,forceLighting:true)
            try await self.stage.prepareExternalForCapture(project:resolved.project,assets:assets)
            guard !Task.isCancelled,self.generation==token else{return}
            self.prepareTask=nil;self.error=nil;self.stage.renderScene()
          }catch{
            if !Task.isCancelled,let self,self.generation==token {
              // This input has a placeholder, not a successfully prepared
              // stage. Retrying the same scene must perform the load again.
              self.stageInput=nil;self.prepareTask=nil;self.error=error.localizedDescription
            }
          }
        }
      }
    }catch{
      renderOwners=[:]
      self.error=error.localizedDescription
      stage.sync(project,selection:[],isolated:[],showGrid:false,studio:true,preset:draft.surface,assets:assets,renderObjectIDs:[])
      stageSyncCount &+= 1
    }
  }
  private func applyPresentation(_ draft:StudioComposition,forceLighting:Bool=false) {
    var camera=time>0 ? ((try? draft.motion.camera(start:draft.camera,fraction:time)) ?? draft.camera):draft.camera
    if let size=stage.view?.bounds.size,size.width>0,size.height>0 {camera.viewportAspect=size.width/size.height}
    if stage.camera != camera {stage.camera=camera;stage.updateCamera()}
    if forceLighting || appliedLighting != draft.lighting {
      stage.applyShotLighting(draft.lighting,studio:true);appliedLighting=draft.lighting
    }
  }
  func exportDialog(video:Bool) {
    NSApp.keyWindow?.makeFirstResponder(nil)
    guard var draft,!busy else{return}
    if !video {draft.camera=stage.camera}
    let panel=NSSavePanel();panel.title=video ? "Export camera video · MP4 + record":"Export scene image · PNG + record";panel.nameFieldStringValue=draft.name+(video ? ".motion":".render");panel.message="Choose a new output folder. Existing destinations are preserved.";panel.canCreateDirectories=true
    guard panel.runModal() == .OK,let url=panel.url else{return}
    stop();busy=true;progress=0;error=nil
    exportTask=Task{[weak self] in
      guard let self else{return};defer{self.busy=false}
      do{self.lastOutput=try await self.export(draft,to:url,video:video);self.store?.toast(video ? "Camera video exported":"Scene image exported")}catch{self.error=error is CancellationError ? "Export cancelled; no output delivered.":error.localizedDescription}
    }
  }
  func cancelExport(){exportTask?.cancel()}
  /// Freeze the visible working composition for a separate image workflow.
  /// Capturing never saves the scene or adds a camera/draft Undo step.
  func prepareForImageCapture() throws -> StudioComposition {
    guard !busy,!mediaExportActive else {throw FormError.invalid("Finish or cancel the active Studio export first.")}
    finishStageEditing();cancelStagePointer();stop()
    guard var value=draft else {throw FormError.missing("Compose a Studio scene first.")}
    guard value.instances.contains(where:{$0.visible}) else {throw FormError.invalid("Add a visible product or prop to the scene first.")}
    value.camera=stage.camera
    try value.validate()
    return value
  }
  func export(_ scene:StudioComposition,to destination:URL,video:Bool)async throws->URL {
    let scene=(scene==draft ? instanceGesture?.before:nil) ?? scene
    cancelStagePointer()
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

extension StudioCompositionController:TablePresentationInteraction {
  func invalidatePresentationGizmo() {gizmoCache=nil}
  // Commit the old inspector target before native focus loss can rebind its
  // delayed SwiftUI draft to the instance picked by this new pointer gesture.
  func preparePresentationInteraction() {finishStageEditing()}
  var presentationInputEnabled:Bool {!busy && !mediaExportActive && owner==store?.project?.id && draft != nil}
  var presentationGizmo:StudioTransformGizmo? {
    guard gizmoVisible,presentationInputEnabled,let selected,selected.visible,let view=stage.view else{return nil}
    if let cache=gizmoCache,cache.generation==generation,cache.camera==stage.camera,
      cache.viewport==view.bounds.size,cache.selection==selected.id,cache.builds==stage.geometryBuilds {return cache.value}
    var low=SIMD3<Double>(repeating:.infinity),high=SIMD3<Double>(repeating:-.infinity)
    for (id,owner) in renderOwners where owner==selected.id {
      guard let node=stage.logicalNode(for:id),let b=stage.localBounds(for:id) else{continue}
      for x in [b.min.x,b.max.x] {for y in [b.min.y,b.max.y] {for z in [b.min.z,b.max.z] {
        let p=node.convertPosition(.init(x,y,z),to:nil).simd*100
        low=simd_min(low,p);high=simd_max(high,p)
      }}}
    }
    // Yaw is authored about the instance's vertical origin, not the center of
    // an asymmetric mesh. Keep that actual axis at the body's physical height.
    let pivot=SIMD3(selected.positionMM.x,(low.y+high.y)/2,selected.positionMM.z)
    guard low.x.isFinite,let value=StudioTransformGizmo(centerMM:pivot,camera:stage.cameraPayload(),viewport:view.bounds.size) else{return nil}
    gizmoCache=(generation,stage.camera,view.bounds.size,selected.id,stage.geometryBuilds,value)
    return value
  }
  var presentationCursor:NSCursor {
    switch tool {case .orbit:return .openHand;case .move:return .arrow;case .lift:return .resizeUpDown;case .rotate:return .crosshair}
  }
  func beginPresentationInteraction(at point:NSPoint,modifiers:NSEvent.ModifierFlags)->Bool {
    guard !busy,!mediaExportActive,let projectID=store?.project?.id,projectID==owner,
      let scene=draft,let view=stage.view,!modifiers.contains(.shift) else{return false}
    if let gizmo=presentationGizmo,let handle=gizmo.hitTest(point),let instance=selected {
      stop();selectionRequest &+= 1
      var gesture=InstanceGesture(projectID:projectID,sceneID:scene.id,instanceID:instance.id,before:scene,tool:tool,down:point,
        initial:instance.positionMM,yaw:instance.rotationDegrees,planeHeight:gizmo.centerMM.y,planeNormal:.init(0,1,0),
        planeOrigin:.init(gizmo.centerMM.x,gizmo.centerMM.y,gizmo.centerMM.z),planeDown:nil,heightPerPoint:gizmo.millimetersPerPoint,
        groundRight:.init(1,0,0),groundUp:.init(0,0,1))
      gesture.gizmo=gizmo;gesture.handle=handle
      gesture.initialAxis=gizmo.axisParameter(handle,at:point);gesture.lastAngle=gizmo.yawAngle(at:point)
      instanceGesture=gesture
      return true
    }
    guard
      let picked=stage.objectID(at:point),let id=renderOwners[picked],
      let instance=scene.instances.first(where:{$0.id==id && $0.visible}) else{return false}
    guard tool != .orbit else{return false}
    selectedInstanceID=id;selectionRequest &+= 1;sync()
    stop()
    let hit=stage.renderer?.pick(atTopLeft:.init(x:point.x,y:view.bounds.height-point.y),viewport:view.bounds.size)
    let origin=hit.map{Vector3($0.pointMM.x,$0.pointMM.y,$0.pointMM.z)} ?? instance.positionMM
    let height=origin.y
    let basis=CameraNavigation.basis(stage.camera)
    var normal=basis.outward
    normal.y=0
    let length=sqrt(normal.x*normal.x+normal.z*normal.z)
    if length>1e-9 {normal.x/=length;normal.z/=length}
    else {normal = .init(0,0,1)}
    // At the horizon a horizontal ray has no unique ground-plane intersection.
    // Keep Move constrained to XZ using the camera's horizontal screen axes;
    // grabbing an object must never unexpectedly become a camera orbit.
    let plane=tool == .move ? (abs(basis.outward.y)<0.05 ? nil:stage.pointOnTable(point,height:height)):stage.pointOnPlane(point,through:origin,normal:normal)
    var groundUp=Vector3(basis.up.x,0,basis.up.z)
    let upLength=sqrt(groundUp.x*groundUp.x+groundUp.z*groundUp.z)
    if upLength>0.05 {groundUp.x/=upLength;groundUp.z/=upLength}
    else {groundUp = .init(-normal.x,0,-normal.z)}
    let vertical=stage.camera.projection=="orthographic" ? CameraFraming.orthographicFactor:tan(39 * Double.pi/360)
    instanceGesture = .init(projectID:projectID,sceneID:scene.id,instanceID:id,before:scene,tool:tool,down:point,
      initial:instance.positionMM,yaw:instance.rotationDegrees,planeHeight:height,planeNormal:normal,planeOrigin:origin,
      planeDown:plane,heightPerPoint:2*stage.camera.distance*100*vertical/max(1,view.bounds.height),
      groundRight:.init(basis.right.x,0,basis.right.z),groundUp:groundUp)
    return true
  }
  func dragPresentationInteraction(to point:NSPoint,modifiers:NSEvent.ModifierFlags) {
    guard var gesture=instanceGesture else{return}
    guard !busy,!mediaExportActive,store?.project?.id==gesture.projectID,owner==gesture.projectID,
      var value=draft,value.id==gesture.sceneID,
      let index=value.instances.firstIndex(where:{$0.id==gesture.instanceID}),
      point.x.isFinite,point.y.isFinite else{cancelPresentationInteraction();return}
    var position=gesture.initial,yaw=gesture.yaw
    if let gizmo=gesture.gizmo,let handle=gesture.handle {
      if handle == .yaw {
        guard let angle=gizmo.yawAngle(at:point),let previous=gesture.lastAngle else{return}
        var delta=angle-previous
        if delta>Double.pi {delta-=2*Double.pi};if delta < -Double.pi {delta+=2*Double.pi}
        gesture.angularDelta+=delta;gesture.lastAngle=angle
        if abs(gesture.angularDelta)<1e-12 {gesture.angularDelta=0}
        yaw+=gesture.angularDelta*180/Double.pi
        instanceGesture=gesture
      }else {
        guard let initial=gesture.initialAxis,let now=gizmo.axisParameter(handle,at:point),let axis=gizmo.axis(handle) else{return}
        let delta=now-initial
        position.x+=axis.world.x*delta;position.y+=axis.world.y*delta;position.z+=axis.world.z*delta
      }
    }else {switch gesture.tool {
    case .move:
      if let start=gesture.planeDown,let now=stage.pointOnTable(point,height:gesture.planeHeight) {
        position.x+=now.x-start.x;position.z+=now.z-start.z
      }else {
        let dx=Double(point.x-gesture.down.x)*gesture.heightPerPoint,dy=Double(point.y-gesture.down.y)*gesture.heightPerPoint
        position.x+=gesture.groundRight.x*dx+gesture.groundUp.x*dy
        position.z+=gesture.groundRight.z*dx+gesture.groundUp.z*dy
      }
    case .lift:
      if let start=gesture.planeDown,let now=stage.pointOnPlane(point,through:gesture.planeOrigin,normal:gesture.planeNormal) {
        position.y+=now.y-start.y
      }else {position.y+=Double(point.y-gesture.down.y)*gesture.heightPerPoint}
    case .rotate:yaw+=Double(point.x-gesture.down.x)*0.5
    case .orbit:return
    }}
    guard [position.x,position.y,position.z,yaw].allSatisfy({$0.isFinite && abs($0)<=1_000_000}) else{return}
    value.instances[index].positionMM=position;value.instances[index].rotationDegrees=yaw
    guard value != draft else{return}
    draft=value;error=nil;sync()
  }
  func endPresentationInteraction(at point:NSPoint,modifiers:NSEvent.ModifierFlags,dragged:Bool) {
    guard let gesture=instanceGesture else{return}
    // Mouse-up may be the last physical sample, but a click never creates history.
    if dragged {dragPresentationInteraction(to:point,modifiers:modifiers)}
    guard instanceGesture != nil else{return}
    instanceGesture=nil
    guard store?.project?.id==gesture.projectID,draft?.id==gesture.sceneID else{return}
    if draft != gesture.before {
      undoDrafts.append(gesture.before);if undoDrafts.count>80 {undoDrafts.removeFirst()}
      redoDrafts=[];store?.objectWillChange.send()
    }
  }
  func cancelPresentationInteraction() {
    guard let gesture=instanceGesture else{return}
    instanceGesture=nil
    guard draft?.id==gesture.sceneID else{return}
    if draft != gesture.before {draft=gesture.before;error=nil;sync()}
  }
  func presentationKeyDown(_ event:NSEvent)->Bool {
    if event.keyCode==53 {cancelStagePointer();return true}
    guard !event.modifierFlags.contains(.command),!event.modifierFlags.contains(.control) else{return false}
    guard presentationInputEnabled else{return true}
    if event.keyCode==51 || event.keyCode==117 {removeInstance();return true}
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "f":focusSelected()
    case "v":tool = .move
    case "o":tool = .orbit
    case "y":tool = .lift
    case "r":tool = .rotate
    case "1":stage.preset("perspective");cameraEdited()
    case "2":stage.preset("overhead");cameraEdited()
    case "3":stage.preset("front");cameraEdited()
    default:return false
    }
    return true
  }
}

struct StudioCompositionViewport:NSViewRepresentable {
  @ObservedObject var controller:StudioCompositionController
  func makeNSView(context:Context)->TableSceneView {
    let view=TableSceneView(frame:.zero);view.clipsToBounds=true;view.controller=controller.stage;controller.stage.view=view
    view.presentationInteraction=controller
    view.setAccessibilityLabel("Studio composition stage · move, lift or rotate instances; background drag orbits, Shift-drag pans")
    view.onCameraInteraction={[weak controller] in controller?.cameraEdited()}
    view.onObjectPick={[weak controller] id in controller?.selectRenderedInstance(id)}
    return view
  }
  func updateNSView(_ view:TableSceneView,context:Context){}
  static func dismantleNSView(_ view:TableSceneView,coordinator:()){view.cancelPointerInteraction();view.presentationInteraction=nil;view.onCameraInteraction=nil;view.onObjectPick=nil}
}

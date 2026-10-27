import AppKit
import Combine
import FormCore
import FormGraphics
import ImageIO

@MainActor final class StudioShotController:ObservableObject {
  weak var store:StudioStore?
  @Published var editingID:UUID?
  @Published var reviewingID:UUID?
  @Published var referenceAspect:Double?
  @Published var name="Untitled shot" {didSet{if oldValue != name {invalidatePreview()}}}
  @Published var width="3000" {didSet{if oldValue != width {invalidatePreview()}}}
  @Published var height="2000" {didSet{if oldValue != height {invalidatePreview()}}}
  @Published var lighting="classic-v1" {didSet{if oldValue != lighting {invalidatePreview()}}}
  @Published var visibilityMode="project" {didSet{if oldValue != visibilityMode {invalidatePreview()}}}
  @Published private(set) var preview:NSImage?
  @Published private(set) var error:String?
  @Published private(set) var busy=false
  @Published private(set) var lastExport:URL?
  var exportDestination:((StudioShot)->URL?)?
  let renderer=StudioShotRenderer()
  private var projectID:UUID?
  private var loadedDefinition:StudioShot?
  private var previewSourceDigest:String?
  private var draftID=UUID()
  private var generation=0
  private var previewTask:Task<Void,Never>?
  private var cache:[String:NSImage]=[:],order:[String]=[]
  private var cacheShotIDs:[String:UUID]=[:]
  private(set) var staleResults=0,cacheBytes=0
  init(store:StudioStore){self.store=store}
  var shots:[StudioShot] {store?.project?.studioPresentation?.shots ?? []}
  var subjectSummary:String {
    guard let project=store?.project else{return "Open a project."}
    let known=Set(project.objects.filter{!$0.isCanvasWorkspace}.map(\.id))
    if visibilityMode=="selection" {return "\(known.intersection(store?.engine.selection ?? []).count) exact selected objects. Include applied details."}
    if visibilityMode=="saved",let id=editingID,let shot=shots.first(where:{$0.id==id}) {return "\(Set(shot.visibility.objectIDs).intersection(known).count) of \(shot.visibility.objectIDs.count) saved objects present."}
    return "\(known.count) current physical objects."
  }
  var diagnostics:[String:Any] {["render_count":renderer.renders,"geometry_builds":renderer.geometryBuilds,"maximum_render_ms":renderer.maximumMilliseconds,"process_peak_rss_bytes":renderer.maximumProcessRSSBytes,"last_render_pixel_bytes":renderer.lastPixelBytes,"preview_cache_bytes":cacheBytes,"preview_cache_limit_bytes":32*1024*1024,"preview_cache_count":cache.count,"stale_results":staleResults,"pixel_cap_is_total_memory_cap":false]}
  func reconcile() {
    guard let id=store?.project?.id else {reset();return}
    if projectID != id {reset();projectID=id}
    let valid=Set(shots.map(\.id)+[draftID])
    for key in order where cacheShotIDs[key].map({!valid.contains($0)}) ?? true {cache.removeValue(forKey:key);cacheShotIDs.removeValue(forKey:key)}
    order.removeAll{cache[$0]==nil};recountCache()
    if preview != nil,previewSourceDigest != (try? store?.project?.studioDesignDigest()) {invalidatePreview()}
    if let id=reviewingID,!shots.contains(where:{$0.id==id}) {reviewingID=nil;referenceAspect=nil;invalidatePreview()}
    if let id=editingID {
      guard let saved=shots.first(where:{$0.id==id}) else {editingID=nil;loadedDefinition=nil;invalidatePreview();return}
      if let old=loadedDefinition,old.id==id,old != saved {
        // A field editor can contain newer text than its SwiftUI binding. Wait
        // for editing to end rather than replacing or committing that input.
        if NSApp.windows.contains(where:{$0.isVisible && ($0.firstResponder as? NSTextView)?.isFieldEditor == true}) {return}
        // Document Undo updates clean displayed options. Independent unsaved
        // fields remain drafts; metadata changes never recall or fit a camera.
        if name==old.name {name=saved.name}
        if width==String(old.pixels.width) {width=String(saved.pixels.width)}
        if height==String(old.pixels.height) {height=String(saved.pixels.height)}
        if lighting==old.lighting {lighting=saved.lighting}
        if visibilityMode=="saved" || (visibilityMode=="project" && old.visibility.mode == .project) {visibilityMode=saved.visibility.mode == .project ? "project":"saved"}
        if store?.studioPreset==old.surface {store?.studioPreset=saved.surface}
      }
      loadedDefinition=saved
    }
  }
  private func selectDefinition(_ shot:StudioShot) {
    editingID=shot.id;loadedDefinition=shot
    name=shot.name;width=String(shot.pixels.width);height=String(shot.pixels.height)
    lighting=shot.lighting;visibilityMode=shot.visibility.mode == .project ? "project":"saved"
  }
  func reset(){generation+=1;previewTask?.cancel();previewTask=nil;editingID=nil;loadedDefinition=nil;reviewingID=nil;referenceAspect=nil;preview=nil;cache=[:];order=[];cacheShotIDs=[:];cacheBytes=0;busy=false;renderer.clear();draftID=UUID();projectID=nil;lastExport=nil;error=nil;name="Untitled shot";width="3000";height="2000";lighting="classic-v1";visibilityMode="project"}
  func invalidatePreview(){generation+=1;previewTask?.cancel();preview=nil;previewSourceDigest=nil;busy=false}
  func leaveReview(){generation+=1;previewTask?.cancel();editingID=nil;loadedDefinition=nil;reviewingID=nil;referenceAspect=nil;preview=nil;busy=false}
  func pixels()throws->StudioPixels {
    guard let w=Int(width),let h=Int(height) else {throw FormError.invalid("Enter whole pixel dimensions.")}
    let p=StudioPixels(width:w,height:h);try p.validate();return p
  }
  func runtimePreflight(_ project:Project,_ shot:StudioShot)throws {
    let ids=try shot.visibility.resolved(in:project)
    let runtime=store?.cloth.preview
    if let source=runtime?.source,source.projectID==project.id,ids.contains(source.objectID),let frame=runtime?.frame,
      runtime?.isRunning==true || runtime?.isStepping==true || frame.diagnostics.completedFrames>0 || (frame.diagnostics.preparation?.passes ?? 0)>0 {
      throw FormError.invalid("This shot includes unpersisted cloth motion or preparation. Saved shots render committed source only; reset the existing cloth preview explicitly before capture or export. No simulation was changed.")
    }
  }
  func draft()throws->StudioShot {
    guard let store else{throw FormError.missing("Open a project first.")}
    store.scene?.updateCamera()
    guard let project=store.project else{throw FormError.missing("Open a project first.")}
    let aspect=referenceAspect ?? project.camera.viewportAspect
    guard let aspect else{throw FormError.invalid("Open a nonzero Table viewport before capturing a shot.")}
    var s=StudioShot(name:name,camera:project.camera,referenceAspect:aspect);s.id=draftID
    if let id=editingID,let saved=shots.first(where:{$0.id==id}) {s.id=id;s.revision=saved.revision;s.visibility=saved.visibility}
    if visibilityMode == "project" {s.visibility = .init()}
    else if visibilityMode == "selection" {s.visibility=StudioVisibility(mode:.objects,objectIDs:store.engine.selection.filter{id in project.objects.contains{$0.id==id && !$0.isCanvasWorkspace}}.sorted{$0.uuidString<$1.uuidString})}
    s.lighting=lighting;s.surface=store.studioPreset;s.pixels=try pixels();try s.validate();try runtimePreflight(project,s);return s
  }
  func recall(_ id:UUID)throws {
    guard let store,let project=store.project,let shot=shots.first(where:{$0.id==id}) else{throw FormError.missing("Saved shot not found.")}
    reconcile();leaveReview()
    // Choosing a definition remains possible when Recall fails. Its actions can
    // repair/delete missing subjects without pretending another view is the shot.
    selectDefinition(shot)
    try runtimePreflight(project,shot)
    store.showSurface(.studio);store.synchronizeScene()
    store.scene?.view?.cancelPointerInteraction();store.engine.project?.camera=shot.camera
    store.scene?.camera=shot.camera;store.scene?.updateCamera()
    reviewingID=shot.id;referenceAspect=shot.referenceAspect
    store.studioPreset=shot.surface;store.isolated=shot.visibility.mode == .objects ? Set(shot.visibility.objectIDs):[]
    store.cameraChanged();store.changed(save:false);requestPreview()
  }
  func save(capture:Bool)throws {
    NSApp.keyWindow?.makeFirstResponder(nil);reconcile();let shot=try draft()
    var args:[String:Any]=["view":"studio","studio_command":capture ? "capture":"update","name":shot.name,"camera":try jsonObject(shot.camera),"reference_aspect":shot.referenceAspect,"lighting":shot.lighting,"surface":shot.surface,"visibility":try jsonObject(shot.visibility),"width":shot.pixels.width,"height":shot.pixels.height]
    if !capture {guard let id=editingID else{throw FormError.invalid("Select a saved shot before updating it.")};args["shot_id"]=id.uuidString}
    let result=try store!.engine.call("form_set_view",arguments:args,source:"Studio")
    if let value=result as? [String:Any],let saved=try? StudioShotCommands.shot(in:store!.project!,id:value["id"]) {selectDefinition(saved)}
    store!.metadataRecordsChanged();error=nil
  }
  func rename(_ id:UUID)throws {
    NSApp.keyWindow?.makeFirstResponder(nil)
    _ = try store!.engine.call("form_set_view",arguments:["view":"studio","studio_command":"rename","shot_id":id.uuidString,"name":name])
    if let saved=store?.project?.studioPresentation?.shots.first(where:{$0.id==id}) {name=saved.name;loadedDefinition=saved}
    store!.metadataRecordsChanged()
  }
  func delete(_ id:UUID)throws {_ = try store!.engine.call("form_set_view",arguments:["view":"studio","studio_command":"delete","shot_id":id.uuidString]);store!.metadataRecordsChanged();reconcile()}
  func perform(_ work:()throws->Void){do{try work();error=nil}catch{self.error=error.localizedDescription}}
  func requestPreview() {
    reconcile();generation+=1;let token=generation;previewTask?.cancel()
    do {
      let shot=try draft(),project=store!.project!,assets=store!.repository.url(for:project.id).appendingPathComponent("Assets")
      let dependencies=try StudioShotRenderer.resources(project:project,assets:assets)
      let key=try project.studioDesignDigest()+String(decoding:JSONEncoder.form.encode(shot),as:UTF8.self)+StudioRenderFolder.hash(JSONSerialization.data(withJSONObject:dependencies,options:.sortedKeys))
      if let cached=cache[key] {preview=cached;previewSourceDigest=try project.studioDesignDigest();error=nil;busy=false;return}
      busy=true;error=nil
      previewTask=Task { [weak self] in
        await Task.yield();guard let self else{return}
        guard !Task.isCancelled,self.generation==token,self.store?.project?.id==project.id,(try? self.store?.project?.studioDesignDigest()) == (try? project.studioDesignDigest()) else{self.staleResults+=1;if self.generation==token {self.busy=false};return}
        do {
          let image=try await self.renderer.render(project:project,shot:shot,assets:assets,preview:true)
          await Task.yield()
          guard !Task.isCancelled,self.generation==token,self.store?.project?.id==project.id,try self.store?.project?.studioDesignDigest()==project.studioDesignDigest() else{self.staleResults+=1;if self.generation==token {self.busy=false};return}
          self.preview=image;self.previewSourceDigest=try project.studioDesignDigest();self.busy=false;self.put(image,key:key,shotID:shot.id)
        } catch {if self.generation==token{self.error=error.localizedDescription;self.busy=false}}
      }
    }catch{self.error=error.localizedDescription;busy=false}
  }
  private func recountCache() {cacheBytes=cache.values.reduce(0){sum,img in sum+(img.representations.map{$0.pixelsWide*$0.pixelsHigh*4}.max() ?? 0)}}
  private func put(_ image:NSImage,key:String,shotID:UUID) {
    cache[key]=image;cacheShotIDs[key]=shotID;order.removeAll{$0==key};order.append(key);recountCache()
    while order.count>8 || cacheBytes>32*1024*1024 {let key=order.removeFirst();cache.removeValue(forKey:key);cacheShotIDs.removeValue(forKey:key);recountCache()}
  }
  func export(_ shot:StudioShot,to url:URL)async throws->URL {
    guard let store,let project=store.project else{throw FormError.missing("Open a project first.")};try shot.validate();try runtimePreflight(project,shot)
    guard url.pathExtension=="render",FileManager.default.fileExists(atPath:url.deletingLastPathComponent().path),!FileManager.default.fileExists(atPath:url.path) else{throw FormError.invalid("Choose a new .render folder in an existing parent. Existing destinations are never overwritten.")}
    let assets=store.repository.url(for:project.id).appendingPathComponent("Assets"),resources=try StudioShotRenderer.resources(project:project,assets:assets)
    let rendered=try await renderer.renderResult(project:project,shot:shot,assets:assets,preview:false)
    let data=try StudioPNG.encode(rendered.image,designDigest:project.studioDesignDigest())
    let record:[String:Any]=["record_version":1,"project_id":project.id.uuidString,"shot_id":shot.id.uuidString,"shot_revision":shot.revision,"design_sha256":try project.studioDesignDigest(),"shot":try jsonObject(shot),"included_object_ids":try shot.visibility.resolved(in:project).map(\.uuidString).sorted(),"width":shot.pixels.width,"height":shot.pixels.height,"effective_vertical_fov_degrees":shot.outputFieldOfView,"effective_orthographic_scale":shot.camera.distance*CameraFraming.orthographicFactor*shot.expansion,"resources":resources,"framing_warnings":rendered.framingWarnings,"near_clip":0.01,"far_clip":1500,"application":"LAB","application_version":Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development","renderer":"RealityKit / Metal / LAB Studio v2","presentation_renderer_version":2,"os_version":ProcessInfo.processInfo.operatingSystemVersionString,"exported_at":ISO8601DateFormatter().string(from:Date()),"png_sha256":StudioRenderFolder.hash(data),"source_archived":false,"physical_size_or_fit_claim":false]
    let result=try StudioRenderFolder.write(png:data,record:record,to:url);lastExport=result;return result
  }
  func exportDialog(){
    do {
      NSApp.keyWindow?.makeFirstResponder(nil);let shot=try draft()
      let destination:URL?
      if let exportDestination {destination=exportDestination(shot)}
      else {
        let panel=NSSavePanel();panel.nameFieldStringValue=shot.name+".render";panel.title="Export shot folder (PNG + record)";panel.message="Choose a new .render folder. It contains the named PNG and its source record; existing folders are never overwritten.";panel.canCreateDirectories=true
        destination=panel.runModal() == .OK ? panel.url:nil
      }
      if let destination {Task {do{let image=try await export(shot,to:destination);store?.toast("Shot PNG: \(image.lastPathComponent)")}catch{self.error=error.localizedDescription}}}
    } catch {self.error=error.localizedDescription}
  }
}

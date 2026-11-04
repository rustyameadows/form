import AppKit
import CryptoKit
import FormCore
import LabRendering

@MainActor final class CyclesAppCoordinator {
  weak var store:StudioStore?
  let preparer=StudioShotRenderer()
  private struct Job {
    let id:UUID,projectID:UUID
    var state="preparing",phase="Preparing scene",sample=0,total=0
    var helperID:UUID?,output:URL?,error:String?,task:Task<Void,Never>?
    var device:String?,fallbackReason:String?
  }
  private var jobs:[UUID:Job]=[:]
  init(store:StudioStore){self.store=store}
  func call(_ args:[String:Any])async throws->Any {
    let allowed:Set<String>=["command","project_id","target","shot_id","scene_id","settings","pixels","path","job_id"]
    guard Set(args.keys).isSubset(of:allowed) else{throw FormError.invalid("Unknown Cycles render argument.")}
    let command=args["command"] as? String ?? "capabilities"
    if command=="capabilities" {
      let c=try await LabCyclesRuntime.service.capabilities()
      return ["engine":c.engineVersion,"devices":c.devices,"protocol_version":c.protocolVersion,
        "targets":["table","shot","scene"],"formats":["png","exr"],"bundled":true] as [String:Any]
    }
    if ["status","result","cancel"].contains(command) {
      guard let raw=args["job_id"] as? String,let id=UUID(uuidString:raw),var job=jobs[id] else{throw FormError.missing("Render job not found.")}
      if command=="cancel",["preparing","rendering"].contains(job.state) {
        job.task?.cancel();job.state="cancelled";job.phase="Cancelled";jobs[id]=job
        if let helperID=job.helperID {await LabCyclesRuntime.service.cancel(jobID:helperID)}
      }
      if command=="result",job.state != "completed" {throw FormError.invalid("The render has not completed. Inspect its status first.")}
      return report(id)
    }
    guard ["configure","start"].contains(command),let store,let project=store.project,
      args["project_id"] as? String==project.id.uuidString else{throw FormError.invalid("Supply the active project_id and a supported render command.")}
    let target=args["target"] as? String ?? ""
    guard ["table","shot","scene"].contains(target),!(args["shot_id"] != nil && args["scene_id"] != nil),
      target=="shot" || args["shot_id"]==nil,target=="scene" || args["scene_id"]==nil else{throw FormError.invalid("Choose exactly one explicit Table, saved shot or saved scene target.")}
    let shot:StudioShot?,scene:StudioComposition?
    if target=="shot" {shot=try StudioShotCommands.shot(in:project,id:args["shot_id"])} else{shot=nil}
    if target=="scene" {
      guard let id=(args["scene_id"] as? String).flatMap(UUID.init(uuidString:)),let value=project.studioPresentation?.scenes?.first(where:{$0.id==id}) else{throw FormError.missing("Choose a saved Studio scene.")};scene=value
    }else{scene=nil}
    var settings=shot?.renderSettings ?? scene?.renderSettings ?? project.renderSettings ?? CyclesRenderSettings()
    if let patch=args["settings"] {
      try CyclesRenderSettings.validateFields(patch)
      guard let patch=patch as? [String:Any],var fields=try jsonObject(settings) as? [String:Any] else{throw FormError.invalid("Render settings must be an object.")}
      fields.merge(patch){_,new in new};settings=try JSONDecoder.form.decode(CyclesRenderSettings.self,from:JSONSerialization.data(withJSONObject:fields))
    }
    try settings.validate()
    if command=="configure" {
      guard args["settings"] != nil else{throw FormError.invalid("Supply render settings to configure.")}
      try store.engine.edit("Changed rendering settings",source:"Codex") {value in
        if target=="table" {value.renderSettings=settings}
        else if let shot,let i=value.studioPresentation?.shots.firstIndex(where:{$0.id==shot.id}) {value.studioPresentation?.shots[i].renderSettings=settings;value.studioPresentation?.shots[i].revision+=1}
        else if let scene,let i=value.studioPresentation?.scenes?.firstIndex(where:{$0.id==scene.id}) {value.studioPresentation?.scenes?[i].renderSettings=settings;value.studioPresentation?.scenes?[i].revision+=1}
      }
      store.changed();try store.engine.flush();return try jsonObject(settings)
    }
    guard !jobs.values.contains(where:{["preparing","rendering"].contains($0.state)}) else{throw FormError.invalid("Finish or cancel the active final render before starting another.")}
    let frozenProject:Project
    var frozenShot:StudioShot
    if let scene {let resolved=try scene.resolved(in:project);frozenProject=resolved.project;frozenShot=scene.shot();frozenShot.visibility = .init(mode:.objects,objectIDs:resolved.visible.sorted{$0.uuidString<$1.uuidString})}
    else {frozenProject=project;frozenShot=shot ?? StudioShot(name:"Table",camera:store.scene?.camera ?? project.camera,referenceAspect:store.scene?.camera.viewportAspect ?? 1.5)
      if target=="table",!store.isolated.isEmpty {frozenShot.visibility = .init(mode:.objects,objectIDs:Array(store.isolated))}}
    if let raw=args["pixels"] {frozenShot.pixels=try JSONDecoder.form.decode(StudioPixels.self,from:JSONSerialization.data(withJSONObject:raw))}
    try frozenShot.validate()
    if let scene {try runtimePreflight(scene:scene,project:project)}
    else if target != "table" {try store.studioShots.runtimePreflight(project,frozenShot)}
    let id=UUID(),exports=store.repository.url(for:project.id).appendingPathComponent("Exports",isDirectory:true)
    try FileManager.default.createDirectory(at:exports,withIntermediateDirectories:true)
    if let raw=args["path"] {guard let path=raw as? String,path.hasPrefix("/") else{throw FormError.invalid("Render output path must be absolute.")}}
    let destination=(args["path"] as? String).map{URL(fileURLWithPath:$0)} ?? exports.appendingPathComponent("Cycles-"+id.uuidString+".render")
    try validateDestination(destination,projectID:project.id)
    let sourceDigest=try project.studioDesignDigest(),assets=store.repository.url(for:project.id).appendingPathComponent("Assets")
    let tableController=target=="table" ? store.scene:nil
    if target=="table",tableController==nil {throw FormError.invalid("Open the Table view before rendering its displayed scene.")}
    jobs[id] = .init(id:id,projectID:project.id)
    let targetCurrent:()->Bool = { [weak store] in
      guard let current=store?.project,current.id==project.id else{return false}
      if let shot {return current.studioPresentation?.shots.first{$0.id==shot.id}==shot}
      if let scene {return current.studioPresentation?.scenes?.first{$0.id==scene.id}==scene}
      return true
    }
    jobs[id]?.task=Task { [weak self] in
      guard let self else{return}
      do {
        let output=try await self.render(project:frozenProject,shot:frozenShot,assets:assets,settings:settings,to:destination,
          sourceProjectID:project.id,sourceDigest:sourceDigest,jobID:id,liveTable:tableController,isTargetCurrent:targetCurrent)
        self.jobs[id]?.output=output;self.jobs[id]?.state="completed";self.jobs[id]?.phase="Complete"
      }catch {self.jobs[id]?.state=(Task.isCancelled || error is CancellationError) ? "cancelled":"failed";self.jobs[id]?.error=error.localizedDescription}
    }
    if jobs.count>32 {for key in jobs.keys.sorted(by:{$0.uuidString<$1.uuidString}) where jobs.count>32 && !["preparing","rendering"].contains(jobs[key]!.state) {jobs.removeValue(forKey:key)}}
    return report(id)
  }
  private func report(_ id:UUID)->[String:Any] {
    guard let job=jobs[id] else{return [:]}
    return ["job_id":id.uuidString,"project_id":job.projectID.uuidString,"state":job.state,"phase":job.phase,
      "sample":job.sample,"samples":job.total,"device":job.device as Any? ?? NSNull(),"fallback_reason":job.fallbackReason as Any? ?? NSNull(),
      "path":job.output?.path as Any? ?? NSNull(),"png":job.output?.path as Any? ?? NSNull(),
      "exr":job.output?.deletingPathExtension().appendingPathExtension("exr").path as Any? ?? NSNull(),
      "record":job.output?.deletingLastPathComponent().appendingPathComponent("render.json").path as Any? ?? NSNull(),"error":job.error as Any? ?? NSNull()]
  }
  func validateDestination(_ url:URL,projectID:UUID)throws {
    guard let store,url.isFileURL,url.pathExtension=="render",!FileManager.default.fileExists(atPath:url.path) else{throw FormError.invalid("Choose a new .render folder for PNG, EXR and provenance.")}
    let root=store.repository.root.standardizedFileURL.resolvingSymlinksInPath().path,path=url.standardizedFileURL.resolvingSymlinksInPath().path
    let exports=store.repository.url(for:projectID).appendingPathComponent("Exports").standardizedFileURL.resolvingSymlinksInPath().path
    guard (!path.hasPrefix(root+"/") || path.hasPrefix(exports+"/")),FileManager.default.fileExists(atPath:url.deletingLastPathComponent().path) else{throw FormError.invalid("Render into this project's Exports folder or an existing independent output directory.")}
  }
  func renderScene(_ scene:StudioComposition,to destination:URL,progress:@escaping(Double)->Void)async throws->URL {
    guard let store,let project=store.project else{throw FormError.missing("Open a project.")}
    try runtimePreflight(scene:scene,project:project)
    try validateDestination(destination,projectID:project.id)
    let resolved=try scene.resolved(in:project)
    var shot=scene.shot();shot.visibility = .init(mode:.objects,objectIDs:Array(resolved.visible))
    let draft=store.studioComposition.draft?.id==scene.id,baseline=project.studioPresentation?.scenes?.first{$0.id==scene.id}
    let targetCurrent:()->Bool = { [weak store] in
      guard let store,store.project?.id==project.id else{return false}
      return draft ? store.studioComposition.draft==scene:store.project?.studioPresentation?.scenes?.first{$0.id==scene.id}==baseline
    }
    return try await render(project:resolved.project,shot:shot,assets:store.repository.url(for:project.id).appendingPathComponent("Assets"),
      settings:scene.renderSettings ?? .init(),to:destination,sourceProjectID:project.id,sourceDigest:project.studioDesignDigest(),isTargetCurrent:targetCurrent,progress:progress)
  }
  func renderShot(_ shot:StudioShot,to destination:URL,progress:@escaping(Double)->Void={_ in})async throws->URL {
    guard let store,let project=store.project else{throw FormError.missing("Open a project.")}
    try store.studioShots.runtimePreflight(project,shot)
    try validateDestination(destination,projectID:project.id)
    let baseline=project.studioPresentation?.shots.first{$0.id==shot.id}
    let targetCurrent:()->Bool = { [weak store] in
      guard let current=store?.project,current.id==project.id else{return false}
      return current.studioPresentation?.shots.first{$0.id==shot.id}==baseline
    }
    return try await render(project:project,shot:shot,assets:store.repository.url(for:project.id).appendingPathComponent("Assets"),
      settings:shot.renderSettings ?? .init(),to:destination,sourceProjectID:project.id,sourceDigest:project.studioDesignDigest(),isTargetCurrent:targetCurrent,progress:progress)
  }
  /// Scene instances expand attachment families into transient render IDs. Check
  /// the corresponding original IDs before rendering committed cloth sources.
  func runtimePreflight(scene:StudioComposition,project:Project)throws {
    guard let store else{throw FormError.missing("Open a project.")}
    var ids=Set(scene.instances.filter(\.visible).compactMap(\.sourceObjectID))
    for _ in 0..<8 {
      let next=Set(project.objects.compactMap{object->UUID? in
        let parent=object.textile?.attachment?.garmentID ?? object.clothAttachment?.surfaceObjectID ?? object.patternAssemblyAttachment?.surfaceObjectID
        return parent.map{ids.contains($0)} == true ? object.id:nil
      })
      let added=next.subtracting(ids);if added.isEmpty {break};ids.formUnion(added)
    }
    guard !ids.isEmpty else{return}
    var shot=scene.shot();shot.visibility = .init(mode:.objects,objectIDs:Array(ids))
    try store.studioShots.runtimePreflight(project,shot)
  }
  private func render(project:Project,shot:StudioShot,assets:URL,settings:CyclesRenderSettings,to destination:URL,
    sourceProjectID:UUID,sourceDigest:String,jobID:UUID?=nil,liveTable:TableSceneController?=nil,isTargetCurrent:@escaping()->Bool={true},progress:@escaping(Double)->Void={_ in})async throws->URL {
    try Task.checkCancellation()
    let resources=try StudioShotRenderer.resources(project:project,assets:assets)
    func checkCurrent(checkResources:Bool=false)throws {
      try Task.checkCancellation()
      guard self.store?.project?.id==sourceProjectID,(try self.store?.project?.studioDesignDigest())==sourceDigest else{throw FormError.invalid("The source project changed during rendering. Render its current revision again.")}
      guard isTargetCurrent() else{throw FormError.invalid("The saved shot or Studio composition changed during rendering. Render its current revision again.")}
      if checkResources,try StudioShotRenderer.resources(project:project,assets:assets) != resources {throw FormError.invalid("A source image, material texture or font changed during rendering. No output was delivered.")}
    }
    try checkCurrent()
    let snapshot:SceneSnapshot
    if let liveTable {
      snapshot=try await preparer.cyclesTableSnapshot(project:project,shot:shot,assets:assets,settings:settings,live:liveTable,resources:resources)
    } else {
      snapshot=try await preparer.cyclesSnapshot(project:project,shot:shot,assets:assets,settings:settings,resources:resources)
    }
    try checkCurrent(checkResources:true)
    let helper=try await LabCyclesRuntime.service.capabilities().helperURL
    let runtimeLocations=CyclesExportProvenance.Locations(executable:Bundle.main.executableURL ?? URL(fileURLWithPath:CommandLine.arguments[0]),helper:helper)
    let runtimeProvenance=try await CyclesExportProvenance.capture(runtimeLocations)
    try checkCurrent(checkResources:true)
    let job=try await LabCyclesRuntime.service.start(snapshot:snapshot,settings:LabCyclesRuntime.configuration(settings,pixels:shot.pixels,preview:false),outputDirectory:LabCyclesRuntime.cacheURL)
    if let id=jobID {jobs[id]?.helperID=job.id;jobs[id]?.state="rendering"}
    return try await withTaskCancellationHandler(operation:{
      do {
        for try await event in job.events {
          try checkCurrent()
          switch event {
          case .progress(let value):
            progress(value.fraction)
            if let id=jobID {jobs[id]?.phase=value.phase;jobs[id]?.sample=value.sample;jobs[id]?.total=value.totalSamples;jobs[id]?.device=value.device;jobs[id]?.fallbackReason=value.fallbackReason}
          case .frame:break
          case .completed(let value):
            try checkCurrent(checkResources:true)
            let currentRuntime=try await CyclesExportProvenance.capture(runtimeLocations)
            try runtimeProvenance.requireUnchanged(currentRuntime)
            try checkCurrent(checkResources:true)
            if let id=jobID {jobs[id]?.device=value.device;jobs[id]?.fallbackReason=value.fallbackReason;jobs[id]?.sample=value.samples;jobs[id]?.total=value.samples}
            let png=try Data(contentsOf:value.pngURL),exr=try Data(contentsOf:value.exrURL)
            let record:[String:Any]=["version":1,"renderer":"Cycles","engine_revision":value.engineVersion,"device":value.device,
              "fallback_reason":value.fallbackReason as Any? ?? NSNull(),"project_id":sourceProjectID.uuidString,
              "source_revision":sourceDigest,"snapshot_revision":snapshot.revision,"source_kind":liveTable == nil ? "saved":"table_runtime_snapshot","shot":try jsonObject(shot),
              "settings":try jsonObject(settings),"width":value.width,"height":value.height,"samples":value.samples,
              "elapsed_seconds":value.elapsedSeconds,"display_transform":"LAB-sRGB-v1","exr_encoding":"scene-linear sRGB, premultiplied alpha",
              "denoiser":value.denoiser,"preparation_seconds":value.preparationSeconds as Any? ?? NSNull(),
              "render_seconds":value.renderSeconds as Any? ?? NSNull(),"denoise_seconds":value.denoiseSeconds as Any? ?? NSNull(),
              "resources":resources,"runtime_provenance":try runtimeProvenance.record(engineRevision:value.engineVersion),
              "png_sha256":StudioRenderFolder.hash(png),"exr_sha256":StudioRenderFolder.hash(exr)]
            let output=try StudioRenderFolder.write(png:png,record:record,to:destination,exr:exr,hook:{phase in
              if phase == .beforeRename {try checkCurrent(checkResources:true)}
            })
            try? FileManager.default.removeItem(at:job.directory)
            return output
          }
        }
        throw FormError.invalid("Cycles ended without a completed image.")
      }catch {
        await LabCyclesRuntime.service.cancel(jobID:job.id)
        if await LabCyclesRuntime.service.status(jobID:job.id)?.state == .completed {try? FileManager.default.removeItem(at:job.directory)}
        throw error
      }
    },onCancel:{Task{await LabCyclesRuntime.service.cancel(jobID:job.id)}})
  }
}

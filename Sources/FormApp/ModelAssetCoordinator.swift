import AppKit
import FormCore
import CoreFoundation
import FormMeshAssets
import LabRendering
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class ModelImportReview:ObservableObject,Identifiable {
  let id=UUID(),url:URL,projectID:UUID,projectEpoch:UUID
  let sourceProject:Project
  @Published var name:String
  @Published var sourceUnit:MeshSourceUnit?
  @Published var state="choose_units"
  @Published var error:String?
  @Published var reference:MeshAssetReference?
  var document:MeshAssetDocument?
  var normalized:Data?
  var preparedScene:MeshAssetPreparedScene?
  @Published var renderWarnings:[String]=[]
  var objectID:UUID?
  var task:Task<Void,Never>?
  var worker:Task<ModelAssetCoordinator.PreparedAsset,Error>?
  var publicationWorker:Task<ModelAssetCoordinator.PublishedFiles,Error>?
  var generation=UUID()
  init(url:URL,project:Project,epoch:UUID,sourceUnit:MeshSourceUnit?,name:String?) {
    self.url=url;projectID=project.id;projectEpoch=epoch;sourceProject=ModelAssetCoordinator.sourceSnapshot(project)
    self.sourceUnit=sourceUnit;self.name=name ?? url.deletingPathExtension().lastPathComponent
  }
}

/// Native review and MCP jobs use the same prepared asset and one guarded publication operation.
@MainActor final class ModelAssetCoordinator:ObservableObject {
  struct PublishedFiles:Sendable {var urls:[URL]}
  struct PreparedAsset:Sendable {var document:MeshAssetDocument,normalized:Data,reference:MeshAssetReference,scene:MeshAssetPreparedScene,cost:Int}
  weak var store:StudioStore?
  @Published var review:ModelImportReview?
  @Published private(set) var loading=Set<String>()
  @Published private(set) var failures:[String:String]=[:]
  private var jobs:[UUID:ModelImportReview]=[:]
  private var cache:[String:(document:MeshAssetDocument,scene:MeshAssetPreparedScene,cost:Int)]=[:],order:[String]=[]
  private var loads:[String:Task<Void,Never>]=[:]
  private var loadWorkers:[String:Task<PreparedAsset,Error>]=[:]
  private var appearances:[String:MeshAssetSceneAppearance]=[:],appearanceOrder:[String]=[]
  private var appearanceWorkers:[String:Task<MeshAssetSceneAppearance,Error>]=[:]
  private var appearanceTasks:[String:Task<Void,Never>]=[:],pendingAppearance:[UUID:String]=[:],lastAppearance:[UUID:String]=[:]
  private var appearanceBytes=0
  private var generation=UUID(),cacheBytes=0
  nonisolated static let cacheLimitBytes=256*1024*1024
  nonisolated static let normalizedByteLimit=768*1024*1024
  nonisolated static let preparedImportLimitBytes=512*1024*1024
  /// Tests may suspend publication after parsing without touching the ordinary library.
  var preparationCheckpoint:(()async->Void)?
  var publicationCheckpoint:(()async->Void)?
  init(store:StudioStore) {self.store=store}
  static func sourceSnapshot(_ project:Project)->Project {var p=project;p.camera = .init();return p}
  private func contextMatches(_ review:ModelImportReview)->Bool {
    guard let store,let project=store.project else{return false}
    return project.id==review.projectID && store.artworkTransferProjectEpoch==review.projectEpoch && Self.sourceSnapshot(project)==review.sourceProject
  }
  func reset() {
    generation=UUID()
    for job in jobs.values {job.generation=UUID();job.task?.cancel();job.worker?.cancel();job.publicationWorker?.cancel();job.state="cancelled"}
    for task in loads.values {task.cancel()};for worker in loadWorkers.values {worker.cancel()};for task in appearanceTasks.values {task.cancel()};for worker in appearanceWorkers.values {worker.cancel()}
    jobs=[:];review=nil;cache=[:];order=[];loads=[:];loadWorkers=[:];loading=[];failures=[:];cacheBytes=0;appearances=[:];appearanceOrder=[];appearanceWorkers=[:];appearanceTasks=[:];pendingAppearance=[:];lastAppearance=[:];appearanceBytes=0
  }
  func openImport() {
    guard store?.project != nil else{store?.error="Open or create a project before importing a 3D model.";return}
    let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
    panel.allowedContentTypes=["glb","gltf","stl"].compactMap{UTType(filenameExtension:$0)}
    panel.title="Import 3D model";panel.message="GLB/glTF preserve static mesh parts and materials. STL requires an explicit unit choice."
    if panel.runModal() == .OK,let url=panel.url {do{_ = try beginImport(url:url,sourceUnit:nil,name:nil,present:true)}catch{store?.error=error.localizedDescription}}
  }
  @discardableResult func beginImport(url:URL,sourceUnit:MeshSourceUnit?,name:String?,present:Bool) throws -> ModelImportReview {
      guard let store,let project=store.project else{throw FormError.missing("Open a project before importing 3D assets.")}
      guard url.isFileURL,["glb","gltf","stl"].contains(url.pathExtension.lowercased()) else{throw FormError.invalid("Choose a GLB, glTF or STL file.")}
      if let name {guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.utf8.count<=256 else{throw FormError.invalid("Model names need 1–256 UTF-8 bytes.")}}
      guard !jobs.values.contains(where:{["preparing","publishing"].contains($0.state)}) else{throw FormError.invalid("Wait for or cancel the active model read before starting another.")}
      if present,let current=review {cancel(current)}
      while jobs.count>=8,let old=jobs.values.first(where:{["failed","cancelled","committed"].contains($0.state)}) {jobs.removeValue(forKey:old.id)}
      guard jobs.count<8 else{throw FormError.invalid("Finish or cancel an existing model import before starting another.")}
      let value=ModelImportReview(url:url,project:project,epoch:store.artworkTransferProjectEpoch,sourceUnit:sourceUnit,name:name)
      jobs[value.id]=value;if present {review=value}
      if url.pathExtension.lowercased() != "stl" || sourceUnit != nil {prepare(value)}
      return value
  }
  func prepare(_ job:ModelImportReview) {
    guard contextMatches(job) else{job.error="The project's source changed. Start a fresh import review.";job.state="failed";return}
    if job.url.pathExtension.lowercased()=="stl",job.sourceUnit==nil {job.error="Choose STL source units before reading geometry.";job.state="choose_units";return}
    job.worker?.cancel();job.task?.cancel();let token=UUID();job.generation=token;job.state="preparing";job.error=nil;job.document=nil;job.reference=nil;job.normalized=nil;job.preparedScene=nil;job.renderWarnings=[]
    let url=job.url,unit=job.sourceUnit,name=job.name
    let worker=Task.detached(priority:.userInitiated) {try Self.prepareAsset(url:url,unit:unit,name:name)}
    job.worker=worker
    job.task=Task { [weak self,weak job] in
      guard let self,let job else{return}
      do {
        let result=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
        if let checkpoint=self.preparationCheckpoint {await checkpoint()}
        guard !Task.isCancelled,job.generation==token,self.contextMatches(job) else{throw CancellationError()}
        let otherBytes=self.jobs.values.filter{$0.id != job.id}.reduce(0){sum,value in sum+(value.document.map{Self.estimatedBytes($0)} ?? 0)+(value.preparedScene?.approximateBytes ?? 0)+(value.normalized?.count ?? 0)}
        guard result.cost+result.normalized.count<=Self.preparedImportLimitBytes-otherBytes else{throw MeshAssetError.limit("Prepared import reviews exceed the 512 MiB aggregate budget. Commit or cancel an existing review.")}
        job.worker=nil
        job.document=result.document;job.normalized=result.normalized;job.reference=result.reference;job.preparedScene=result.scene;job.renderWarnings=result.scene.warnings;job.state="ready";job.error=nil
      }catch {
        guard job.generation==token else{return}
        job.worker=nil
        job.state=(error is CancellationError) ? "cancelled":"failed";job.error=error.localizedDescription
      }
    }
  }
  nonisolated static func prepareAsset(url:URL,unit:MeshSourceUnit?,name:String)throws->PreparedAsset {
    let document=try MeshAssetImporter.importFile(url,options:.init(sourceUnit:unit));try MeshAssetGeometry.validate(document)
    let documentCost=estimatedBytes(document)
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];let normalized=try encoder.encode(document)
    guard normalized.count<=normalizedByteLimit else{throw MeshAssetError.limit("Normalized asset exceeds 768 MiB.")}
    let id=UUID().uuidString,source=id+"."+url.pathExtension.lowercased(),normal=id+".mesh.json"
    let reference=MeshAssetReference(document:document,sourceAsset:source,normalizedAsset:normal,normalizedSHA256:MeshAssetHash.sha256(normalized),name:name)
    try reference.validate();let scene=try MeshAssetSceneAdapter.prepare(document:document,reference:reference),cost=documentCost+scene.approximateBytes
    guard cost<=cacheLimitBytes else{throw MeshAssetError.limit("Decoded model and prepared display buffers exceed the 256 MiB interactive asset budget. Reduce mesh/texture resolution.")}
    return .init(document:document,normalized:normalized,reference:reference,scene:scene,cost:cost)
  }
  nonisolated static func estimatedBytes(_ document:MeshAssetDocument)->Int {
    document.sourceData.count+document.externalResources.reduce(0){$0+$1.data.count}+document.images.reduce(0){$0+$1.data.count}+document.meshes.reduce(0){sum,mesh in sum+mesh.primitives.reduce(0){$0+$1.positionsMM.count*24+$1.normals.count*12+$1.indices.count*4+($1.uv0.count+$1.uv1.count)*8+$1.tangents.count*16+$1.colors.count*16}}
  }
  /// Starts detached immutable resource staging; poll status until committed/failed/cancelled.
  /// The final guarded graph publication is one main-actor edit, with no large file IO.
  func commit(_ job:ModelImportReview,source:String="Studio")throws {
    guard let store,job.state=="ready",let document=job.document,let normalized=job.normalized,let preparedScene=job.preparedScene,var reference=job.reference,contextMatches(job) else{throw FormError.invalid("The model is not ready or the project's source changed. Start a fresh review.")}
    guard !job.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,job.name.utf8.count<=256 else{throw FormError.invalid("Enter a model name within 256 UTF-8 bytes.")}
    store.finishArtworkEditing()
    guard contextMatches(job) else{throw FormError.invalid("Finishing active edits changed the source revision. Review the import against the new revision.")}
    reference.name=job.name;try reference.validate()
    let acceptedReference=reference
    let assets=store.repository.url(for:job.projectID).appendingPathComponent("Assets",isDirectory:true),token=UUID(),name=job.name
    job.generation=token;job.state="publishing";job.error=nil
    let worker=Task.detached(priority:.userInitiated) {try Self.publishResources(document:document,normalized:normalized,reference:acceptedReference,assets:assets)}
    job.publicationWorker=worker
    job.task=Task { [weak self,weak job] in
      var published:PublishedFiles?
      do {
        let result=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
        published=result
        if let checkpoint=self?.publicationCheckpoint {await checkpoint()}
        guard let self,let job,let store=self.store,!Task.isCancelled,job.generation==token,job.state=="publishing" else{throw CancellationError()}
        guard self.contextMatches(job) else{throw FormError.invalid("The source changed during import publication. Start a fresh review.")}
        // A newly focused field may have accumulated edits while disk IO ran.
        store.finishArtworkEditing()
        guard self.contextMatches(job) else{throw FormError.invalid("The source changed during import publication. Start a fresh review.")}
        var created:ProductObject?
        try store.engine.edit("Imported 3D model",source:source) {project in
          guard project.id==job.projectID,Self.sourceSnapshot(project)==job.sourceProject else{throw FormError.invalid("The import source revision is stale.")}
          var object=try project.makeObject(recipeID:"importedMesh",name:name,parameters:["scalePercent":100]);object.meshAsset=acceptedReference;object.position=try Self.newPosition(for:object,in:project)
          project.objects.append(object);created=object
        }
        guard let object=created else{throw FormError.invalid("The imported object was not published.")}
        published=nil // Resources now belong to the durable revision/Undo history.
        self.remember(document,scene:preparedScene,key:acceptedReference.normalizedSHA256);job.reference=acceptedReference;job.objectID=object.id;job.state="committed";store.select(object.id);store.showingHome=false
        job.document=nil;job.normalized=nil;job.preparedScene=nil;job.worker=nil;job.publicationWorker=nil
        store.changed();if self.review?.id==job.id {self.review=nil}
      }catch {
        if let published {await Task.detached(priority:.utility) {Self.removePublished(published)}.value}
        guard let job,job.generation==token else{return}
        job.publicationWorker=nil
        job.state=(error is CancellationError) ? "cancelled":"failed";job.error=error.localizedDescription
      }
    }
  }
  private nonisolated static func publishResources(document:MeshAssetDocument,normalized:Data,reference:MeshAssetReference,assets:URL)throws->PublishedFiles {
    try Task.checkCancellation()
    let fm=FileManager.default,stage=assets.appendingPathComponent(".model-import-"+UUID().uuidString,isDirectory:true)
    try fm.createDirectory(at:stage,withIntermediateDirectories:true)
    defer{try? fm.removeItem(at:stage)}
    var published:[URL]=[]
    do {
      let files=[(reference.sourceAsset,document.sourceData),(reference.normalizedAsset,normalized)]
      for (name,data) in files {
        try Task.checkCancellation();let target=assets.appendingPathComponent(name)
        guard !fm.fileExists(atPath:target.path) else{throw FormError.invalid("An immutable model destination already exists.")}
        try data.write(to:stage.appendingPathComponent(name),options:.withoutOverwriting)
      }
      for (name,_) in files {try Task.checkCancellation();let target=assets.appendingPathComponent(name);try fm.moveItem(at:stage.appendingPathComponent(name),to:target);published.append(target)}
      try Task.checkCancellation();return .init(urls:published)
    }catch {removePublished(.init(urls:published));throw error}
  }
  private nonisolated static func removePublished(_ files:PublishedFiles) {for url in files.urls {try? FileManager.default.removeItem(at:url)}}
  private nonisolated static func newPosition(for imported:ProductObject,in project:Project)throws->Vector3 {
    let physical=project.objects.filter{$0.hasTablePresentation};guard !physical.isEmpty else{return .init()}
    let right=physical.map {object->Double in
      let angle=object.rotation*Double.pi/180,c=cos(angle),s=sin(angle)
      if let cad=object.cadRepresentation {return object.position.x+[cad.minimum.x,cad.maximum.x].flatMap{x in [cad.minimum.z,cad.maximum.z].map{c*x+s*$0}}.max()!}
      return object.position.x+abs(c)*object.footprintWidth/2+abs(s)*object.footprintDepth/2
    }.max() ?? 0
    let x=right+imported.footprintWidth/2+25
    guard x.isFinite,abs(x)<=1e7 else{throw FormError.invalid("New imported model placement exceeds the physical workspace bounds.")}
    return .init(x,0,0)
  }
  func cancel(_ job:ModelImportReview) {job.generation=UUID();job.task?.cancel();job.worker?.cancel();job.publicationWorker?.cancel();job.state="cancelled";job.document=nil;job.normalized=nil;job.preparedScene=nil;job.worker=nil;job.publicationWorker=nil;if review?.id==job.id {review=nil}}
  private func remember(_ document:MeshAssetDocument,scene:MeshAssetPreparedScene,key:String) {
    let cost=Self.estimatedBytes(document)+scene.approximateBytes;guard cost<=Self.cacheLimitBytes else{return}
    if let old=cache.removeValue(forKey:key) {cacheBytes-=old.cost};order.removeAll{$0==key}
    while cacheBytes+cost>Self.cacheLimitBytes,let first=order.first {order.removeFirst();if let old=cache.removeValue(forKey:first){cacheBytes-=old.cost}}
    cache[key]=(document,scene,cost);order.append(key);cacheBytes+=cost
  }
  /// Returns only validated cached geometry. A cache miss schedules bounded loading off the UI thread.
  func resolvedAsset(for object:ProductObject,assets:URL)->MeshAssetDocument? {
    guard let reference=object.meshAsset else{return nil}
    let key=reference.normalizedSHA256
    if let cached=cache[key] {return cached.document}
    guard loads[key]==nil,failures[key]==nil else{return nil}
    let token=generation,projectID=store?.project?.id
    loading.insert(key)
    let worker=Task.detached(priority:.userInitiated) {
      let document=try Self.readAsset(reference,assets:assets),scene=try MeshAssetSceneAdapter.prepare(document:document,reference:reference),cost=Self.estimatedBytes(document)+scene.approximateBytes
      guard cost<=Self.cacheLimitBytes else{throw MeshAssetError.limit("Loaded asset exceeds the interactive mesh/texture memory budget.")}
      return PreparedAsset(document:document,normalized:Data(),reference:reference,scene:scene,cost:cost)
    };loadWorkers[key]=worker
    loads[key]=Task { [weak self] in
      guard let self else{return}
      defer{if self.generation==token {self.loads.removeValue(forKey:key);self.loadWorkers.removeValue(forKey:key);self.loading.remove(key)}}
      do {
        let prepared=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
        guard !Task.isCancelled,self.generation==token,self.store?.project?.id==projectID else{return}
        self.remember(prepared.document,scene:prepared.scene,key:key);self.store?.changed(save:false)
      }catch {guard self.generation==token else{return};self.failures[key]=error.localizedDescription;self.store?.changed(save:false)}
    }
    return nil
  }
  func resolvedScene(for object:ProductObject,assets:URL,artwork:CGImage?=nil,artworkRevision:String="none")->[SceneRenderablePayload]? {
    guard let reference=object.meshAsset else{return nil}
    _ = resolvedAsset(for:object,assets:assets)
    guard let prepared=cache[reference.normalizedSHA256]?.scene else{return nil}
    let key=reference.normalizedSHA256+"|"+reference.appearanceRevision+"|"+(artwork==nil ? "none":artworkRevision)
    pendingAppearance[object.id]=key
    func placed(_ appearance:MeshAssetSceneAppearance)->[SceneRenderablePayload] {MeshAssetSceneAdapter.renderables(appearance,objectID:object.id,positionMM:.init(object.position.x,object.position.y,object.position.z),yawDegrees:object.rotation,scalePercent:object["scalePercent"])}
    if let appearance=appearances[key] {lastAppearance[object.id]=key;return placed(appearance)}
    let recolor=reference.materialOverrides.contains {override in override.colorHex != nil && prepared.materials.indices.contains(override.materialIndex) && prepared.materials[override.materialIndex].baseColorTexture != nil}
    if !recolor && (artwork==nil || reference.artworkBindings.isEmpty) {
      do {let appearance=try MeshAssetSceneAdapter.appearance(prepared,reference:reference);rememberAppearance(appearance,key:key);lastAppearance[object.id]=key;return placed(appearance)}catch{failures[reference.normalizedSHA256]=error.localizedDescription;return nil}
    }
    if appearanceTasks[key]==nil {
      let token=generation,objectID=object.id,image=artwork
      let worker=Task.detached(priority:.userInitiated) {try MeshAssetSceneAdapter.appearance(prepared,reference:reference,artwork:image,artworkRevision:artworkRevision)};appearanceWorkers[key]=worker
      appearanceTasks[key]=Task { [weak self] in
        guard let self else{return}
        defer{if self.generation==token {self.appearanceTasks.removeValue(forKey:key);self.appearanceWorkers.removeValue(forKey:key)}}
        do {
          let appearance=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
          guard !Task.isCancelled,self.generation==token,self.pendingAppearance[objectID]==key else{return}
          self.rememberAppearance(appearance,key:key);self.lastAppearance[objectID]=key;self.store?.changed(save:false)
        }catch{guard self.generation==token else{return};self.failures[reference.normalizedSHA256]=error.localizedDescription;self.store?.changed(save:false)}
      }
    }
    if let last=lastAppearance[object.id],let appearance=appearances[last] {return placed(appearance)}
    return nil
  }
  private func rememberAppearance(_ appearance:MeshAssetSceneAppearance,key:String) {
    let limit=64*1024*1024;guard appearance.approximateBytes<=limit else{return}
    if let old=appearances.removeValue(forKey:key) {appearanceBytes-=old.approximateBytes};appearanceOrder.removeAll{$0==key}
    while appearanceBytes+appearance.approximateBytes>limit || appearanceOrder.count>=256,let first=appearanceOrder.first {appearanceOrder.removeFirst();if let old=appearances.removeValue(forKey:first){appearanceBytes-=old.approximateBytes}}
    appearances[key]=appearance;appearanceOrder.append(key);appearanceBytes+=appearance.approximateBytes
  }
  nonisolated static func readAsset(_ reference:MeshAssetReference,assets:URL)throws->MeshAssetDocument {
    try reference.validate()
    let root=assets.standardizedFileURL.resolvingSymlinksInPath(),url=root.appendingPathComponent(reference.normalizedAsset).resolvingSymlinksInPath()
    guard url.deletingLastPathComponent()==root else{throw MeshAssetError.invalid("The normalized asset resolves outside its project.")}
    let values=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
    guard values.isRegularFile==true,let size=values.fileSize,size>0,size<=normalizedByteLimit else{throw MeshAssetError.limit("Normalized model resource is missing or exceeds 768 MiB.")}
    let data=try Data(contentsOf:url);guard data.count<=normalizedByteLimit,MeshAssetHash.sha256(data)==reference.normalizedSHA256 else{throw MeshAssetError.invalid("The normalized model resource digest changed.")}
    let document=try JSONDecoder().decode(MeshAssetDocument.self,from:data);try MeshAssetGeometry.validate(document)
    guard document.provenance.sourceSHA256==reference.sourceSHA256,document.boundsMM==reference.boundsMM,document.vertexCount==reference.vertexCount,document.triangleCount==reference.triangleCount,estimatedBytes(document)<=cacheLimitBytes else{throw MeshAssetError.invalid("Normalized geometry disagrees with its product reference.")}
    let original=root.appendingPathComponent(reference.sourceAsset).resolvingSymlinksInPath()
    guard original.deletingLastPathComponent()==root else{throw MeshAssetError.invalid("The original asset resolves outside its project.")}
    let sourceValues=try original.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
    guard sourceValues.isRegularFile==true,let count=sourceValues.fileSize,count==document.sourceData.count,count<=MeshImportLimits().sourceBytes,MeshAssetHash.sha256(try Data(contentsOf:original))==reference.sourceSHA256 else{throw MeshAssetError.invalid("The original model source is missing or its digest changed.")}
    return document
  }
  func retry(_ object:ProductObject,assets:URL) {if let key=object.meshAsset?.normalizedSHA256 {failures.removeValue(forKey:key);_ = resolvedAsset(for:object,assets:assets)}}
  func issue(for object:ProductObject)->String? {object.meshAsset.flatMap{failures[$0.normalizedSHA256]}}
  nonisolated static func scale(_ object:ProductObject)->Double {object["scalePercent"]/100}
  nonisolated static func sourceToTableOffset(_ reference:MeshAssetReference)->MeshPoint3 {.init(-(reference.boundsMM.minimum.x+reference.boundsMM.maximum.x)/2,-reference.boundsMM.minimum.y,-(reference.boundsMM.minimum.z+reference.boundsMM.maximum.z)/2)}
  func bounds(for object:ProductObject)->MeshAssetBounds? {
    guard let reference=object.meshAsset else{return nil};let s=Self.scale(object),size=reference.boundsMM.size
    return .init(minimum:.init(-size.x*s/2,0,-size.z*s/2),maximum:.init(size.x*s/2,size.y*s,size.z*s/2))
  }
  var diagnostics:[String:Any] {["cached_assets":cache.count,"cache_bytes":cacheBytes,"cache_limit_bytes":Self.cacheLimitBytes,"loading":loading.count,"failed":failures.count,"appearance_cache_bytes":appearanceBytes,"appearance_cache_limit_bytes":64*1024*1024]}
  private func job(_ args:[String:Any])throws->ModelImportReview {guard let text=args["job_id"] as? String,let id=UUID(uuidString:text),let job=jobs[id] else{throw FormError.missing("Model import job not found. Start a fresh import if the project changed.")};return job}
  func status(_ job:ModelImportReview)throws->[String:Any] {
    var report:[String:Any]=["job_id":job.id.uuidString,"state":job.state,"project_id":job.projectID.uuidString,"name":job.name,"source_units":job.sourceUnit?.rawValue ?? "format_declared","source_revision_current":contextMatches(job),"error":job.error as Any? ?? NSNull(),"object_id":job.objectID?.uuidString as Any? ?? NSNull()]
    if let reference=job.reference {report["asset"]=try jsonObject(reference)};return report
  }
  func call(_ args:[String:Any])throws->Any {
    if let value=args["command"],!(value is String) {throw FormError.invalid("command must be a string.")}
    let command=args["command"] as? String ?? "formats"
    let allowed:[String:Set<String>]=["formats":["command"],"import":["command","path","source_units","name"],"status":["command","job_id"],"commit":["command","job_id"],"cancel":["command","job_id"],"inspect":["command","object_id"],"material":["command","object_id","material_index","color","metallic","roughness","opacity","clear"],"artwork":["command","object_id","material_index","source_object_id","primitive_ids","clear"]]
    guard let keys=allowed[command],Set(args.keys).isSubset(of:keys.union(["_source"])) else{throw FormError.invalid("Unknown model asset command or unsupported argument.")}
    if let clear=args["clear"] {guard let n=clear as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{throw FormError.invalid("clear must be Boolean.")}}
    for key in ["name","color"] {if let value=args[key],!(value is String) {throw FormError.invalid("\(key) must be a string.")}}
    if let value=args["primitive_ids"],!(value is [String]) {throw FormError.invalid("primitive_ids must be an array of strings.")}
    switch command {
    case "formats":return ["formats":["glb","gltf","stl"],"gltf_units":"meters by format declaration; explicit override retained","stl_units":"explicit source_units required","editability":"visualMesh","limits":["source_bytes":MeshImportLimits().sourceBytes,"vertices":MeshImportLimits().vertices,"triangles":MeshImportLimits().triangles,"texture_edge":MeshImportLimits().textureEdge,"decoded_asset_bytes":Self.cacheLimitBytes],"unsupported":["skinning","morph targets","required Draco/meshopt compression","OBJ","USD/USDZ"],"printer_commands":false]
    case "import":
      guard let path=args["path"] as? String,path.hasPrefix("/") else{throw FormError.invalid("Import requires an absolute local path.")}
      let unit:MeshSourceUnit?
      if let value=args["source_units"] {guard let raw=value as? String,let parsed=MeshSourceUnit(rawValue:raw) else{throw FormError.invalid("source_units must be millimeter, centimeter, meter or inch.")};unit=parsed}else{unit=nil}
      let url=URL(fileURLWithPath:path);if url.pathExtension.lowercased()=="stl",unit==nil {throw MeshAssetError.unitRequired("Pass source_units for STL import.")}
      let value=try beginImport(url:url,sourceUnit:unit,name:args["name"] as? String,present:false);return try status(value)
    case "status":return try status(job(args))
    case "commit":let value=try job(args);try commit(value,source:"Codex");return try status(value)
    case "cancel":let value=try job(args);cancel(value);return try status(value)
    case "inspect":
      let object=try sourceObject(args),reference=object.meshAsset!;return ["object_id":object.id.uuidString,"asset":try jsonObject(reference),"display_bounds_mm":try jsonObject(bounds(for:object)),"loaded":cache[reference.normalizedSHA256] != nil,"load_error":issue(for:object) as Any? ?? NSNull(),"manufacturing_validated":false]
    case "material":return try editMaterial(args)
    case "artwork":return try bindArtwork(args)
    default:throw FormError.invalid("Unknown model asset command.")
    }
  }
  private func sourceObject(_ args:[String:Any])throws->ProductObject {
    guard let store,let text=args["object_id"] as? String,let id=UUID(uuidString:text),let object=store.project?.objects.first(where:{$0.id==id}),object.meshAsset != nil else{throw FormError.missing("Choose an imported visual mesh object.")};return object
  }
  private func materialIndex(_ args:[String:Any])throws->Int {
    guard let n=args["material_index"] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,n.doubleValue.rounded()==n.doubleValue,n.intValue>=0 else{throw FormError.invalid("material_index must be a nonnegative integer.")};return n.intValue
  }
  private func editMaterial(_ args:[String:Any])throws->Any {
    guard let store else{throw FormError.missing("The project closed.")};let object=try sourceObject(args),index=try materialIndex(args)
    guard !object.locked else{throw FormError.invalid("Unlock this object before changing its material slots.")}
    var reference=object.meshAsset!;let previous=reference.materialOverrides.first{$0.materialIndex==index};reference.materialOverrides.removeAll{$0.materialIndex==index}
    guard reference.materials.contains(where:{$0.index==index}) else{throw FormError.invalid("The material slot is unavailable.")}
    if args["clear"] as? Bool != true {
      func number(_ key:String)throws->Double? {guard let value=args[key] else{return nil};guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{throw FormError.invalid("\(key) must be a finite number.")};return n.doubleValue}
      var value=previous ?? MeshAssetMaterialOverride(materialIndex:index)
      value.colorHex=args["color"] as? String ?? value.colorHex;value.metallic=try number("metallic") ?? value.metallic;value.roughness=try number("roughness") ?? value.roughness;value.opacity=try number("opacity") ?? value.opacity
      guard value.colorHex != nil || value.metallic != nil || value.roughness != nil || value.opacity != nil else{throw FormError.invalid("Choose surface color, metallic, roughness, opacity or clear for this material slot.")}
      try value.validate();reference.materialOverrides.append(value);reference.materialOverrides.sort{$0.materialIndex<$1.materialIndex}
    }
    try reference.validate()
    try store.engine.edit("Changed imported material",source:"Codex") {project in guard let i=project.objects.firstIndex(where:{$0.id==object.id}),!project.objects[i].locked else{throw FormError.invalid("Imported object became unavailable.")};project.objects[i].meshAsset=reference}
    store.changed();return try jsonObject(reference)
  }
  private func bindArtwork(_ args:[String:Any])throws->Any {
    guard let store else{throw FormError.missing("The project closed.")};let object=try sourceObject(args),index=try materialIndex(args)
    guard !object.locked else{throw FormError.invalid("Unlock this object before changing its UV artwork.")}
    var reference=object.meshAsset!;reference.artworkBindings.removeAll{$0.materialIndex==index}
    guard reference.materials.contains(where:{$0.index==index}) else{throw FormError.invalid("The material slot is unavailable.")}
    let clear=args["clear"] as? Bool==true
    var sourceID:UUID?
    if !clear {
      guard let value=args["source_object_id"] as? String,let id=UUID(uuidString:value) else{throw FormError.invalid("Choose a same-project independent artwork source.")};sourceID=id
      guard let project=store.project,let source=project.objects.first(where:{$0.id==id}) else{throw FormError.missing("Artwork source unavailable.")};let size=project.artworkSize(source);reference.artworkSizeMM = .init(width:size.x,height:size.y)
      let ids=args["primitive_ids"] as? [String] ?? [];reference.artworkBindings.append(.init(materialIndex:index,primitiveIDs:ids));reference.artworkBindings.sort{$0.materialIndex<$1.materialIndex};try reference.validate()
    }
    try reference.validate()
    try store.engine.edit("Mapped artwork to imported UVs",source:"Codex") {project in
      if !clear {try project.linkArtwork(object.id,sourceID:sourceID,fit:"fit")}
      guard let i=project.objects.firstIndex(where:{$0.id==object.id}),!project.objects[i].locked else{throw FormError.invalid("Imported object became unavailable.")};project.objects[i].meshAsset=reference
    }
    store.changed();return ["asset":try jsonObject(reference),"mapping":"UV0 appearance only; physical scale and seam continuity are unverified"]
  }
}

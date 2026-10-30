import AppKit
import CoreFoundation
import Foundation
import FormCore
import FormCADModel
import FormCADKernel
import FormCADModeling
import LabRendering
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class CADModelReview:ObservableObject,Identifiable {
  let id=UUID(),projectID:UUID,epoch:UUID,source:Project,targetObjectID:UUID?
  let previewObjectID=UUID()
  @Published var definition:CADModelDefinition
  @Published var state="draft"
  @Published var issue:String?
  @Published var scene:[SceneRenderablePayload]=[]
  @Published var quality="inspection"
  @Published var sourceUpAxis="y"
  var importURL:URL?
  var token=UUID(),task:Task<Void,Never>?,worker:Task<CADModelCoordinator.Prepared,Error>?
  var prepared:CADModelCoordinator.Prepared?
  var result:[String:Any]=[:]
  var diagnostic:[String:Any]?
  var timings:[String:Double]=[:]
  var evidenceTasks:[UUID:Task<Void,Never>]=[:]
  var pendingEvidence:[[String:Any]]?
  init(definition:CADModelDefinition,project:Project,epoch:UUID,target:UUID?){self.definition=definition;projectID=project.id;self.epoch=epoch;source=CADModelCoordinator.sourceSnapshot(project);targetObjectID=target}
}

/// Native review and MCP calls share the same staged exact evaluation and guarded publication.
@MainActor final class CADModelCoordinator:ObservableObject {
  static let maximumDefinitionSubmissionBytes=4*1024*1024
  struct Prepared:Sendable {
    var definition:CADModelDefinition,evaluation:CADModelEvaluation,representation:CADRepresentation
    var stage:URL,files:[String:URL],scene:[SceneRenderablePayload]
    var display:CADSceneAdapter.Prepared
    var timings:[String:Double]
    var durable=false
  }
  weak var store:StudioStore?
  @Published var review:CADModelReview?
  @Published private(set) var failures:[UUID:String]=[:]
  private var failureKeys:[UUID:String]=[:],loadTokens:[String:UUID]=[:]
  private var epoch=UUID()
  var jobs:[UUID:CADModelReview]=[:]
  var evaluator=CADModelEvaluator()
  var evidenceRequests:[UUID:CADEvidenceRequest]=[:]
  private var scenes:[String:CADSceneAdapter.Prepared]=[:],sceneOrder:[String]=[],sceneBytes=0
  private var loads:[String:Task<Void,Never>]=[:],loadWorkers:[String:Task<CADSceneAdapter.Prepared,Error>]=[:]
  var preparationCheckpoint:(()async->Void)?
  var sceneLoadCheckpoint:((ProductObject)async->Void)?
  init(store:StudioStore){self.store=store}
  nonisolated static func sourceSnapshot(_ project:Project)->Project {var p=project;p.camera = .init();return p}
  func matches(_ job:CADModelReview)->Bool {guard let p=store?.project else{return false};return epoch==job.epoch&&p.id==job.projectID&&Self.sourceSnapshot(p)==job.source}
  func reset(){epoch=UUID();for job in jobs.values{cancel(job)};jobs=[:];evidenceRequests=[:];review=nil;for task in loads.values{task.cancel()};for worker in loadWorkers.values{worker.cancel()};loads=[:];loadWorkers=[:];scenes=[:];sceneOrder=[];sceneBytes=0;failures=[:];failureKeys=[:];loadTokens=[:];evaluator=CADModelEvaluator()}
  func openEditor(objectID:UUID?=nil){do{guard let p=store?.project else{throw FormError.missing("Open a project first.")};let definition=try objectID.map{id in guard let o=p.objects.first(where:{$0.id==id}),let d=o.cadModel else{throw FormError.invalid("Choose an exact CAD model.")};return d} ?? CADModelExamples.enclosure();let job=try begin(definition,target:objectID);review=job}catch{store?.error=error.localizedDescription}}
  func openImport() {
    guard store?.project != nil else{store?.error="Open a project before importing exact geometry.";return}
    let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;panel.allowedContentTypes=["step","stp","brep"].compactMap{UTType(filenameExtension:$0)};panel.title="Import exact CAD body"
    panel.message="Preserve original exact geometry. STEP declares units; BRep assumes millimeters, so verify its source scale. Imported construction history is unavailable."
    let axis=NSPopUpButton(frame:.init(x:0,y:0,width:220,height:28));axis.addItems(withTitles:["Source uses Y up","Source uses Z up"]);panel.accessoryView=axis
    if panel.runModal() == .OK,let url=panel.url{do{let job=try importReview(url:url,name:nil,sourceUpAxis:axis.indexOfSelectedItem==1 ? "z":"y");review=job}catch{store?.error=error.localizedDescription}}
  }
  @discardableResult private func importReview(url:URL,name:String?,sourceUpAxis:String="y")throws->CADModelReview {
    let node=CADFeatureNode(name:"Awaiting exact source",operation:.init(.box,values:["width":1,"height":1,"depth":1]))
    let draft=CADModelDefinition(name:name ?? url.deletingPathExtension().lastPathComponent,features:[node],outputs:[node.id])
    guard ["y","z"].contains(sourceUpAxis) else{throw FormError.invalid("source_up_axis must be y or z.")}
    let job=try begin(draft);job.sourceUpAxis=sourceUpAxis;preview(job,importURL:url);return job
  }
  @discardableResult func begin(_ definition:CADModelDefinition,target:UUID?=nil)throws->CADModelReview {
    guard let store,let p=store.project else{throw FormError.missing("Open a project first.")}
    _ = try definition.validatedOrder(checkRequirements:false)
    if let target{guard let object=p.objects.first(where:{$0.id==target}),object.cadModel != nil,!object.locked else{throw FormError.invalid("Choose an unlocked exact CAD model.")}}
    for old in jobs.values where old.definition.id==definition.id&&["preparing","publishing"].contains(old.state){throw FormError.invalid("Finish or cancel the active evaluation for this model.")}
    while jobs.count>=8,let old=jobs.values.first(where:{["failed","cancelled","committed"].contains($0.state)}){cancel(old);jobs.removeValue(forKey:old.id)}
    guard jobs.count<8 else{throw FormError.invalid("Commit or cancel a CAD review before starting another.")}
    let job=CADModelReview(definition:definition,project:p,epoch:epoch,target:target);jobs[job.id]=job;return job
  }
  func preview(_ job:CADModelReview,importURL:URL?=nil){
    if let importURL{job.importURL=importURL}
    guard matches(job) else{job.state="failed";job.issue="The source project changed. Start a fresh CAD review.";return}
    job.task?.cancel();job.worker?.cancel();cancelEvidence(for:job);let previous=job.prepared
    let token=UUID();job.token=token;job.state="preparing";job.issue=nil;job.diagnostic=nil;job.result=[:]
    let definition=job.definition,sourceUpAxis=job.sourceUpAxis,quality=job.quality,sourceURL=job.importURL,assets=store!.repository.url(for:job.projectID).appendingPathComponent("Assets"),evaluator=self.evaluator,target=job.targetObjectID ?? job.previewObjectID
    let worker=Task.detached(priority:.userInitiated){try await Self.prepare(definition,evaluator:evaluator,assets:assets,objectID:target,importURL:sourceURL,sourceUpAxis:sourceUpAxis,quality:quality,sourceOverrides:previous?.files ?? [:])};job.worker=worker
    job.task=Task{[weak self,weak job] in guard let self,let job else{return};do{
      var prepared=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
      if let checkpoint=self.preparationCheckpoint{await checkpoint()}
      guard !Task.isCancelled,job.token==token,self.matches(job) else{self.removeStage(prepared.stage);throw CancellationError()}
      let otherCost=self.jobs.values.filter{$0.id != job.id}.reduce(0){$0+($1.prepared?.scene.reduce(0){$0+$1.mesh.approximateBytes} ?? 0)}
      guard otherCost+prepared.scene.reduce(0,{$0+$1.mesh.approximateBytes})<=256*1024*1024 else{self.removeStage(prepared.stage);throw FormError.invalid("Prepared CAD reviews exceed the aggregate interactive buffer budget. Commit or cancel another review.")}
      if let target=job.targetObjectID,let project=self.store?.project,var object=project.objects.first(where:{$0.id==target}) {
        object.cadModel=prepared.definition;object.cadRepresentation=prepared.representation
        let start=ProcessInfo.processInfo.systemUptime
        prepared.scene=try CADSurfaceAppearance.apply(prepared.display,object:object,project:project,assets:assets,materials:self.store?.materials ?? FormCore.Material.presets)
        prepared.timings["surface_artwork"]=(ProcessInfo.processInfo.systemUptime-start)*1000
      }
      if let previous,previous.stage != prepared.stage{self.removeStage(previous.stage)}
      job.importURL=nil;job.definition=prepared.definition;job.prepared=prepared;job.scene=prepared.scene;job.timings=prepared.timings;job.worker=nil;job.state="ready"
      if let requests=job.pendingEvidence {job.pendingEvidence=nil;do{_ = try self.startEvidence(job,requests:requests)}catch{job.diagnostic=self.diagnostic(error,job:job,category:"evidence")}}
    }catch{guard job.token==token else{return};job.worker=nil;job.state=error is CancellationError ? "cancelled":"failed";job.issue=error.localizedDescription;job.diagnostic=self.diagnostic(error,job:job)}}
  }
  nonisolated static func prepare(_ proposed:CADModelDefinition,evaluator:CADModelEvaluator,assets:URL,objectID:UUID,importURL:URL?=nil,sourceUpAxis:String="y",quality:String="inspection",sourceOverrides:[String:URL]=[:])async throws->Prepared {
    let started=ProcessInfo.processInfo.systemUptime
    let fm=FileManager.default,workspace=fm.temporaryDirectory.appendingPathComponent("lab-cad-"+UUID().uuidString,isDirectory:true)
    try fm.createDirectory(at:workspace,withIntermediateDirectories:false)
    do{
      var model=proposed,sourceFiles:[String:URL]=[:]
      let resources=workspace.appendingPathComponent("Sources",isDirectory:true);try fm.createDirectory(at:resources,withIntermediateDirectories:false)
      if let importURL {
        guard importURL.isFileURL,["step","stp","brep"].contains(importURL.pathExtension.lowercased()) else{throw FormError.invalid("Choose a local STEP or BRep source.")}
        let values=try importURL.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]);guard values.isRegularFile==true,let size=values.fileSize,size>0,size<=256*1024*1024 else{throw FormError.invalid("Exact import is missing or exceeds 256 MiB.")}
        let data=try Data(contentsOf:importURL),hash=CADSceneAdapter.digest(data),name="cad-source-\(hash)."+(importURL.pathExtension.lowercased()=="brep" ? "brep":"step"),url=resources.appendingPathComponent(name)
        try data.write(to:url,options:.withoutOverwriting);sourceFiles[name]=url
        guard ["y","z"].contains(sourceUpAxis) else{throw FormError.invalid("Choose y or z as the STEP source up axis.")}
        model.features=[];model.outputs=[];model.parameters=[];model.importedAssemblies=nil
        if importURL.pathExtension.lowercased()=="brep" {
          let node=CADFeatureNode(name:"Imported exact body",operation:.init(.importedBRep,source:.init(path:name,sha256:hash)));model.features=[node];model.outputs=[node.id]
          if sourceUpAxis=="z"{let placement=CADFeatureNode(name:"Z-up to Y-up source placement",operation:.init(.transform,inputs:[node.id],matrix:[1,0,0,0,0,0,1,0,0,-1,0,0,0,0,0,1]));model.features.append(placement);model.outputs=[placement.id]}
          model.assumptions=["Exact BRep body with original bytes retained; source feature history is unavailable.","BRep has no physical unit metadata. Millimeters are an unverified source-scale assumption; verify the original dimensions before fabrication."]
        }else{
          let kernel=await evaluator.kernel,assembly=try await kernel.readSTEPAssembly(from:url)
          guard assembly.sourceSHA256==hash,assembly.parts.count*(sourceUpAxis=="z" ? 2:1)<=256 else{throw FormError.invalid("STEP source changed or its leaf construction exceeds the 256-feature graph budget.")}
          var outputByPath:[String:UUID]=[:]
          for node in assembly.nodes where !node.assembly {
            let feature=CADFeatureNode(id:stableID("\(model.id):\(hash):\(node.path):source"),name:boundedName(node.name),operation:.init(.importedSTEP,source:.init(path:name,sha256:hash,partPath:node.path)))
            model.features.append(feature);var output=feature.id
            if sourceUpAxis=="z"{let placement=CADFeatureNode(id:stableID("\(model.id):\(hash):\(node.path):orientation"),name:boundedName(node.name),operation:.init(.transform,inputs:[feature.id],matrix:[1,0,0,0,0,0,1,0,0,-1,0,0,0,0,0,1]));model.features.append(placement);output=placement.id}
            outputByPath[node.path]=output;model.outputs.append(output)
          }
          let nodes=assembly.nodes.map{node in CADImportedAssemblyNode(path:node.path,parentPath:node.parentIndex.map{assembly.nodes[$0].path},definitionKey:node.definitionKey,name:node.name,assembly:node.assembly,localTransformMM:node.localTransformMM,worldTransformMM:node.worldTransformMM,linearRGBA:node.linearRGBA,faceColors:node.faceColors.map{.init(faceIndex:$0.faceIndex,linearRGBA:$0.rgba)},outputFeatureID:outputByPath[node.path])}
          model.importedAssemblies=[.init(source:.init(path:name,sha256:hash),kernelVersion:assembly.kernelVersion,sourceUpAxis:sourceUpAxis,nodes:nodes)]
          model.assumptions=["STEP source hierarchy, occurrence names, repeated part definitions, placements, part colors and per-face colors are retained. Imported construction history is unavailable."]
        }
        model.assumptions.append("Source up axis explicitly set to \(sourceUpAxis.uppercased()); Z-up sources receive an exact rigid placement into LAB +Y up.")
      }else{
        for source in model.features.compactMap(\.operation.source){if sourceFiles[source.path] != nil{continue};let sourceRoot=sourceOverrides[source.path]?.deletingLastPathComponent() ?? assets,sourceName=sourceOverrides[source.path]?.lastPathComponent ?? source.path;let data=try CADSceneAdapter.verifiedAsset(sourceName,sha256:source.sha256,assets:sourceRoot,maximumBytes:256*1024*1024),url=resources.appendingPathComponent(source.path);if !fm.fileExists(atPath:url.path){try data.write(to:url,options:.withoutOverwriting)};sourceFiles[source.path]=url}
      }
      try Task.checkCancellation()
      let tessellation:CADTessellation;switch quality{case "preview":tessellation = .preview;case "inspection":tessellation = .inspection;case "fabrication":tessellation = .fabrication;default:throw FormError.invalid("CAD quality must be preview, inspection or fabrication.")}
      let evaluationStart=ProcessInfo.processInfo.systemUptime
      var evaluation=try await evaluator.evaluate(model,resourcesAt:resources)
      if var assemblies=model.importedAssemblies {
        var updated=false
        for a in assemblies.indices{for n in assemblies[a].nodes.indices{if assemblies[a].nodes[n].outputFingerprint==nil,let id=assemblies[a].nodes[n].outputFeatureID,let fingerprint=evaluation.features.first(where:{$0.id==id})?.fingerprint{assemblies[a].nodes[n].outputFingerprint=fingerprint;updated=true}}}
        if updated{model.importedAssemblies=assemblies;evaluation=try await evaluator.evaluate(model,resourcesAt:resources)}
      }
      let evaluationMS=(ProcessInfo.processInfo.systemUptime-evaluationStart)*1000,tessellationStart=ProcessInfo.processInfo.systemUptime
      var components:[CADComponentRepresentation]=[],meshes:[UUID:CADMesh]=[:]
      for id in evaluation.outputOrder {
        guard let shape=evaluation.outputs[id],let report=evaluation.features.first(where:{$0.id==id}) else{throw FormError.invalid("An evaluated CAD output is missing.")}
        let mesh=try await evaluator.mesh(for:evaluation,outputID:id,quality:tessellation),meshHash=CADSceneAdapter.digest(try CADMeshArchive.encode(mesh)),info=shape.info
        meshes[id]=mesh
        // These references describe a private evaluated preview only. Exact
        // asset hashes replace them at commit, before project publication.
        var component=CADComponentRepresentation(id:id,name:report.name,brepAsset:"preview-\(report.fingerprint).brep",brepSHA256:report.fingerprint,meshAsset:"cad-\(meshHash).mesh",meshSHA256:meshHash,minimum:.init(info.minimum.x,info.minimum.y,info.minimum.z),maximum:.init(info.maximum.x,info.maximum.y,info.maximum.z),volumeMM3:info.volumeMM3,valid:info.valid,closed:info.closed,solidCount:info.solids,faceCount:info.faces,edgeCount:info.edges,vertexCount:info.vertices,triangleCount:mesh.triangleCount)
        component.featureFingerprint=report.fingerprint;components.append(component)
      }
      let tessellationMS=(ProcessInfo.processInfo.systemUptime-tessellationStart)*1000,renderStart=ProcessInfo.processInfo.systemUptime
      var representation=CADRepresentation(modelID:model.id,definitionSHA256:evaluation.revisionHash,kernelVersion:CADKernel.version,editability:model.features.contains{$0.operation.source != nil} ? "importedCADBody":"nativeFeatureModel",components:components,meshDeflectionMM:tessellation.linearDeflectionMM)
      representation.resolvedSurfaces=evaluation.surfaces.isEmpty ? nil:evaluation.surfaces
      try representation.validate(for:model)
      var object=ProductObject(name:model.name,recipeID:"cadModel",parameters:[:]);object.id=objectID;object.cadModel=model;object.cadRepresentation=representation
      let display=try CADSceneAdapter.prepare(for:object,meshes:meshes),scene=display.renderables
      let renderMS=(ProcessInfo.processInfo.systemUptime-renderStart)*1000
      try Task.checkCancellation();return .init(definition:model,evaluation:evaluation,representation:representation,stage:workspace,files:sourceFiles,scene:scene,display:display,timings:["source_preparation":(evaluationStart-started)*1000,"evaluation":evaluationMS,"tessellation":tessellationMS,"render_preparation":renderMS,"preview":(ProcessInfo.processInfo.systemUptime-started)*1000])
    }catch{try? fm.removeItem(at:workspace);throw error}
  }
  func cancel(_ job:CADModelReview){job.token=UUID();job.task?.cancel();job.worker?.cancel();cancelEvidence(for:job);job.state="cancelled";discard(job);if review?.id==job.id{review=nil}}
  private func discard(_ job:CADModelReview){if let p=job.prepared{removeStage(p.stage)};job.prepared=nil;job.scene=[]}
  private func removeStage(_ url:URL){Task.detached(priority:.utility){try? FileManager.default.removeItem(at:url)}}
  /// Copying and hashing occur off the UI actor. The final document edit is a single Undo transaction.
  func commit(_ job:CADModelReview)throws {
    guard let store,job.state=="ready",let prepared=job.prepared,matches(job),try CADModelEvaluator.revisionHash(job.definition)==prepared.evaluation.revisionHash,Self.deflection(job.quality)==prepared.representation.meshDeflectionMM else{throw FormError.invalid("CAD preview is not ready or its source project changed. Preview again against the new source.")}
    guard !jobs.values.contains(where:{$0.id != job.id&&$0.state=="publishing"}) else{throw FormError.invalid("Wait for the active CAD publication to finish.")}
    if let target=job.targetObjectID,let project=store.project {try Self.validateFamilySurfaceBindings(project:project,target:target,surfaces:Set(prepared.evaluation.surfaces.map(\.id)))}
    store.finishArtworkEditing();guard matches(job),try CADModelEvaluator.revisionHash(job.definition)==prepared.evaluation.revisionHash,Self.deflection(job.quality)==prepared.representation.meshDeflectionMM else{throw FormError.invalid("Finishing active fields changed the source. Start a fresh CAD review.")}
    job.task?.cancel();cancelEvidence(for:job);job.token=UUID();let assets=store.repository.url(for:job.projectID).appendingPathComponent("Assets"),token=job.token,evaluator=self.evaluator;job.state="publishing";job.issue=nil
    let publicationStart=ProcessInfo.processInfo.systemUptime
    let worker=Task.detached(priority:.userInitiated){() async throws -> (Prepared,[URL]) in
      let durable=try await Self.materialize(prepared,evaluator:evaluator)
      try Task.checkCancellation()
      return(durable,try Self.publish(durable.files,to:assets))
    }
    job.task=Task{[weak self,weak job] in guard let self,let job else{return};var published:[URL]=[];do{
      let publication=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
      let prepared=publication.0;published=publication.1
      guard !Task.isCancelled,job.token==token,self.matches(job),let store=self.store else{throw FormError.invalid("The project changed before exact geometry publication.")}
      var created:UUID?,publishedObjectIDs=Set<UUID>()
      try store.engine.edit(job.targetObjectID==nil ? "Created exact CAD model":"Updated exact CAD model",source:"CAD") {project in
        guard Self.sourceSnapshot(project)==job.source else{throw FormError.invalid("The CAD source revision is stale.")}
        if let id=job.targetObjectID {guard let i=project.objects.firstIndex(where:{$0.id==id}),!project.objects[i].locked else{throw FormError.invalid("The CAD object is missing or locked.")};let design=project.objects[i].designID,linked=project.objects[i].relationship=="variant" || project.objects.contains{$0.designID==design&&$0.relationship=="variant"}
          let family=project.objects.indices.filter{$0==i || linked&&project.objects[$0].designID==design}
          guard family.allSatisfy({!project.objects[$0].locked}) else{throw FormError.invalid("Unlock all linked CAD variants before editing their shared construction.")}
          try Self.validateFamilySurfaceBindings(project:project,target:id,surfaces:Set(prepared.evaluation.surfaces.map(\.id)))
          for member in family{publishedObjectIDs.insert(project.objects[member].id);var representation=prepared.representation;let styles=project.objects[member].cadRepresentation?.components ?? [];for c in representation.components.indices{if let old=styles.first(where:{$0.id==representation.components[c].id}){representation.components[c].materialID=old.materialID;representation.components[c].color=old.color}};project.objects[member].cadModel=prepared.definition;project.objects[member].cadRepresentation=representation}
          project.objects[i].name=prepared.definition.name;created=id}
        else{var object=try project.makeObject(recipeID:"cadModel",name:prepared.definition.name);object.position=try Self.newPosition(for:prepared.representation,in:project);object.cadModel=prepared.definition;object.cadRepresentation=prepared.representation;project.objects.append(object);created=object.id;publishedObjectIDs.insert(object.id)}
        try project.validateModelRepresentations()
      }
      self.invalidateSceneFailures(for:publishedObjectIDs)
      job.timings=prepared.timings;job.timings["publication"]=(ProcessInfo.processInfo.systemUptime-publicationStart)*1000
      job.state="committed";if let created{job.result=["object_id":created.uuidString,"revision":prepared.evaluation.revisionHash];store.select(created)};store.showingHome=false;store.changed();self.discard(job);if self.review?.id==job.id{self.review=nil}
    }catch{let remove=published;Task.detached(priority:.utility){for url in remove{try? FileManager.default.removeItem(at:url)}};guard job.token==token else{return};job.state=error is CancellationError ? "cancelled":"failed";job.issue=error.localizedDescription;job.diagnostic=self.diagnostic(error,job:job,category:"publication")}}
  }
  /// Exact serialization belongs to publication, not every parameter preview.
  /// The evaluator checks that this is still its accepted revision throughout.
  nonisolated static func materialize(_ preview:Prepared,evaluator:CADModelEvaluator)async throws->Prepared {
    if preview.durable{return preview}
    var result=preview
    let started=ProcessInfo.processInfo.systemUptime
    let quality=CADTessellation(linearDeflectionMM:preview.representation.meshDeflectionMM,angularDeflectionRadians:preview.representation.meshDeflectionMM==CADTessellation.preview.linearDeflectionMM ? CADTessellation.preview.angularDeflectionRadians:preview.representation.meshDeflectionMM==CADTessellation.fabrication.linearDeflectionMM ? CADTessellation.fabrication.angularDeflectionRadians:CADTessellation.inspection.angularDeflectionRadians)
    let exact=preview.stage.appendingPathComponent("Exact",isDirectory:true)
    let manifest=try await evaluator.stageSources(preview.evaluation,to:exact,includeSTEP:false,quality:quality)
    for output in manifest.outputs {
      guard let index=result.representation.components.firstIndex(where:{$0.id==output.featureID}),let brepHash=manifest.files[output.brep],let meshHash=manifest.files[output.mesh] else{throw FormError.invalid("Published CAD output disagrees with the evaluated preview.")}
      guard meshHash==result.representation.components[index].meshSHA256 else{throw FormError.invalid("Published CAD tessellation changed after its preview.")}
      let brep="cad-\(brepHash).brep",mesh="cad-\(meshHash).mesh"
      result.files[brep]=exact.appendingPathComponent(output.brep);result.files[mesh]=exact.appendingPathComponent(output.mesh)
      result.representation.components[index].brepAsset=brep;result.representation.components[index].brepSHA256=brepHash
      result.representation.components[index].meshAsset=mesh;result.representation.components[index].meshSHA256=meshHash
    }
    try result.representation.validate(for:result.definition)
    result.timings["serialization"]=(ProcessInfo.processInfo.systemUptime-started)*1000
    result.durable=true;return result
  }
  private nonisolated static func stableID(_ text:String)->UUID {let hex=CADSceneAdapter.digest(Data(text.utf8)),pieces=[hex.prefix(8),hex.dropFirst(8).prefix(4),hex.dropFirst(12).prefix(4),hex.dropFirst(16).prefix(4),hex.dropFirst(20).prefix(12)];return UUID(uuidString:pieces.map(String.init).joined(separator:"-"))!}
  private nonisolated static func boundedName(_ text:String)->String {var result="";for c in text{guard result.utf8.count+String(c).utf8.count<=256 else{break};result.append(c)};return result.isEmpty ? "Exact component":result}
  private nonisolated static func deflection(_ quality:String)->Double?{switch quality{case "preview":return CADTessellation.preview.linearDeflectionMM;case "inspection":return CADTessellation.inspection.linearDeflectionMM;case "fabrication":return CADTessellation.fabrication.linearDeflectionMM;default:return nil}}
  private nonisolated static func newPosition(for representation:CADRepresentation,in project:Project)throws->Vector3 {
    let objects=project.objects.filter{$0.hasTablePresentation};guard !objects.isEmpty else{return .init()}
    let right=objects.map{object->Double in
      guard let r=object.cadRepresentation else{return object.position.x+object.footprintWidth/2}
      let angle=object.rotation * Double.pi/180,c=cos(angle),s=sin(angle)
      return object.position.x+[r.minimum.x,r.maximum.x].flatMap{x in [r.minimum.z,r.maximum.z].map{c*x+s*$0}}.max()!
    }.max() ?? 0
    let x=right-representation.minimum.x+55;guard x.isFinite,abs(x)<=1e7 else{throw FormError.invalid("New CAD placement exceeds the physical workspace bounds.")};return .init(x,0,0)
  }
  nonisolated static func writeExclusive(_ data:Data,to destination:URL)throws {
    let stage=destination.deletingLastPathComponent().appendingPathComponent(".lab-cad-render-"+UUID().uuidString+".png"),fm=FileManager.default
    defer{try? fm.removeItem(at:stage)};try Task.checkCancellation();try data.write(to:stage,options:.withoutOverwriting);try Task.checkCancellation();try fm.moveItem(at:stage,to:destination)
  }
  nonisolated static func publish(_ files:[String:URL],to assets:URL)throws->[URL] {
    let fm=FileManager.default;try fm.createDirectory(at:assets,withIntermediateDirectories:true);var created:[URL]=[]
    do{for (name,url) in files.sorted(by:{$0.key<$1.key}){try Task.checkCancellation();let data=try Data(contentsOf:url),digest=CADSceneAdapter.digest(data),destination=assets.appendingPathComponent(name)
      guard !name.contains("/"),name.contains(digest) else{throw FormError.invalid("An immutable CAD asset name disagrees with its content.")}
      if fm.fileExists(atPath:destination.path){_ = try CADSceneAdapter.verifiedAsset(name,sha256:digest,assets:assets,maximumBytes:512*1024*1024)}else{try data.write(to:destination,options:.withoutOverwriting);created.append(destination)}
    };try Task.checkCancellation();return created}catch{for url in created{try? fm.removeItem(at:url)};throw error}
  }
  private nonisolated static func sceneKey(_ object:ProductObject)->String? {
    guard let r=object.cadRepresentation else{return nil}
    let resources=r.components.map{"\($0.id):\($0.brepAsset):\($0.brepSHA256):\($0.meshAsset):\($0.meshSHA256):\($0.featureFingerprint ?? "")"}.joined(separator:"|")
    return "\(object.id):\(r.definitionSHA256):\(r.kernelVersion):\(r.meshDeflectionMM):\(resources)"
  }
  private func loadIsCurrent(objectID:UUID,key:String,token:UUID,projectEpoch:UUID)->Bool {
    guard epoch==projectEpoch,loadTokens[key]==token,let current=store?.project?.objects.first(where:{$0.id==objectID}) else{return false}
    return Self.sceneKey(current)==key
  }
  private func invalidateSceneFailures(for ids:Set<UUID>){
    for id in ids{failures.removeValue(forKey:id);failureKeys.removeValue(forKey:id)}
    for key in Array(loads.keys) where ids.contains(where:{key.hasPrefix($0.uuidString+":")}){loads.removeValue(forKey:key)?.cancel();loadWorkers.removeValue(forKey:key)?.cancel();loadTokens.removeValue(forKey:key)}
  }
  func resolvedScene(for object:ProductObject,assets:URL)->[SceneRenderablePayload]? {
    guard let key=Self.sceneKey(object) else{return nil}
    if let prepared=scenes[key]{
      guard let project=store?.project else{return CADSceneAdapter.renderables(prepared,for:object,materials:store?.materials ?? FormCore.Material.presets)}
      do{let result=try CADSurfaceAppearance.apply(prepared,object:object,project:project,assets:assets,materials:store?.materials ?? FormCore.Material.presets);failures.removeValue(forKey:object.id);failureKeys.removeValue(forKey:object.id);return result}
      catch{failures[object.id]=error.localizedDescription;failureKeys[object.id]=key;return CADSceneAdapter.renderables(prepared,for:object,materials:store?.materials ?? FormCore.Material.presets)}
    }
    guard loads[key]==nil,failureKeys[object.id] != key else{return nil}
    let projectEpoch=epoch,token=UUID(),worker=Task.detached(priority:.userInitiated){try CADSceneAdapter.prepare(for:object,assets:assets)};loadWorkers[key]=worker;loadTokens[key]=token
    loads[key]=Task{[weak self] in
      guard let self else{return}
      defer{if self.epoch==projectEpoch,self.loadTokens[key]==token{self.loads.removeValue(forKey:key);self.loadWorkers.removeValue(forKey:key);self.loadTokens.removeValue(forKey:key)}}
      do{
        let prepared=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
        if let checkpoint=self.sceneLoadCheckpoint{await checkpoint(object)}
        guard !Task.isCancelled,self.loadIsCurrent(objectID:object.id,key:key,token:token,projectEpoch:projectEpoch) else{return}
        self.failures.removeValue(forKey:object.id);self.failureKeys.removeValue(forKey:object.id);self.remember(prepared,key:key);self.store?.changed(save:false)
      }catch{
        if let checkpoint=self.sceneLoadCheckpoint{await checkpoint(object)}
        guard !Task.isCancelled,self.loadIsCurrent(objectID:object.id,key:key,token:token,projectEpoch:projectEpoch) else{return}
        self.failures[object.id]=error.localizedDescription;self.failureKeys[object.id]=key;self.store?.changed(save:false)
      }
    };return nil
  }
  private func remember(_ value:CADSceneAdapter.Prepared,key:String){while sceneBytes+value.approximateBytes>256*1024*1024,let first=sceneOrder.first{sceneOrder.removeFirst();if let old=scenes.removeValue(forKey:first){sceneBytes-=old.approximateBytes}};scenes[key]=value;sceneOrder.append(key);sceneBytes+=value.approximateBytes}
  func issue(for object:ProductObject)->String?{guard let key=Self.sceneKey(object),failureKeys[object.id]==key else{return nil};return failures[object.id]}
  func retry(_ object:ProductObject,assets:URL){invalidateSceneFailures(for:[object.id]);_ = resolvedScene(for:object,assets:assets)}
  func face(for pick:ScenePick,object:ProductObject)->[String:Any]? {guard let r=object.cadRepresentation,let body=r.components.first(where:{pick.componentID.hasSuffix($0.id.uuidString)}),let key=Self.sceneKey(object),let prepared=scenes[key],let faces=prepared.triangleFaces[pick.componentID+"|"+(pick.partID ?? "")] ?? (pick.partID==nil ? prepared.triangleFaces[pick.componentID]:nil),faces.indices.contains(pick.triangle) else{return nil};return ["output_id":body.id.uuidString,"face_index":Int(faces[pick.triangle]),"model_revision":r.definitionSHA256,"ordinal_scope":"Inspect feature topology for its input fingerprint before selecting edges or faces."]}
  func call(_ name:String,_ args:[String:Any])throws->Any {
    if let raw=args["command"],!(raw is String){throw FormError.invalid("command must be a string.")}
    let command=args["command"] as? String ?? "capabilities"
    if ["patch","evidence","evidence_status","evidence_cancel","validate","validation_status"].contains(command){return try loopCall(command,args)}
    let common:Set<String>=["command"],modelKeys:Set<String>=["object_id","job_id","definition","template"],perCommand:[String:Set<String>]=[
      "capabilities":[],"templates":[],"plan":modelKeys,"inspect":modelKeys,"status":["job_id"],"cancel":["job_id"],"commit":["job_id"],
      "create":modelKeys.union(["quality","evidence"]),"evaluate":modelKeys.union(["quality","evidence"]),"parameter":modelKeys.union(["quality","values","name","value","evidence"]),"feature":modelKeys.union(["quality","action","feature","feature_id","operation","suppressed","outputs","output","evidence"]),"import_step":["path","name","source_up_axis","quality"],"topology":["job_id","feature_id"],"clearance":["job_id","first_output_id","second_output_id"],"export":["job_id","output_id","path","format"],"render":["job_id","path","view","width","height","transparent"]]
    guard let allowed=perCommand[command],Set(args.keys).isSubset(of:allowed.union(common)) else{throw FormError.invalid("Unknown CAD command or unsupported argument fields.")}
    if args["job_id"] != nil&&(args["object_id"] != nil||args["definition"] != nil||args["template"] != nil) || args["template"] != nil&&(args["object_id"] != nil||args["definition"] != nil){throw FormError.invalid("Choose one CAD model source: definition, object, active job or template.")}
    for key in ["output","suppressed","transparent"] where args[key] != nil{guard let n=args[key] as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{throw FormError.invalid("\(key) must be a boolean.")}}
    for key in ["object_id","job_id","feature_id","output_id","first_output_id","second_output_id"] where args[key] != nil{guard let raw=args[key] as? String,UUID(uuidString:raw) != nil else{throw FormError.invalid("Provide a valid \(key).")}}
    for key in ["template","quality","name","source_up_axis","path","format","action","view"] where args[key] != nil{guard args[key] is String else{throw FormError.invalid("\(key) must be a string.")}}
    if let quality=args["quality"] as? String{guard ["preview","inspection","fabrication"].contains(quality) else{throw FormError.invalid("Choose preview, inspection or fabrication quality.")}}
    func numeric(_ raw:Any)throws->Double{guard let value=raw as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID(),value.doubleValue.isFinite,abs(value.doubleValue)<=1e7 else{throw FormError.invalid("CAD parameter values must be finite numbers, not booleans or strings.")};return value.doubleValue}
    func id(_ key:String)throws->UUID {guard let raw=args[key] as? String,let value=UUID(uuidString:raw) else{throw FormError.invalid("Provide a valid \(key).")} ;return value}
    func job()throws->CADModelReview {let value=try id("job_id");guard let job=jobs[value] else{throw FormError.missing("CAD job is unavailable.")};return job}
    func model()throws->(CADModelDefinition,UUID?) {
      let target=(args["object_id"] as? String).flatMap(UUID.init(uuidString:))
      if args["object_id"] != nil,target==nil{throw FormError.invalid("Invalid object_id.")}
      if let raw=args["definition"]{try Self.validateDefinitionJSON(raw);let data=try JSONSerialization.data(withJSONObject:raw);guard data.count<=Self.maximumDefinitionSubmissionBytes else{throw FormError.invalid("Complete CAD definition submission exceeds 4 MiB. Use bounded atomic patches for larger graphs within the existing scalar/feature limits.")};return(try JSONDecoder().decode(CADModelDefinition.self,from:data),target)}
      if let target{guard let d=store?.project?.objects.first(where:{$0.id==target})?.cadModel else{throw FormError.missing("Choose an exact CAD object.")};return(d,target)}
      if let raw=args["job_id"] as? String,let uuid=UUID(uuidString:raw){guard let job=jobs[uuid],!["cancelled","committed"].contains(job.state) else{throw FormError.missing("Choose an active CAD preview job.")};return(job.definition,job.targetObjectID)}
      return(try CADModelExamples.make(args["template"] as? String ?? "enclosure"),nil)
    }
    switch command {
    case "capabilities":return ["kernel":"OCCT \(CADKernel.version)","kernel_version":CADKernel.version,"units":"mm","up_axis":"Y","commands":["capabilities","templates","plan","create","evaluate","parameter","feature","patch","status","commit","cancel","inspect","topology","export","import_step","clearance","render","evidence","evidence_status","evidence_cancel","validate","validation_status"],"feature_kinds":CADFeatureKind.allCases.map(\.rawValue),"publication":"Private in-memory previews retain exact geometry. Commit serializes and publishes one guarded Undo transaction.","patch_actions":["parameters","append","replace","remove","suppress","outputs","requirements","output_requirements","surfaces"],"evidence_kinds":["summary","topology","clearance","render","export"],"limits":["features":256,"definition_submission_bytes":Self.maximumDefinitionSubmissionBytes,"source_asset_bytes":256*1024*1024,"source_bytes":256*1024*1024,"scalar_expressions":32768,"mesh_triangles":2_000_000],"limit_notes":"source_bytes is the legacy alias for source_asset_bytes. Full-definition submissions and exact import assets have separate bounds; atomic patches retain the same graph scalar/feature budgets.","import_editability":"Exact STEP components with hierarchy, names, placements and source colors. Original feature history is unavailable."] as [String:Any]
    case "templates":return try CADModelExamples.names.map{try jsonObject(CADModelExamples.make($0))}
    case "plan":let (d,_)=try model();let order=try d.validatedOrder();return ["definition":try jsonObject(d),"revision":try CADModelEvaluator.revisionHash(d),"order":order.map{$0.id.uuidString},"assumptions":d.assumptions,"unresolved_measurements":d.unresolvedMeasurements]
    case "create","evaluate":let (d,target)=try model();let requests=try suppliedEvidence(args);let j=try begin(d,target:target);if let quality=args["quality"] as? String{j.quality=quality};j.pendingEvidence=requests;preview(j);return status(j)
    case "parameter":var (d,target)=try model();if let raw=args["values"]{guard args["name"]==nil,args["value"]==nil,let values=raw as? [String:Any],!values.isEmpty else{throw FormError.invalid("Provide a nonempty values map or a single name/value pair.")};for (name,value) in values{try d.setParameter(name,value:numeric(value))}}else{guard let parameter=args["name"] as? String,let raw=args["value"] else{throw FormError.invalid("Provide parameter name and numeric value, or a values map.")};try d.setParameter(parameter,value:numeric(raw))};let requests=try suppliedEvidence(args);let j=try begin(d,target:target);if let quality=args["quality"] as? String{j.quality=quality};j.pendingEvidence=requests;preview(j);return status(j)
    case "feature":var (d,target)=try model();let action=args["action"] as? String ?? "replace"
      if action=="append"{guard let raw=args["feature"] else{throw FormError.invalid("Provide a typed feature node.")};try Self.validateFeatureJSON(raw);let node=try JSONDecoder().decode(CADFeatureNode.self,from:JSONSerialization.data(withJSONObject:raw));d.features.append(node);if args["output"] as? Bool==true{d.outputs=[node.id]}}
      else {let fid=try id("feature_id");guard let index=d.features.firstIndex(where:{$0.id==fid}) else{throw FormError.missing("Feature is unavailable.")}
        if action=="suppress"{guard let value=args["suppressed"] as? Bool else{throw FormError.invalid("Provide suppressed:true or false.")};d.features[index].suppressed=value}
        else if action=="remove"{d.features.remove(at:index);if let raw=args["outputs"] as? [String]{let values=raw.compactMap(UUID.init(uuidString:));guard values.count==raw.count else{throw FormError.invalid("Invalid output IDs.")};d.outputs=values}}
        else if action=="replace"{guard let raw=args["operation"] else{throw FormError.invalid("Provide the replacement typed operation.")};try Self.validateOperationJSON(raw);d.features[index].operation=try JSONDecoder().decode(CADFeatureOperation.self,from:JSONSerialization.data(withJSONObject:raw))}
        else{throw FormError.invalid("Feature action must be append, replace, suppress or remove.")}
      };d.revision+=1;let requests=try suppliedEvidence(args);let j=try begin(d,target:target);if let quality=args["quality"] as? String{j.quality=quality};j.pendingEvidence=requests;preview(j);return status(j)
    case "status":return status(try job())
    case "commit":let j=try job();try commit(j);return status(j)
    case "cancel":let j=try job();cancel(j);return status(j)
    case "inspect":let(d,target)=try model();var result:[String:Any]=["definition":try jsonObject(d),"revision":try CADModelEvaluator.revisionHash(d),"kernel_version":CADKernel.version,"editability":d.features.contains{$0.operation.source != nil} ? "importedCADBody":"nativeFeatureModel"]
      if let target,let r=store?.project?.objects.first(where:{$0.id==target})?.cadRepresentation{result["representation"]=try jsonObject(r);result["numeric_metadata"]=Self.numericMetadataProvenance(r,saved:true)};return result
    case "import_step":guard let path=args["path"] as? String,path.hasPrefix("/") else{throw FormError.invalid("Provide an absolute local STEP or BRep path.")};let j=try importReview(url:URL(fileURLWithPath:path),name:args["name"] as? String,sourceUpAxis:args["source_up_axis"] as? String ?? "y");return status(j)
    case "topology","clearance","render","export":
      let j=try job();var request=args;request.removeValue(forKey:"command");request.removeValue(forKey:"job_id");request["kind"]=command
      let operation=try startEvidence(j,requests:[request],legacy:true)
      return ["job_id":j.id.uuidString,"request_id":operation.id.uuidString,command=="render" ? "render":command=="export" ? "export":"inspection":"pending"]
    default:throw FormError.invalid("Unknown CAD command '\(command)'.")
    }
  }
  func status(_ job:CADModelReview)->[String:Any] {
    var result:[String:Any]=["job_id":job.id.uuidString,"state":job.state,"model_id":job.definition.id.uuidString,"kernel_version":CADKernel.version,"definition_revision":job.definition.revision,"draft_revision":(try? CADModelEvaluator.revisionHash(job.definition)) as Any? ?? NSNull(),"result":job.result,"timings_ms":job.timings,"evidence":evidenceRequests.values.filter{$0.jobID==job.id}.map{["request_id":$0.id.uuidString,"revision":$0.revision,"state":$0.state,"elapsed_ms":$0.elapsedMS] as [String:Any]}]
    if let issue=job.issue{result["error"]=issue}
    if let diagnostic=job.diagnostic{result["diagnostic"]=diagnostic}
    result["surface_artwork_issues"]=try? jsonObject(surfacePlacementIssues(job))
    if let p=job.prepared{result["revision"]=p.evaluation.revisionHash;result["representation"]=try? jsonObject(p.representation);result["durable_assets"]=p.durable;result["rebuilt_features"]=p.evaluation.rebuiltFeatureIDs.map(\.uuidString);result["surfaces"]=try? jsonObject(p.evaluation.surfaces);result["surface_issues"]=try? jsonObject(p.evaluation.surfaceIssues);result["features"]=p.evaluation.features.map{["feature_id":$0.id.uuidString,"name":$0.name,"operation":$0.kind.rawValue,"from_cache":$0.fromCache,"duration_ms":$0.durationMS] as [String:Any]}}
    if let p=job.prepared{result["numeric_metadata"]=Self.numericMetadataProvenance(p.representation,saved:false)}
    if let id=job.targetObjectID,let saved=job.source.objects.first(where:{$0.id==id})?.cadRepresentation{result["saved_numeric_metadata"]=Self.numericMetadataProvenance(saved,saved:true)}
    return result
  }
  nonisolated static func numericMetadataProvenance(_ representation:CADRepresentation,saved:Bool)->[String:Any] {
    let sameBuild=representation.kernelVersion==CADKernel.version
    return ["recorded_kernel_version":representation.kernelVersion,"current_kernel_version":CADKernel.version,
      "source":saved ? "saved_representation":"evaluated_result","state":sameBuild ? "current_kernel_build":"other_kernel_build",
      "recomputed_on_load":false,"reevaluate_to_refresh":!sameBuild,
      "refresh_action":"Preview/evaluate the source, inspect the result, then commit to replace saved numeric metadata in one Undo transaction."]
  }
  func surfacePlacementIssues(_ job:CADModelReview)->[PhysicalSurfaceArtworkPlacementIssue] {
    guard let id=job.targetObjectID else{return []}
    return Self.linkedCADFamily(project:job.source,target:id).flatMap{job.source.physicalSurfaceArtworkPlacementIssues(for:$0,surfaces:job.prepared?.evaluation.surfaces)}
  }
  private static func linkedCADFamily(project:Project,target:UUID)->[ProductObject] {
    guard let object=project.objects.first(where:{$0.id==target}) else{return []}
    let linked=object.relationship=="variant" || project.objects.contains{$0.designID==object.designID&&$0.relationship=="variant"}
    return project.objects.filter{$0.id==target || linked&&$0.designID==object.designID}
  }
  private static func validateFamilySurfaceBindings(project:Project,target:UUID,surfaces:Set<String>)throws {
    let missing=linkedCADFamily(project:project,target:target).flatMap{object in
      (object.surfaceArtworkBindings ?? []).filter{!surfaces.contains($0.surfaceID)}.map{object.id.uuidString+"/"+$0.surfaceID}
    }
    guard missing.isEmpty else{throw FormError.invalid("Resolve or explicitly unbind the affected artwork surfaces before applying this model (objectID/surfaceID): "+missing.joined(separator:", "))}
  }
  private nonisolated static func object(_ raw:Any,keys:Set<String>,label:String)throws->[String:Any] {
    guard let value=raw as? [String:Any],Set(value.keys).isSubset(of:keys) else{throw FormError.invalid("Unsupported fields in \(label).")};return value
  }
  private nonisolated static func validateDefinitionJSON(_ raw:Any)throws {
    let value=try object(raw,keys:["id","version","revision","name","parameters","features","outputs","assumptions","unresolvedMeasurements","importedAssemblies","requirements","outputRequirements","surfaces"],label:"CAD definition")
    if let raw=value["surfaces"]{guard let surfaces=raw as? [[String:Any]] else{throw FormError.invalid("CAD surfaces must be an array.")};for surface in surfaces{try validateSurfaceJSON(surface)}}
    for key in ["requirements","outputRequirements"]{if let raw=value[key]{guard let requirements=raw as? [[String:Any]] else{throw FormError.invalid("CAD requirements must be an array.")};for requirement in requirements{try validateRequirementJSON(requirement,output:key=="outputRequirements")}}}
    if let parameters=value["parameters"] as? [Any]{for p in parameters{_ = try object(p,keys:["name","value","minimum","maximum","unit"],label:"CAD parameter")}}
    if let features=value["features"] as? [Any]{for f in features{try validateFeatureJSON(f)}}
    if let assemblies=value["importedAssemblies"] as? [Any]{for raw in assemblies{let assembly=try object(raw,keys:["source","kernelVersion","sourceUpAxis","nodes"],label:"STEP assembly metadata");if let source=assembly["source"]{_ = try object(source,keys:["path","sha256","partPath"],label:"STEP source")};if let nodes=assembly["nodes"] as? [Any]{for raw in nodes{let node=try object(raw,keys:["path","parentPath","definitionKey","name","assembly","localTransformMM","worldTransformMM","linearRGBA","faceColors","outputFeatureID","outputFingerprint"],label:"STEP occurrence metadata");if let colors=node["faceColors"] as? [Any]{for color in colors{_ = try object(color,keys:["faceIndex","linearRGBA"],label:"STEP face color")}}}}}}

  }
  nonisolated static func validateRequirementJSON(_ raw:Any,output:Bool)throws {
    let fields:Set<String>=output ? ["id","outputID","otherOutputID","metric","relation","value","message","tolerance"]:["id","lhs","relation","rhs","message","tolerance"]
    _ = try object(raw,keys:fields,label:"CAD requirement")
  }
  nonisolated static func validateSurfaceJSON(_ raw:Any)throws {
    let value=try object(raw,keys:["id","name","outputFeatureID","selection","origin","uAxis","vAxis","width","height","boundary"],label:"CAD surface")
    for key in ["origin","uAxis","vAxis"]{if let p=value[key]{_ = try object(p,keys:["x","y","z"],label:"CAD surface frame")}}
    if let raw=value["boundary"]{guard let points=raw as? [[String:Any]] else{throw FormError.invalid("CAD surface boundary must be points.")};for p in points{_ = try object(p,keys:["x","y"],label:"CAD surface boundary")}}
    if let selection=value["selection"]{try validateOperationJSON(["kind":"shell","values":["thickness":1],"selection":selection])}
  }
  nonisolated static func validateFeatureJSON(_ raw:Any)throws {
    let value=try object(raw,keys:["id","name","operation","suppressed"],label:"CAD feature")
    if let operation=value["operation"]{try validateOperationJSON(operation)}
  }
  nonisolated static func validateOperationJSON(_ raw:Any)throws {
    let value=try object(raw,keys:["kind","inputs","values","points","holes","curves","plane","direction","origin","vector","path","matrix","selection","source","ruled"],label:"CAD operation")
    func point(_ p:Any,_ dimensions:Set<String>)throws{_ = try object(p,keys:dimensions,label:"CAD point")}
    if let points=value["points"] as? [Any]{for p in points{try point(p,["x","y"])}}
    if let holes=value["holes"] as? [[Any]]{for ring in holes{for p in ring{try point(p,["x","y"])}}}
    if let path=value["path"] as? [Any]{for p in path{try point(p,["x","y","z"])}}
    for key in ["origin","vector","direction"]{if let p=value[key]{try point(p,["x","y","z"])}}
    if let raw=value["plane"]{let plane=try object(raw,keys:["origin","u","v"],label:"CAD plane");for p in plane.values{try point(p,["x","y","z"])}}
    if let curves=value["curves"] as? [Any]{for raw in curves{let curve=try object(raw,keys:["kind","start","control1","control2","end"],label:"CAD curve");for key in ["start","control1","control2","end"]{if let p=curve[key],!(p is NSNull){try point(p,["x","y"])}}}}
    if let source=value["source"]{_ = try object(source,keys:["path","sha256","partPath"],label:"CAD source")}
    if let raw=value["selection"]{let selection=try object(raw,keys:["allEdges","edges","faces","faceAtMaximum","faceAtMinimum","facesAtExtrema","faceAtCenter","straightEdgesAtMaximum","straightEdgesAtMinimum"],label:"CAD topology selection");guard selection.count==1 else{throw FormError.invalid("Choose one typed CAD topology selection.")};for (key,payload) in selection{let fields:Set<String>=key=="allEdges" ? []:key=="edges" || key=="faces" ? ["revisionHash","indices"]:key=="faceAtCenter" ? ["point","tolerance"]:["axis"];let values=try object(payload,keys:fields,label:"CAD selection fields");if let p=values["point"]{try point(p,["x","y","z"])}}}
  }

}

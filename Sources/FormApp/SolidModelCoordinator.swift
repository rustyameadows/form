import Foundation
import FormCore
import FormGeometry

/// One process-wide bound, shared by editing, captures and print prewarming.
/// A cancelled queued request releases its continuation without starting CPU work.
actor SolidSurfaceWorkPool {
  static let shared=SolidSurfaceWorkPool()
  private var active=0
  private struct Waiter {let id:UUID;let continuation:CheckedContinuation<Bool,Never>}
  private var waiters:[Waiter]=[]
  func acquire(_ id:UUID)async throws {
    try Task.checkCancellation()
    if active<2 {active+=1;return}
    guard waiters.count<128 else{throw FormError.invalid("Too many solid builds are waiting. Finish or cancel an earlier request.")}
    let granted=await withTaskCancellationHandler(operation:{await withCheckedContinuation{waiters.append(.init(id:id,continuation:$0))}},onCancel:{Task{await self.cancel(id)}})
    guard granted else{throw CancellationError()}
    if Task.isCancelled {release();throw CancellationError()}
  }
  private func cancel(_ id:UUID) {if let i=waiters.firstIndex(where:{$0.id==id}) {waiters.remove(at:i).continuation.resume(returning:false)}}
  func release() {if waiters.isEmpty {active-=1}else{waiters.removeFirst().continuation.resume(returning:true)}}
  static func build(recipe:Recipe,parameters:[String:Double],preview:Bool,cancellation:OrganicMeshCancellation)async throws->SolidSurface {
    let id=UUID();try await shared.acquire(id)
    do {
      try Task.checkCancellation();if cancellation.isCancelled {throw CancellationError()}
      try recipe.validate(parameters)
      guard let definition=recipe.solid else{throw FormError.invalid("The solid source is no longer available.")}
      let result=try SolidSurfaceBuilder.build(definition,parameters:parameters,useEditingPreview:preview,cancellation:cancellation)
      await shared.release();return result
    } catch {await shared.release();throw error}
  }
}

/// Transient native controls and derived surfaces. Only a completed authoritative
/// native edit changes the existing Recipe parameters; meshes never enter Project.
@MainActor final class SolidModelCoordinator {
  typealias Builder=@Sendable (Recipe,[String:Double],Bool,OrganicMeshCancellation)async throws->SolidSurface
  struct Display {let surface:SolidSurface;let revision:String;let parameters:[String:Double];let recipe:Recipe}
  private struct ReleasedIntent {let token:UUID;let parameters:[String:Double]}
  private struct Draft {
    let token:UUID,projectID:UUID,objectID:UUID,recipe:Recipe
    var baseline:[String:Double]
    var parameters:[String:Double]
    var editing:Bool
    var predecessors:[ReleasedIntent]=[]
  }
  private struct Request {
    let token:UUID,epoch:UUID,projectID:UUID,objectID:UUID,recipe:Recipe,parameters:[String:Double],key:String
    let preview:Bool,commit:Bool,draftToken:UUID?,order:Int
  }
  private struct Entry {
    var desired:Request?
    var display:Display?
    var full:Display?
    var issue:String?
    var access=0
  }
  private struct Running {let request:Request;let task:Task<SolidSurface,Error>;let cancellation:OrganicMeshCancellation}
  private weak var store:StudioStore?
  private let builder:Builder
  private let maximumBytes:Int,maximumObjects:Int
  private var epoch=UUID(),projectID:UUID?
  private var entries:[UUID:Entry]=[:],drafts:[UUID:Draft]=[:],pending:[UUID:Request]=[:],running:[UUID:Running]=[:]
  private var clock=0
  private(set) var completedBuilds=0,discardedBuilds=0,maximumActiveBuilds=0
  init(store:StudioStore,builder:@escaping Builder={recipe,parameters,preview,cancellation in
    try await SolidSurfaceWorkPool.build(recipe:recipe,parameters:parameters,preview:preview,cancellation:cancellation)
  },maximumBytes:Int=256*1024*1024,maximumObjects:Int=128) {
    self.store=store;self.builder=builder;self.maximumBytes=max(1,maximumBytes);self.maximumObjects=max(1,maximumObjects)
  }
  var activeBuilds:Int {running.count}
  var pendingBuilds:Int {pending.count}
  var retainedBytes:Int {
    var seen=Set<UUID>(),count=0
    for entry in entries.values {for display in [entry.display,entry.full].compactMap({$0}) where seen.insert(display.surface.storageID).inserted {count+=display.surface.byteCount}}
    return count
  }
  func issue(for id:UUID)->String? {entries[id]?.issue}
  func hasDraft(_ id:UUID)->Bool {drafts[id] != nil}
  func value(for object:ProductObject,parameter:String)->Double {drafts[object.id]?.parameters[parameter] ?? object[parameter]}
  func reset() {
    epoch=UUID();projectID=nil;entries=[:];drafts=[:];pending=[:]
    for work in running.values {work.cancellation.cancel();work.task.cancel()}
    // Running requests retain their slots until they actually stop. Switching
    // projects cannot accumulate abandoned native workers outside the bound.
  }
  func synchronize(_ project:Project?) {
    guard let project else{reset();return}
    if projectID != project.id {reset();projectID=project.id}
    let sources=project.objects.filter{project.recipe($0.recipeID)?.solid != nil}
    let ids=Set(sources.map(\.id))
    for id in Array(entries.keys) where !ids.contains(id) {cancel(id);entries[id]=nil;drafts[id]=nil}
    for object in sources {
      guard let recipe=project.recipe(object.recipeID) else{continue}
      if let draft=drafts[object.id],draft.recipe != recipe || draft.baseline != object.parameters {
        cancel(object.id);drafts[object.id]=nil
      }
      guard drafts[object.id]==nil else{continue}
      enqueue(projectID:project.id,objectID:object.id,recipe:recipe,parameters:object.parameters,preview:false,draftToken:nil)
    }
    pump()
  }
  func display(for object:ProductObject,project:Project,needsSurface:Bool=false)->Display? {
    if projectID != project.id {synchronize(project)}
    if entries[object.id]==nil {synchronize(project)}
    if needsSurface,entries[object.id]?.display==nil,!pending.keys.contains(object.id),!running.values.contains(where:{$0.request.objectID==object.id}) {
      entries[object.id]?.desired=nil;synchronize(project)
    }
    clock+=1;entries[object.id]?.access=clock
    return entries[object.id]?.display
  }
  @discardableResult func beginGesture(_ object:ProductObject)->UUID? {
    guard let project=store?.project,let current=project.objects.first(where:{$0.id==object.id}),!current.locked,
      let recipe=project.recipe(current.recipeID),recipe.solid != nil else{return nil}
    synchronize(project)
    let previous=drafts[object.id]
    var predecessors=previous?.predecessors ?? []
    if let previous,previous.parameters != previous.baseline || !previous.predecessors.isEmpty {
      predecessors.append(.init(token:previous.token,parameters:previous.parameters))
      // Bound rapid pending gesture history while keeping every accumulated
      // parameter intent in its later complete parameter dictionary.
      if predecessors.count>16 {predecessors.removeFirst(predecessors.count-16)}
    }
    cancel(object.id)
    let token=UUID();drafts[object.id] = .init(token:token,projectID:project.id,objectID:object.id,recipe:recipe,baseline:current.parameters,parameters:previous?.parameters ?? current.parameters,editing:true,predecessors:predecessors)
    if entries[object.id]?.full==nil {
      entries[object.id]?.desired=nil
      enqueue(projectID:project.id,objectID:object.id,recipe:recipe,parameters:current.parameters,preview:false,draftToken:nil);pump()
    }
    return token
  }
  func set(_ object:ProductObject,parameters:[String:Double]) {
    guard let project=store?.project,let current=project.objects.first(where:{$0.id==object.id}),!current.locked,
      let recipe=project.recipe(current.recipeID),recipe.solid != nil else{return}
    if projectID != project.id {synchronize(project)}
    if drafts[object.id]==nil {
      drafts[object.id] = .init(token:UUID(),projectID:project.id,objectID:object.id,recipe:recipe,baseline:current.parameters,parameters:current.parameters,editing:false)
    }
    guard var draft=drafts[object.id],draft.recipe==recipe,draft.baseline==current.parameters else{cancelDraft(object.id);return}
    for (name,value) in parameters {
      guard let parameter=recipe.parameters.first(where:{$0.id==name}),value.isFinite,(parameter.minimum...parameter.maximum).contains(value) else{
        store?.error="Enter a finite value within this parameter's supported range.";return
      }
      draft.parameters[name]=value
    }
    drafts[object.id]=draft
    if draft.editing,entries[object.id]?.full==nil {
      enqueue(projectID:project.id,objectID:object.id,recipe:recipe,parameters:draft.baseline,preview:false,draftToken:nil)
    }else{
      enqueue(projectID:project.id,objectID:object.id,recipe:recipe,parameters:draft.parameters,
        preview:draft.editing && recipe.solid?.previewNodes != nil,draftToken:draft.token)
    }
    store?.objectWillChange.send();pump()
  }
  func endGesture(_ token:UUID) {
    guard let id=drafts.first(where:{$0.value.token==token})?.key,var draft=drafts[id] else{return}
    draft.editing=false;drafts[id]=draft
    if draft.parameters==draft.baseline,draft.predecessors.isEmpty {cancelDraft(id,restoreReleased:false);return}
    enqueueReleased(draft);pump()
  }
  private func enqueueReleased(_ draft:Draft) {
    enqueue(projectID:draft.projectID,objectID:draft.objectID,recipe:draft.recipe,parameters:draft.predecessors.first?.parameters ?? draft.parameters,preview:false,draftToken:draft.token)
  }
  func cancelDraft(_ id:UUID,restoreReleased:Bool=true) {
    guard let draft=drafts.removeValue(forKey:id) else{return}
    cancel(id)
    let full=entries[id]?.full;entries[id]?.display=full
    entries[id]?.desired=nil;entries[id]?.issue=nil
    if restoreReleased,let previous=draft.predecessors.last {
      let restored=Draft(token:previous.token,projectID:draft.projectID,objectID:id,recipe:draft.recipe,baseline:draft.baseline,parameters:previous.parameters,editing:false,predecessors:Array(draft.predecessors.dropLast()))
      drafts[id]=restored;enqueueReleased(restored);pump()
    }else if let project=store?.project {synchronize(project)}
    notify()
  }
  func cancelGesture(_ token:UUID) {
    guard let id=drafts.first(where:{$0.value.token==token})?.key else{return}
    cancelDraft(id)
  }
  func cancelDrafts() {for id in Array(drafts.keys) {cancelDraft(id,restoreReleased:false)}}
  private func cancel(_ id:UUID) {
    pending[id]=nil
    for work in running.values where work.request.objectID==id {work.cancellation.cancel();work.task.cancel()}
  }
  private func enqueue(projectID:UUID,objectID:UUID,recipe:Recipe,parameters:[String:Double],preview:Bool,draftToken:UUID?) {
    guard let definition=recipe.solid else{return}
    do {
      let key=try SolidRecipeGeometry.sourceKey(definition,parameters:parameters,isEditingPreview:preview)
      let commit=draftToken != nil && drafts[objectID]?.editing==false
      if let desired=entries[objectID]?.desired,desired.key==key,desired.recipe==recipe,desired.commit==commit,desired.draftToken==draftToken {return}
      if let full=entries[objectID]?.full,full.revision==key,full.recipe==recipe,!preview,draftToken==nil {return}
      guard entries[objectID] != nil || entries.count<maximumObjects else{store?.error="Too many solid objects are waiting for interactive geometry.";return}
      cancel(objectID);clock+=1
      let request=Request(token:UUID(),epoch:epoch,projectID:projectID,objectID:objectID,recipe:recipe,parameters:parameters,key:key,preview:preview,commit:commit,draftToken:draftToken,order:clock)
      var entry=entries[objectID] ?? Entry();entry.desired=request;entry.issue=nil;entry.access=clock;entries[objectID]=entry
      let cached = !preview ? try SolidRecipeGeometry.cachedSurface(definition,parameters:parameters):nil
      if let cached {
        Task{[weak self] in await Task.yield();self?.complete(request,result:.success(cached))}
      }else if commit,!preview,let display=entry.display,display.revision==key,!display.surface.isEditingPreview {
        Task{[weak self] in await Task.yield();self?.complete(request,result:.success(display.surface))}
      }else{pending[objectID]=request}
    }catch{store?.error=error.localizedDescription}
  }
  private func pump() {
    while running.count<2,let request=pending.values.min(by:{$0.order<$1.order}) {
      pending[request.objectID]=nil
      let cancellation=OrganicMeshCancellation(),builder=self.builder
      let task=Task.detached(priority:.userInitiated){try await builder(request.recipe,request.parameters,request.preview,cancellation)}
      running[request.token] = .init(request:request,task:task,cancellation:cancellation)
      maximumActiveBuilds=max(maximumActiveBuilds,running.count)
      Task { [weak self] in let result=await task.result;self?.complete(request,result:result) }
    }
  }
  private func complete(_ request:Request,result:Result<SolidSurface,Error>) {
    // A full worker may finish while another native control still owns the
    // engine transaction. Wait in the same bounded slot; never close that
    // unrelated gesture or absorb this publication into its Undo snapshot.
    if case .success=result,request.commit,
      request.epoch==epoch,entries[request.objectID]?.desired?.token==request.token,
      store?.engine.hasActiveInteraction==true {
      Task{[weak self] in try? await Task.sleep(nanoseconds:20_000_000);self?.complete(request,result:result)}
      return
    }
    running[request.token]=nil;defer{pump()}
    guard request.epoch==epoch,request.projectID==store?.project?.id,
      entries[request.objectID]?.desired?.token==request.token,
      let project=store?.project,let current=project.objects.first(where:{$0.id==request.objectID}),
      project.recipe(current.recipeID)==request.recipe else{discardedBuilds+=1;return}
    if let token=request.draftToken {
      guard let draft=drafts[request.objectID],draft.token==token,
        (draft.parameters==request.parameters || (request.commit && draft.predecessors.first?.parameters==request.parameters)),
        draft.baseline==current.parameters else{discardedBuilds+=1;return}
    }else if current.parameters != request.parameters {discardedBuilds+=1;return}
    switch result {
    case .failure(let error):
      if error is CancellationError {discardedBuilds+=1;return}
      reject(request,"Solid construction: "+error.localizedDescription)
    case .success(let surface):
      guard surface.isEditingPreview==request.preview,surface.byteCount<=maximumBytes else{
        reject(request,"The solid result exceeds the interactive buffer budget or has the wrong source quality.");return
      }
      let display=Display(surface:surface,revision:request.key,parameters:request.parameters,recipe:request.recipe)
      let previous=entries[request.objectID]
      entries[request.objectID]?.display=display
      if request.draftToken==nil || request.commit {entries[request.objectID]?.full=display}
      evict(except:request.objectID)
      guard retainedBytes<=maximumBytes else{entries[request.objectID]=previous;reject(request,"The active solid previews exceed the interactive buffer budget.");return}
      do {
        if !request.preview,let definition=request.recipe.solid {try SolidRecipeGeometry.remember(surface,definition:definition,parameters:request.parameters)}
        if request.commit,let token=request.draftToken,let draft=drafts[request.objectID],draft.token==token,!draft.editing,!request.preview {
          // The worker already checked the complete source and full mesh. The
          // ordinary command remains the sole accepted parameter publication.
          store?.engine.endInteraction()
          _ = try store?.engine.call("form_update_object",arguments:["object_id":request.objectID.uuidString,"parameters":request.parameters],source:"Studio")
          if var remaining=drafts[request.objectID],remaining.predecessors.first?.parameters==request.parameters {
            remaining.predecessors.removeFirst();remaining.baseline=request.parameters
            if remaining.predecessors.isEmpty,remaining.parameters==remaining.baseline {drafts[request.objectID]=nil}
            else{drafts[request.objectID]=remaining}
          }else{drafts[request.objectID]=nil}
        }
        entries[request.objectID]?.issue=nil;completedBuilds+=1
        if request.commit {store?.changed()}
        if !request.preview,(request.draftToken==nil || request.commit) {refreshLinkedVectors(request.objectID,surface:surface)}
        if let draft=drafts[request.objectID] {
          if request.commit,!draft.editing {enqueueReleased(draft)}
          else if request.draftToken==nil,draft.editing,draft.parameters != draft.baseline {
            enqueue(projectID:draft.projectID,objectID:request.objectID,recipe:draft.recipe,parameters:draft.parameters,preview:draft.recipe.solid?.previewNodes != nil,draftToken:draft.token)
          }
        }
        notify()
      }catch{entries[request.objectID]=previous;reject(request,error.localizedDescription)}
    }
  }
  private func reject(_ request:Request,_ message:String) {
    entries[request.objectID]?.issue=message;store?.error=message
    if request.draftToken != nil {
      if request.commit {
        if var remaining=drafts[request.objectID],remaining.predecessors.first?.parameters==request.parameters {
          remaining.predecessors.removeFirst()
          if remaining.predecessors.isEmpty,remaining.parameters==request.parameters {drafts[request.objectID]=nil}
          else{drafts[request.objectID]=remaining;enqueueReleased(remaining)}
        }else{drafts[request.objectID]=nil}
      }
      let full=entries[request.objectID]?.full;entries[request.objectID]?.display=full
    }
    notify()
  }
  private func evict(except id:UUID) {
    while retainedBytes>maximumBytes,let victim=entries.filter({$0.key != id && drafts[$0.key]==nil && $0.value.display != nil}).min(by:{$0.value.access<$1.value.access})?.key {
      entries[victim]?.display=nil;entries[victim]?.full=nil
    }
  }
  private func refreshLinkedVectors(_ id:UUID,surface:SolidSurface) {
    guard let store,var project=store.project else{return}
    let assets=store.repository.url(for:project.id).appendingPathComponent("Assets")
    let issues=ObjectViewUpdates.refreshSources([id],project:&project,assets:assets,solidSurfaces:[id:surface])
    if project != store.project {store.engine.project=project;store.metadataRecordsChanged()}
    if !issues.isEmpty {store.error=issues.joined(separator:"\n")}
  }
  private func notify() {
    guard let store else{return}
    store.objectWillChange.send();store.previewVersion &+= 1
    if store.scene != nil {store.synchronizeScene()}
    if store.environment == .studio {store.studioComposition.sync()}
  }
}

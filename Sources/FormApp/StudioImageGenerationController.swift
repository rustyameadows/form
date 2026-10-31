import AppKit
import Combine
import CryptoKit
import FormCore

@MainActor final class StudioImageGenerationController:ObservableObject {
  weak var store:StudioStore?
  let library:StudioAssetLibrary
  let connection=OpenAIConnectionPreviewController()
  @Published var prompt=""
  @Published var style="Faithful studio lighting, clear product details, restrained background."
  @Published var references:[StudioGenerationReference]=[]
  @Published var options=StudioImageGenerationOptions()
  @Published var selectedRunID:UUID?
  @Published private(set) var capture:StudioGenerationCapture?
  @Published private(set) var history:[StudioGenerationRun]=[]
  @Published private(set) var stylePresets:[StudioGenerationStylePreset]=StudioGenerationStylePreset.builtins
  @Published private(set) var busy=false
  @Published private(set) var isCapturing=false
  @Published private(set) var progress=0.0
  @Published private(set) var phase:StudioGenerationPhase = .idle
  @Published private(set) var error:String?
  private let renderer=StudioShotRenderer(),root:URL
  private let provider:any StudioImageGenerationProvider
  private var task:Task<Void,Never>?,generation=0,activeRunID:UUID?,owner:UUID?
  private let captureLimit:Int
  var currentRun:StudioGenerationRun? {history.first{$0.id==selectedRunID}}
  var isCaptureStale:Bool {capture.map{!isCurrent($0)} ?? true}
  init(store:StudioStore,library:StudioAssetLibrary,provider:(any StudioImageGenerationProvider)?=nil,captureLimit:Int=960) {
    self.store=store;self.library=library;self.provider=provider ?? LocalStudioImageGenerationProvider();self.captureLimit=max(160,min(1024,captureLimit))
    root=store.repository.root.appendingPathComponent("StudioAssets");owner=store.project?.id
    loadHistory();loadStyles()
  }
  private static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  private static var now:Date {Date(timeIntervalSince1970:Date().timeIntervalSince1970.rounded(.down))}
  private func draftHash(_ value:StudioComposition)throws->String {Self.hash(try JSONEncoder.form.encode(value))}
  private func isCurrent(_ value:StudioGenerationCapture)->Bool {
    guard let store,let project=store.project,project.id==value.projectID,
      let draft=store.studioComposition.draft,
      (try? project.studioDesignDigest())==value.designSHA256,
      (try? draftHash(draft))==value.draftSHA256 else{return false}
    return store.studioComposition.stage.camera==value.camera
  }
  private func check(_ token:Int,projectID:UUID)throws {
    try Task.checkCancellation()
    guard generation==token,store?.project?.id==projectID else{throw CancellationError()}
  }
  func reconcile() {
    if owner != store?.project?.id {resetForProjectChange();owner=store?.project?.id}
    objectWillChange.send()
  }
  func resetForProjectChange() {cancel();capture=nil;selectedRunID=nil;references=[];prompt="";style="Faithful studio lighting, clear product details, restrained background.";options = .init();error=nil;renderer.clear();owner=store?.project?.id}
  func reset(){resetForProjectChange()}
  func clearError(){error=nil}
  func dismissError(){clearError()}
  func cancel() {
    generation+=1;task?.cancel();task=nil
    if let id=activeRunID {updateRun(id){$0.status = .cancelled;$0.completedAt=Self.now;$0.error="Local demo cancelled; no new results were delivered."}}
    activeRunID=nil;busy=false;isCapturing=false;progress=0;phase = .idle
  }
  func newRun(){if busy {cancel()};selectedRunID=nil;error=nil;progress=0;phase = .idle}
  func selectRun(_ id:UUID) {guard history.contains(where:{$0.id==id}) else{return};selectedRunID=id}
  func imageURL(assetID:UUID)throws->URL {guard let asset=library.asset(id:assetID) else{throw StudioGenerationError.invalid("That Library image is unavailable.")};return try library.fileURL(for:asset)}
  func addReference(assetID:UUID,role:StudioGenerationReference.Role = .style) {
    guard let asset=library.asset(id:assetID),asset.kind == .image else{error="Choose an image from Library.";return}
    if let index=references.firstIndex(where:{$0.assetID==assetID}) {references[index].role=role}
    else if references.count<8 {references.append(.init(assetID:assetID,role:role))}
    else {error="Use up to eight reference images."}
  }
  func removeReference(assetID:UUID){references.removeAll{$0.assetID==assetID}}
  func iterate(resultAssetID:UUID) {
    selectedRunID=nil
    if !references.contains(where:{$0.assetID==resultAssetID}) {addReference(assetID:resultAssetID,role:.style)}
  }
  func retry()async {
    if let prior=currentRun {
      let fixture=options.failureFixture
      prompt=prior.prompt;style=prior.style;references=prior.references;options=prior.options;options.failureFixture=fixture
      capture=prior.capture
    }
    await generate()
  }
  func captureScene()async {
    guard !busy,let store,let projectID=store.project?.id else{error="Open a project and arrange a Studio scene first.";return}
    generation+=1;let token=generation
    busy=true;isCapturing=true;phase = .capturing;progress=0.05;error=nil
    let work=Task { @MainActor [weak self] in
      guard let self else{return}
      defer {if self.generation==token {self.busy=false;self.isCapturing=false;self.task=nil;self.phase = .idle}}
      do {
        let frozen=try store.studioComposition.prepareForImageCapture()
        guard let project=store.project,project.id==projectID else{throw CancellationError()}
        guard let currentDraft=store.studioComposition.draft else{throw StudioGenerationError.invalid("Choose a composed scene.")}
        let digest=try project.studioDesignDigest(),draftDigest=try self.draftHash(currentDraft)
        let sourceIDs=Array(Set(frozen.instances.filter(\.visible).compactMap(\.sourceObjectID)))
        if !sourceIDs.isEmpty {
          var preflight=frozen.shot(camera:frozen.camera)
          preflight.visibility = .init(mode:.objects,objectIDs:sourceIDs)
          try store.studioShots.runtimePreflight(project,preflight)
        }
        let resolved=try frozen.resolved(in:project)
        var shot=frozen.shot(camera:frozen.camera)
        shot.visibility = .init(mode:.objects,objectIDs:resolved.visible.sorted{$0.uuidString<$1.uuidString})
        let aspect=max(0.125,min(8,frozen.camera.viewportAspect ?? 1.6)),long=self.captureLimit
        shot.referenceAspect=aspect
        shot.pixels = aspect>=1 ? .init(width:long,height:max(64,Int((Double(long)/aspect).rounded()))):.init(width:max(64,Int((Double(long)*aspect).rounded())),height:long)
        let rendered=try await self.renderer.renderResult(project:resolved.project,shot:shot,assets:store.repository.url(for:project.id).appendingPathComponent("Assets"),preview:false,renderObjectIDs:resolved.visible)
        try self.check(token,projectID:project.id)
        var value=StudioGenerationCapture(id:UUID(),createdAt:Self.now,projectID:project.id,projectName:project.name,scene:frozen,camera:frozen.camera,designSHA256:digest,draftSHA256:draftDigest,inputAssetID:UUID(),width:shot.pixels.width,height:shot.pixels.height,warnings:rendered.framingWarnings.isEmpty ? []:["Some scene bounds extend beyond the captured frame."])
        guard self.isCurrent(value) else{throw StudioGenerationError.stale}
        let png=try StudioPNG.encode(rendered.image,designDigest:digest)
        if let bitmap=NSBitmapImageRep(data:png) {value.width=bitmap.pixelsWide;value.height=bitmap.pixelsHigh}
        let asset=try self.library.register(data:png,filename:"scene-input.png",name:"Scene input · "+frozen.name,metadata:.init(kind:.image,origin:.exported,projectID:project.id,projectName:project.name,sceneID:frozen.id,isMock:false,options:["purpose":"generation_input","renderer":"RealityKit","design_sha256":digest,"draft_sha256":draftDigest,"transport":"none"]))
        value.inputAssetID=asset.id;self.capture=value;self.progress=1
      }catch {if self.generation==token {self.error=error is CancellationError ? "Scene capture cancelled.":error.localizedDescription}}
    }
    task=work;await work.value
  }
  func generate()async {
    guard !busy else{return}
    guard let capture,store?.project?.id==capture.projectID else{error="Capture a Studio composition in the current project, or reopen the project belonging to this frozen input.";return}
    do {
      try options.validate();try validateForm()
      guard let asset=library.asset(id:capture.inputAssetID),asset.byteCount<=32*1024*1024 else{throw StudioGenerationError.invalid("The scene input is unavailable or too large.")}
      let input=try Data(contentsOf:library.fileURL(for:asset))
      if let expected=asset.sha256,Self.hash(input) != expected {throw StudioGenerationError.invalid("The captured input changed on disk. Recapture the scene.")}
      generation+=1;let token=generation
      let run=StudioGenerationRun(id:UUID(),createdAt:Self.now,completedAt:nil,status:.running,capture:capture,prompt:prompt,style:style,references:references,options:options)
      try persist(run);history.insert(run,at:0);if history.count>128 {history.removeLast(history.count-128)}
      activeRunID=run.id;selectedRunID=run.id;busy=true;phase = .queued;progress=0;error=nil
      let request=StudioGenerationRequest(inputPNG:input,prompt:run.prompt,style:run.style,references:run.references,options:run.options)
      let work=Task { @MainActor [weak self] in
        guard let self else{return}
        defer {if self.generation==token {self.busy=false;self.activeRunID=nil;self.task=nil;self.phase = .finished}}
        do {
          await Task.yield();try self.check(token,projectID:capture.projectID);self.phase = .preparing;self.progress=0.05
          let images=try await self.provider.generate(request) { [weak self] value in
            guard let self,self.generation==token else{return}
            self.phase = .generating;self.progress=0.1+max(0,min(1,value))*0.75
          }
          try self.check(token,projectID:capture.projectID)
          guard images.count==run.options.count else{throw StudioGenerationError.invalid("The local demo returned an incomplete batch.")}
          self.phase = .writing;self.progress=0.9
          await Task.yield();try self.check(token,projectID:capture.projectID)
          var registrations=[StudioAssetRegistration]()
          for (index,png) in images.enumerated() {
            let dimensions=run.options.pixels
            guard png.count<=32*1024*1024,png.starts(with:[137,80,78,71,13,10,26,10]),let bitmap=NSBitmapImageRep(data:png),bitmap.pixelsWide==dimensions.width,bitmap.pixelsHigh==dimensions.height else{throw StudioGenerationError.invalid("The local demo returned an invalid or incorrectly sized PNG batch.")}
            let sourceIDs=Array(Set([capture.inputAssetID]+run.references.map(\.assetID))).sorted{$0.uuidString<$1.uuidString}
            registrations.append(.init(data:png,filename:"demo-\(index+1).png",name:"Demo · \(run.capture.scene.name) · \(index+1)",metadata:.init(kind:.image,origin:.generated,projectID:capture.projectID,projectName:capture.projectName,sceneID:capture.sceneID,generationID:run.id,isMock:true,sourceAssetIDs:sourceIDs,prompt:run.prompt,provider:"Local demo · no AI request",options:run.options.redactedMetadata.merging(["style":run.style,"design_sha256":capture.designSHA256,"draft_sha256":capture.draftSHA256]){_,new in new})))
          }
          let ids=try self.library.registerBatch(registrations).map(\.id)
          self.updateRun(run.id){$0.status = .succeeded;$0.outputAssetIDs=ids;$0.completedAt=Self.now;$0.error=nil}
          self.progress=1
        }catch {
          guard self.generation==token else{return}
          let status:StudioGenerationRun.Status=error is CancellationError ? .cancelled:(error as? StudioGenerationError).map{if case .stale=$0{return true};return false} == true ? .stale:.failed
          let saved=self.updateRun(run.id){$0.status=status;$0.completedAt=Self.now;$0.error=error.localizedDescription}
          self.error=error.localizedDescription+(saved ? "":" "+(self.error ?? "History could not be saved."))
        }
      }
      task=work;await work.value
    }catch {self.error=error.localizedDescription}
  }
  private func validateForm()throws {
    guard !prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,prompt.count<=8000,style.count<=4000,references.count<=8,Set(references.map(\.assetID)).count==references.count else{throw StudioGenerationError.invalid("Add a prompt up to 8000 characters, a style up to 4000, and at most eight unique references.")}
    for reference in references {
      guard let asset=library.asset(id:reference.assetID),asset.kind == .image,!asset.isMissing else{throw StudioGenerationError.invalid("A reference image is missing. Replace it before creating another image.")}
      _ = try library.fileURL(for:asset)
    }
  }
  private var runDirectory:URL {root.appendingPathComponent("GenerationRuns")}
  private func persist(_ run:StudioGenerationRun)throws {try FileManager.default.createDirectory(at:runDirectory,withIntermediateDirectories:true);let data=try JSONEncoder.form.encode(run);guard data.count<=2*1024*1024 else{throw StudioGenerationError.invalid("Generation provenance exceeds its bounded record size.")};try data.write(to:runDirectory.appendingPathComponent(run.id.uuidString+".json"),options:.atomic)}
  @discardableResult private func updateRun(_ id:UUID,_ change:(inout StudioGenerationRun)->Void)->Bool {
    guard let index=history.firstIndex(where:{$0.id==id}) else{return false};var run=history[index];change(&run)
    // A completed batch/cancellation is already real. Retain its terminal state
    // and output links even if the separate history write cannot reach disk.
    history[index]=run
    do {try persist(run);return true}catch {self.error="Could not save generation history. The current result links were retained: "+error.localizedDescription;return false}
  }
  private func recoveredOutputIDs(for run:StudioGenerationRun)->[UUID]? {
    let expectedSources=Set([run.capture.inputAssetID]+run.references.map(\.assetID))
    let assets=library.items.filter{$0.metadata.generationID==run.id}
    guard assets.count==run.options.count,Set(assets.map(\.filename))==Set((1...run.options.count).map{"demo-\($0).png"}) else{return nil}
    for asset in assets {
      guard asset.kind == .image,asset.origin == .generated,asset.storage == .owned,asset.isMock,
        asset.metadata.projectID==run.capture.projectID,asset.metadata.sceneID==run.capture.sceneID,
        asset.metadata.provider==run.provider,
        asset.metadata.prompt==run.prompt,Set(asset.metadata.sourceAssetIDs)==expectedSources,
        asset.metadata.options?["design_sha256"]==run.capture.designSHA256,
        asset.metadata.options?["draft_sha256"]==run.capture.draftSHA256,
        asset.metadata.options?["style"]==run.style,
        run.options.redactedMetadata.allSatisfy({asset.metadata.options?[$0.key]==$0.value}) else{return nil}
    }
    return assets.sorted{$0.filename<$1.filename}.map(\.id)
  }
  private func loadHistory() {
    let files=((try? FileManager.default.contentsOfDirectory(at:runDirectory,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey])) ?? []).filter{$0.pathExtension=="json"}.sorted{((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)>((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)}.prefix(128)
    history=files.compactMap {url in
      guard let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=2*1024*1024,
        let data=try? Data(contentsOf:url),var run=try? JSONDecoder.form.decode(StudioGenerationRun.self,from:data),
        (try? run.options.validate()) != nil else{return nil}
      if run.status == .running {
        // Library publishes a generated batch in one atomic index transaction.
        // That exact provenance can recover a final history write lost at exit.
        if let ids=recoveredOutputIDs(for:run) {run.status = .succeeded;run.outputAssetIDs=ids;run.error=nil}
        else {run.status = .cancelled;run.error="The app closed before this local demo completed."}
        run.completedAt=Self.now
        do {try persist(run)}catch {self.error="Recovered generation state could not be saved: "+error.localizedDescription}
      }
      return run
    }.sorted{$0.createdAt>$1.createdAt}
  }
  func saveStylePreset(name:String)throws {
    let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
    guard !name.isEmpty,name.count<=80,style.count<=4000,references.count<=8 else{throw StudioGenerationError.invalid("Name the style using at most 80 characters.")}
    var values=stylePresets
    if let index=values.firstIndex(where:{$0.name.caseInsensitiveCompare(name) == .orderedSame}) {values[index].instructions=style;values[index].references=references}
    else {guard values.count<32 else{throw StudioGenerationError.invalid("Keep up to 32 reusable styles.")};values.append(.init(id:UUID(),name:name,instructions:style,references:references))}
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);try JSONEncoder.form.encode(values).write(to:root.appendingPathComponent("GenerationStyles.json"),options:.atomic);stylePresets=values
  }
  func applyStylePreset(_ preset:StudioGenerationStylePreset){style=preset.instructions;references=preset.references}
  private func loadStyles(){guard let data=try? Data(contentsOf:root.appendingPathComponent("GenerationStyles.json")),data.count<=512*1024,let values=try? JSONDecoder.form.decode([StudioGenerationStylePreset].self,from:data),values.count<=32 else{return};let ids=Set(values.map(\.id));stylePresets=StudioGenerationStylePreset.builtins.filter{!ids.contains($0.id)}+values}
}

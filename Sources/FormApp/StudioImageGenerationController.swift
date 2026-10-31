import AppKit
import Combine
import CryptoKit
import FormCore

@MainActor final class StudioImageGenerationController:ObservableObject {
  weak var store:StudioStore?
  let library:StudioAssetLibrary
  let projectID:UUID?
  let connection:OpenAIConnectionPreviewController
  @Published var prompt=""
  @Published var style="Faithful studio lighting, clear product details, restrained background."
  @Published var references:[StudioGenerationReference]=[]
  @Published var options=StudioImageGenerationOptions()
  @Published var selectedRunID:UUID?
  @Published private(set) var capture:StudioGenerationCapture?
  @Published private(set) var history:[StudioGenerationRun]=[]
  @Published private(set) var stylePresets:[StudioGenerationStylePreset]=StudioGenerationStylePreset.builtins
  @Published private(set) var promptPresets:[StudioGenerationPromptPreset]=StudioGenerationPromptPreset.builtins
  @Published private(set) var busy=false
  @Published private(set) var isCapturing=false
  @Published private(set) var progress=0.0
  @Published private(set) var phase:StudioGenerationPhase = .idle
  @Published private(set) var error:String?
  private let renderer=StudioShotRenderer(),root:URL
  private let provider:any StudioImageGenerationProvider
  private var task:Task<Void,Never>?,generation=0,activeRunID:UUID?,owner:UUID?
  private var stylesReadFailed=false
  private var promptsReadFailed=false
  private var lastScopeActive=false
  private var scopeIsActive:Bool {projectID != nil && store?.project?.id==projectID && store?.showingHome==false}
  var currentRun:StudioGenerationRun? {guard scopeIsActive else{return nil};return history.first{$0.id==selectedRunID && $0.capture.projectID==projectID}}
  var isCaptureStale:Bool {capture.map{!isCurrent($0)} ?? true}
  var hasExactStudioPixels:Bool {capture?.hasExactStudioPixels == true}
  init(store:StudioStore,library:StudioAssetLibrary,provider:(any StudioImageGenerationProvider)?=nil,connection:OpenAIConnectionPreviewController?=nil) {
    self.store=store;self.library=library;self.provider=provider ?? LocalStudioImageGenerationProvider()
    self.connection=connection ?? OpenAIConnectionPreviewController()
    projectID=library.projectID ?? store.project?.id
    root=store.repository.root.appendingPathComponent("StudioAssets");owner=store.project?.id
    lastScopeActive=scopeIsActive
    loadHistory();loadStyles();loadPrompts()
  }
  private static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  private static var now:Date {Date(timeIntervalSince1970:Date().timeIntervalSince1970.rounded(.down))}
  private func draftHash(_ value:StudioComposition)throws->String {Self.hash(try JSONEncoder.form.encode(value))}
  private func isCurrent(_ value:StudioGenerationCapture)->Bool {
    guard scopeIsActive,value.projectID==projectID,let store,let project=store.project,project.id==value.projectID,
      let draft=store.studioComposition.draft,
      (try? project.studioDesignDigest())==value.designSHA256,
      (try? draftHash(draft))==value.draftSHA256 else{return false}
    return store.studioComposition.stage.camera==value.camera
  }
  private func check(_ token:Int,projectID:UUID)throws {
    try Task.checkCancellation()
    guard scopeIsActive,self.projectID==projectID,generation==token,store?.project?.id==projectID else{throw CancellationError()}
  }
  func reconcile() {
    if owner != store?.project?.id || lastScopeActive != scopeIsActive {resetForProjectChange();owner=store?.project?.id}
    objectWillChange.send()
  }
  func resetForProjectChange() {cancel();capture=nil;selectedRunID=nil;references=[];prompt="";style="Faithful studio lighting, clear product details, restrained background.";options = .init();error=nil;renderer.clear();owner=store?.project?.id;lastScopeActive=scopeIsActive;history=[];stylePresets=StudioGenerationStylePreset.builtins;promptPresets=StudioGenerationPromptPreset.builtins;loadHistory();loadStyles();loadPrompts()}
  func reset(){resetForProjectChange()}
  func clearError(){error=nil}
  func dismissError(){clearError()}
  func cancel() {
    generation+=1;task?.cancel();task=nil
    if let id=activeRunID {updateRun(id){$0.status = .cancelled;$0.completedAt=Self.now;$0.error="Local demo cancelled; no new results were delivered."}}
    activeRunID=nil;busy=false;isCapturing=false;progress=0;phase = .idle
  }
  func newRun(){if busy {cancel()};selectedRunID=nil;error=nil;progress=0;phase = .idle}
  /// Entering from Studio replaces only the scene input. The composing prompt,
  /// references, model and other generation settings belong to the user.
  func refreshSceneInputFromStudio() {
    guard scopeIsActive,!busy else{return}
    capture=nil
    let token=generation
    Task { @MainActor [weak self] in
      guard let self,self.generation==token,self.scopeIsActive else{return}
      await self.captureScene()
    }
  }
  func selectRun(_ id:UUID) {guard scopeIsActive,history.contains(where:{$0.id==id && $0.capture.projectID==projectID}) else{return};selectedRunID=id}
  func imageURL(assetID:UUID)throws->URL {guard scopeIsActive,let asset=library.asset(id:assetID),asset.metadata.projectID==projectID else{throw StudioGenerationError.invalid("That image is not available in this project's Library.")};return try library.fileURL(for:asset)}
  func addReference(assetID:UUID,role:StudioGenerationReference.Role = .style) {
    guard scopeIsActive,let asset=library.asset(id:assetID),asset.kind == .image,asset.metadata.projectID==projectID else{error="Choose an image from this project's Library.";return}
    if let index=references.firstIndex(where:{$0.assetID==assetID}) {references[index].role=role}
    else if references.count<8 {references.append(.init(assetID:assetID,role:role))}
    else {error="Use up to eight reference images."}
  }
  func removeReference(assetID:UUID){references.removeAll{$0.assetID==assetID}}
  func iterate(resultAssetID:UUID) {
    guard scopeIsActive,let asset=library.asset(id:resultAssetID),asset.kind == .image,asset.metadata.projectID==projectID else{error="Choose an image from this project's Library.";return}
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
    guard scopeIsActive,!busy,let store,let projectID=self.projectID else{error="Open this project and arrange a Studio scene first.";return}
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
        let rendered=try await self.renderer.renderResult(project:resolved.project,shot:shot,assets:store.repository.url(for:project.id).appendingPathComponent("Assets"),preview:false,renderObjectIDs:resolved.visible)
        try self.check(token,projectID:project.id)
        var value=StudioGenerationCapture(id:UUID(),createdAt:Self.now,projectID:project.id,projectName:project.name,scene:frozen,camera:frozen.camera,designSHA256:digest,draftSHA256:draftDigest,inputAssetID:UUID(),width:shot.pixels.width,height:shot.pixels.height,warnings:rendered.framingWarnings.isEmpty ? []:["Some scene bounds extend beyond the captured frame."])
        guard self.isCurrent(value) else{throw StudioGenerationError.stale}
        let png=try StudioPNG.encode(rendered.image,designDigest:digest)
        let actual=try StudioGenerationPNG.pixelSize(of:png)
        guard actual==frozen.pixels else{throw StudioGenerationError.invalid("The native render did not preserve the Studio output pixels. No scene input was published; recapture the scene.")}
        value.context=try StudioGenerationInputContext.make(project:project,scene:frozen,resolved:resolved.project,renderObjectCount:resolved.visible.count,width:value.width,height:value.height,renderer:self.renderer.backendIdentifier)
        var inputOptions=["purpose":"generation_input","renderer":self.renderer.backendIdentifier,"design_sha256":digest,"draft_sha256":draftDigest,"transport":"none"]
        inputOptions["input_context_sha256"]=try value.context?.sha256
        let asset=try self.library.register(data:png,filename:"scene-input.png",name:"Scene input · "+frozen.name,metadata:.init(kind:.image,origin:.exported,projectID:project.id,projectName:project.name,sceneID:frozen.id,isMock:false,options:inputOptions))
        value.inputAssetID=asset.id;self.capture=value;self.options.outputPixels=frozen.pixels;self.progress=1
      }catch {if self.generation==token {self.error=error is CancellationError ? "Scene capture cancelled.":error.localizedDescription}}
    }
    task=work;await work.value
  }
  func generate()async {
    guard !busy else{return}
    guard scopeIsActive,let capture,capture.projectID==projectID else{error="Capture a Studio composition in this project, or reopen the project belonging to this frozen input.";return}
    do {
      guard capture.hasExactStudioPixels else{throw StudioGenerationError.invalid("This earlier scene input was scaled down. Recapture the scene to use its exact Studio output pixels.")}
      var effectiveOptions=options;effectiveOptions.outputPixels=capture.scene.pixels
      try effectiveOptions.validate();try validateForm()
      guard let asset=library.asset(id:capture.inputAssetID),asset.metadata.projectID==projectID else{throw StudioGenerationError.invalid("The scene input is unavailable in this project. Recapture the scene.")}
      let input=try Data(contentsOf:library.fileURL(for:asset))
      if let expected=asset.sha256,Self.hash(input) != expected {throw StudioGenerationError.invalid("The captured input changed on disk. Recapture the scene.")}
      guard try StudioGenerationPNG.pixelSize(of:input)==capture.scene.pixels else{throw StudioGenerationError.invalid("The saved scene image does not match its Studio output pixels. Recapture the scene; this image will not be resized.")}
      generation+=1;let token=generation
      let run=StudioGenerationRun(id:UUID(),createdAt:Self.now,completedAt:nil,status:.running,capture:capture,prompt:prompt,style:style,references:references,options:effectiveOptions)
      try persist(run);history.insert(run,at:0);if history.count>128 {history.removeLast(history.count-128)}
      options=effectiveOptions
      activeRunID=run.id;selectedRunID=run.id;busy=true;phase = .queued;progress=0;error=nil
      let request=StudioGenerationRequest(inputPNG:input,prompt:run.prompt,style:run.style,references:run.references,options:run.options,context:run.capture.context)
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
          var provenance=run.options.redactedMetadata.merging(["style":run.style,"design_sha256":capture.designSHA256,"draft_sha256":capture.draftSHA256]){_,new in new}
          provenance["input_context_sha256"]=try capture.context?.sha256
          for (index,png) in images.enumerated() {
            let dimensions=run.options.pixels
            let actual=try StudioGenerationPNG.pixelSize(of:png)
            guard actual.width==dimensions.width,actual.height==dimensions.height else{throw StudioGenerationError.invalid("The local demo returned an incorrectly sized PNG batch. Studio output pixels must be preserved.")}
            let sourceIDs=Array(Set([capture.inputAssetID]+run.references.map(\.assetID))).sorted{$0.uuidString<$1.uuidString}
            registrations.append(.init(data:png,filename:"demo-\(index+1).png",name:"Demo · \(run.capture.scene.name) · \(index+1)",metadata:.init(kind:.image,origin:.generated,projectID:capture.projectID,projectName:capture.projectName,sceneID:capture.sceneID,generationID:run.id,isMock:true,sourceAssetIDs:sourceIDs,prompt:run.prompt,provider:"Local demo · no AI request",options:provenance)))
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
      guard scopeIsActive,let asset=library.asset(id:reference.assetID),asset.metadata.projectID==projectID,asset.kind == .image,!asset.isMissing else{throw StudioGenerationError.invalid("A reference image is missing from this project's Library. Replace it before creating another image.")}
      _ = try library.fileURL(for:asset)
    }
  }
  private var runDirectory:URL {root.appendingPathComponent("GenerationRuns")}
  private func persist(_ run:StudioGenerationRun)throws {guard run.capture.projectID==projectID else{throw StudioGenerationError.invalid("Generation history belongs to another project.")};try FileManager.default.createDirectory(at:runDirectory,withIntermediateDirectories:true);let data=try JSONEncoder.form.encode(run);guard data.count<=2*1024*1024 else{throw StudioGenerationError.invalid("Generation provenance exceeds its bounded record size.")};try data.write(to:runDirectory.appendingPathComponent(run.id.uuidString+".json"),options:.atomic)}
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
      if let context=run.capture.context {guard let digest=try? context.sha256,asset.metadata.options?["input_context_sha256"]==digest else{return nil}}
    }
    return assets.sorted{$0.filename<$1.filename}.map(\.id)
  }
  private func loadHistory() {
    guard scopeIsActive else{history=[];return}
    let files=((try? FileManager.default.contentsOfDirectory(at:runDirectory,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey])) ?? []).filter{$0.pathExtension=="json"}.sorted{((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)>((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)}.prefix(4096)
    var values=[StudioGenerationRun]()
    for url in files {
      guard let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=2*1024*1024,
        let data=try? Data(contentsOf:url),var run=try? JSONDecoder.form.decode(StudioGenerationRun.self,from:data),
        run.capture.projectID==projectID,(try? run.options.validate()) != nil else{continue}
      if let context=run.capture.context,(try? context.validate()) == nil {continue}
      if run.status == .running {
        // Library publishes a generated batch in one atomic index transaction.
        // That exact provenance can recover a final history write lost at exit.
        if let ids=recoveredOutputIDs(for:run) {run.status = .succeeded;run.outputAssetIDs=ids;run.error=nil}
        else {run.status = .cancelled;run.error="The app closed before this local demo completed."}
        run.completedAt=Self.now
        do {try persist(run)}catch {self.error="Recovered generation state could not be saved: "+error.localizedDescription}
      }
      values.append(run);if values.count==128 {break}
    }
    history=values.sorted{$0.createdAt>$1.createdAt}
  }
  private var styleFile:URL? {projectID.map{root.appendingPathComponent("GenerationStyles").appendingPathComponent($0.uuidString+".json")}}
  private func ownsReferences(_ values:[StudioGenerationReference])->Bool {
    values.count<=8 && Set(values.map(\.assetID)).count==values.count && values.allSatisfy {value in
      guard let asset=library.asset(id:value.assetID) else{return false}
      return asset.metadata.projectID==projectID && asset.kind == .image
    }
  }
  func saveStylePreset(name:String)throws {
    let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
    guard scopeIsActive,let file=styleFile,!stylesReadFailed,!name.isEmpty,name.count<=80,style.count<=4000,ownsReferences(references) else{throw StudioGenerationError.invalid("Save a named style with references from this project and a readable project style file.")}
    var values=stylePresets
    if let index=values.firstIndex(where:{$0.name.caseInsensitiveCompare(name) == .orderedSame}) {values[index].instructions=style;values[index].references=references}
    else {guard values.count<32 else{throw StudioGenerationError.invalid("Keep up to 32 reusable styles.")};values.append(.init(id:UUID(),name:name,instructions:style,references:references))}
    try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONEncoder.form.encode(values).write(to:file,options:.atomic);stylePresets=values
  }
  func applyStylePreset(_ preset:StudioGenerationStylePreset){guard scopeIsActive,stylePresets.contains(preset),ownsReferences(preset.references) else{error="That style is not available in this project.";return};style=preset.instructions;references=preset.references}
  private func loadStyles(){
    stylePresets=StudioGenerationStylePreset.builtins;stylesReadFailed=false
    guard scopeIsActive,let file=styleFile else{return}
    let scoped=FileManager.default.fileExists(atPath:file.path)
    let source=scoped ? file:root.appendingPathComponent("GenerationStyles.json")
    guard FileManager.default.fileExists(atPath:source.path) else{return}
    guard let data=try? Data(contentsOf:source),data.count<=512*1024,
      let decoded=try? JSONDecoder.form.decode([StudioGenerationStylePreset].self,from:data),decoded.count<=32 else{
      if scoped {stylesReadFailed=true;error="The project style file could not be read. Its existing bytes were preserved."};return
    }
    // Old global files are never rewritten. Only referenced presets with an
    // unambiguous owner can be adopted; unassigned text-only presets stay put.
    let values=decoded.filter{(scoped || !$0.references.isEmpty) && !$0.name.isEmpty && $0.name.count<=80 && $0.instructions.count<=4000 && ownsReferences($0.references)}
    let ids=Set(values.map(\.id));stylePresets=StudioGenerationStylePreset.builtins.filter{!ids.contains($0.id)}+values
  }
  private var promptFile:URL? {projectID.map{root.appendingPathComponent("GenerationPrompts").appendingPathComponent($0.uuidString+".json")}}
  func applyPromptPreset(_ preset:StudioGenerationPromptPreset) {
    guard scopeIsActive,promptPresets.contains(preset) else{error="That prompt preset is not available in this project.";return}
    prompt=preset.prompt
  }
  func savePromptPreset(name:String)throws {
    let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
    guard scopeIsActive,let file=promptFile,!promptsReadFailed,!name.isEmpty,name.count<=80,
      !prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,prompt.count<=8000 else{throw StudioGenerationError.invalid("Save a named project prompt with at most8000 characters and a readable preset file.")}
    var values=promptPresets
    if let index=values.firstIndex(where:{$0.name.caseInsensitiveCompare(name) == .orderedSame}) {values[index].prompt=prompt}
    else {guard values.count<32 else{throw StudioGenerationError.invalid("Keep up to32 project prompt presets.")};values.append(.init(id:UUID(),name:name,prompt:prompt))}
    try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
    let data=try JSONEncoder.form.encode(values);guard data.count<=2*1024*1024 else{throw StudioGenerationError.invalid("The project prompt file exceeds2MiB.")}
    try data.write(to:file,options:.atomic);promptPresets=values
  }
  private func loadPrompts() {
    promptPresets=StudioGenerationPromptPreset.builtins;promptsReadFailed=false
    guard scopeIsActive,let file=promptFile,FileManager.default.fileExists(atPath:file.path) else{return}
    guard let data=try? Data(contentsOf:file),data.count<=2*1024*1024,
      let values=try? JSONDecoder.form.decode([StudioGenerationPromptPreset].self,from:data),values.count<=32,
      Set(values.map(\.id)).count==values.count,
      values.allSatisfy({!$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.name.count<=80 && !$0.prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.prompt.count<=8000}) else{
      promptsReadFailed=true;error="The project prompt preset file could not be read. Its existing bytes were preserved.";return
    }
    let ids=Set(values.map(\.id));promptPresets=StudioGenerationPromptPreset.builtins.filter{!ids.contains($0.id)}+values
  }
}

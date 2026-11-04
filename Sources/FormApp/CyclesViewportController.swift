import AppKit
import Combine
import FormCore
import LabRendering

/// Presentation state is transient; saved settings remain in the project/shot.
@MainActor final class CyclesViewportController:ObservableObject {
  weak var source:TableSceneController?
  @Published private(set) var image:NSImage?
  @Published private(set) var phase="Fast"
  @Published private(set) var sample=0
  @Published private(set) var totalSamples=0
  @Published private(set) var device=""
  @Published private(set) var error:String?
  @Published private(set) var isPaused=false
  @Published private(set) var fallbackReason:String?
  private var task:Task<Void,Never>?
  private var jobID:UUID?
  private var generation=0
  private var lastKey:String?
  init(source:TableSceneController){self.source=source}
  var enabled:Bool {source?.cyclesSettings.renderer == .cycles}
  var statusText:String {Self.statusText(phase:phase,sample:sample,totalSamples:totalSamples)}
  static func statusText(phase:String,sample:Int,totalSamples:Int)->String {
    let value=phase.lowercased()
    if value=="complete" {return "Complete · \(sample)"}
    if value=="fast" {return "Fast"}
    let label:String
    if value=="paused" {label="Paused"}
    else if value.contains("denois") {label="Denoising"}
    else if value.contains("another render") {return "Waiting"}
    else if sample>0 || value.contains("rendering") || value.contains("sample") {label="Rendering"}
    else {label="Preparing"}
    return totalSamples>0 ? "\(label) · \(sample)/\(totalSamples)":label
  }
  func pause() {let latest=image;isPaused=true;suspend();image=latest;phase="Paused"}
  func resume() {isPaused=false;refresh()}
  func suspend() {
    generation &+= 1;task?.cancel();task=nil;lastKey=nil;image=nil
    if let id=jobID {Task{await LabCyclesRuntime.service.cancel(jobID:id)}}
    jobID=nil;phase=enabled ? "Paused":"Fast"
  }
  func refresh() {lastKey=nil;sceneChanged()}
  func sceneChanged() {
    guard let source,enabled,let view=source.view,view.window != nil,!view.isHiddenOrHasHiddenAncestor else {
      if task != nil || image != nil {suspend()};return
    }
    guard !isPaused else{image=nil;phase="Paused";return}
    let settings=source.cyclesSettings
    let key:String
    do {key=try source.cyclesSceneKey(settings:settings)+":\(Int(view.bounds.width))x\(Int(view.bounds.height))"}
    catch {self.error=error.localizedDescription;return}
    guard key != lastKey else{return}
    suspend();lastKey=key;error=nil;phase="Preparing";sample=0;totalSamples=settings.previewSamples;device="";fallbackReason=nil
    let token=generation
    task=Task { [weak self,weak source] in
      do {
        try await Task.sleep(nanoseconds:300_000_000)
        guard let self,let source,self.generation==token,let view=source.view,view.window != nil else{return}
        let pixels=StudioPixels(width:max(64,Int(view.bounds.width)),height:max(64,Int(view.bounds.height)))
        let snapshot=try await source.cyclesSnapshot(settings:settings)
        let configuration=LabCyclesRuntime.configuration(settings,pixels:pixels,preview:true)
        let job=try await LabCyclesRuntime.service.start(snapshot:snapshot,settings:configuration,outputDirectory:LabCyclesRuntime.cacheURL)
        guard self.generation==token,!Task.isCancelled else{await LabCyclesRuntime.service.cancel(jobID:job.id);return}
        self.jobID=job.id
        for try await event in job.events {
          try Task.checkCancellation()
          guard self.generation==token else{await LabCyclesRuntime.service.cancel(jobID:job.id);return}
          switch event {
          case .progress(let progress):
            self.phase=progress.phase;self.sample=progress.sample;self.totalSamples=progress.totalSamples
            if let device=progress.device {self.device=device}
            self.fallbackReason=progress.fallbackReason
          case .frame(let frame):
            guard frame.sourceRevision==snapshot.revision else{continue}
            self.image=Self.image(at:frame.url);self.sample=frame.sample
          case .completed(let result):
            self.image=Self.image(at:result.pngURL);self.device=result.device
            self.fallbackReason=result.fallbackReason
            self.sample=result.samples;self.phase="Complete";self.jobID=nil
          }
        }
      } catch is CancellationError {} catch CyclesRenderError.cancelled {
        await self?.retryAfterPreemption(generation:token)
      } catch CyclesRenderError.busy {
        await self?.retryAfterPreemption(generation:token)
      } catch {
        guard let self,self.generation==token else{return}
        self.error=error.localizedDescription;self.phase="Render unavailable";self.image=nil;self.jobID=nil
      }
    }
  }
  private func retryAfterPreemption(generation token:Int)async {
    guard generation==token,!Task.isCancelled,!isPaused,enabled else{return}
    jobID=nil;phase="Another render in progress"
    try? await Task.sleep(nanoseconds:2_000_000_000)
    guard generation==token,!Task.isCancelled,!isPaused,enabled else{return}
    refresh()
  }
  private static func image(at url:URL)->NSImage? {
    guard let data=try? Data(contentsOf:url) else{return nil}
    return NSImage(data:data)
  }
}

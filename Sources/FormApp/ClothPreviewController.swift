import SwiftUI
import FormCore

/// One actor owns native/MCP preview state. Only an explicitly running task
/// schedules work; opening an inspector or reading diagnostics never does.
@MainActor final class ClothPreviewController:ObservableObject {
  enum PreviewError:LocalizedError {
    case superseded
    var errorDescription:String? {"The cloth source changed before this step completed."}
  }
  @Published private(set) var diagnostics:ClothDiagnostics?
  @Published private(set) var isStepping=false
  @Published private(set) var lastError:String?
  var onFrame:((ClothMesh,ClothFrame)->Void)?
  private var session=ClothSession()
  private var runner:Task<Void,Never>?
  private var runnerID:UUID?
  private(set) var maximumWorkerMilliseconds=0.0
  private(set) var maximumPublishMilliseconds=0.0
  private var frameStepSeconds=1.0/60
  var frame:ClothFrame? {session.frame}
  var mesh:ClothMesh? {session.mesh}
  var definitionDigest:String? {session.studyDigest}
  var source:ClothSourceIdentity? {session.source}
  var isRunning:Bool {diagnostics?.status == .running}
  deinit {runner?.cancel()}
  @discardableResult func bind(_ identity:ClothSourceIdentity,study:ClothStudy)throws -> Bool {
    var replacement=session
    guard try replacement.bind(identity,study:study) else {return false}
    cancelRunner();maximumWorkerMilliseconds=0;maximumPublishMilliseconds=0;session=replacement;frameStepSeconds=study.settings.frameStepSeconds;isStepping=false;lastError=nil;publish();return true
  }
  func clear() {cancelRunner();session.clear();diagnostics=nil;lastError=nil;isStepping=false}
  func run()throws {
    guard !isStepping else {throw FormError.invalid("Wait for the current cloth step before running.")}
    if runner != nil {return}
    try session.start();lastError=nil
    let identity=UUID();runnerID=identity
    runner=Task { [weak self] in
      while !Task.isCancelled {
        guard let work=self?.nextRunStep(identity) else {break}
        let began=Date()
        let measured=await Task.detached(priority:.userInitiated) {let t=Date();let result=work.compute();return(result,Date().timeIntervalSince(t)*1000)}.value
        guard !Task.isCancelled else{break}
        self?.maximumWorkerMilliseconds=max(self?.maximumWorkerMilliseconds ?? 0,measured.1)
        guard let delay=self?.completeRunStep(measured.0,identity:identity) else {break}
        let remaining=max(0,delay-Date().timeIntervalSince(began))
        if remaining>0 {try? await Task.sleep(nanoseconds:UInt64(remaining*1_000_000_000))}
      }
      self?.finishRunner(identity)
    }
    publish()
  }
  func stop() {cancelRunner();session.stop();isStepping=false;publish()}
  func reset() {cancelRunner();session.reset();isStepping=false;lastError=nil;publish()}
  func sourceHistoryChanged() {reset()}
  /// Paused single/bounded step, shared by a native Step action and future MCP.
  /// Native Run must be stopped first, preventing competing ownership.
  func step(frames:Int = 1)async throws {
    guard runner==nil,!isStepping else {throw FormError.invalid("Stop the running cloth study before requesting a manual step.")}
    var candidate=session
    try candidate.start();let work=try candidate.prepare(frames:frames)
    session=candidate;isStepping=true;lastError=nil
    let measured=await Task.detached(priority:.userInitiated) {let t=Date();let result=work.compute();return(result,Date().timeIntervalSince(t)*1000)}.value
    let result=measured.0;maximumWorkerMilliseconds=max(maximumWorkerMilliseconds,measured.1)
    guard session.accept(result) else {throw PreviewError.superseded}
    session.stop();isStepping=false;lastError=result.error;publish()
    if let error=result.error {throw FormError.invalid(error)}
  }
  func stepImmediately(frames:Int = 1)throws {
    guard runner==nil,!isStepping else {throw FormError.invalid("Stop the running cloth study before requesting a manual step.")}
    var candidate=session;try candidate.start();let work=try candidate.prepare(frames:frames),began=Date(),result=work.compute()
    maximumWorkerMilliseconds=max(maximumWorkerMilliseconds,Date().timeIntervalSince(began)*1000)
    guard candidate.accept(result) else {throw PreviewError.superseded}
    candidate.stop();session=candidate;lastError=result.error;publish()
    if let error=result.error {throw FormError.invalid(error)}
  }
  func report(_ error:Error) {
    if case PreviewError.superseded=error {return}
    lastError=error.localizedDescription
  }
  private func nextRunStep(_ identity:UUID)->ClothWorkItem? {
    guard runnerID==identity else {return nil}
    do {return try session.prepare()}
    catch {lastError=error.localizedDescription;session.stop();publish();return nil}
  }
  private func completeRunStep(_ result:ClothWorkResult,identity:UUID)->Double? {
    guard runnerID==identity,session.accept(result) else {return nil}
    lastError=result.error;publish()
    return runnerID==identity && session.frame?.diagnostics.status == .running ? (session.frame?.diagnostics.preparation?.status == .preparing ? 0:frameStepSeconds):nil
  }
  private func finishRunner(_ identity:UUID) {
    guard runnerID==identity else {return}
    runner=nil;runnerID=nil
  }
  private func cancelRunner() {runnerID=nil;runner?.cancel();runner=nil}
  private func publish() {
    let began=Date();defer{maximumPublishMilliseconds=max(maximumPublishMilliseconds,Date().timeIntervalSince(began)*1000)}
    guard let mesh=session.mesh,let frame=session.frame else {diagnostics=nil;return}
    diagnostics=frame.diagnostics;onFrame?(mesh,frame)
  }
}

struct ClothPreviewControls:View {
  @ObservedObject var controller:ClothPreviewController
  var body:some View {
    VStack(alignment:.leading,spacing:10) {
      HStack(spacing:8) {
        Button("Run",systemImage:"play.fill") {perform {try controller.run()}}.disabled(controller.isRunning || controller.isStepping || controller.diagnostics==nil)
        Button("Stop",systemImage:"stop.fill") {controller.stop()}.disabled(!controller.isRunning && !controller.isStepping)
        Button("Step",systemImage:"forward.frame") {Task {do {try await controller.step()}catch {controller.report(error)}}}.disabled(controller.isRunning || controller.isStepping || controller.diagnostics==nil)
        Button("Reset",systemImage:"arrow.counterclockwise") {controller.reset()}.disabled(controller.diagnostics==nil)
      }
      if let d=controller.diagnostics {
        HStack {Text("\(d.elapsedSeconds,format:.number.precision(.fractionLength(2))) s");Text("\(d.vertexCount) vertices");Text("\(d.pinnedCount) pinned")}.font(.caption).monospacedDigit().foregroundStyle(.secondary)
        HStack {Text("Max stretch \(d.maximumStretchRatio,format:.number.precision(.fractionLength(3)))×");Text("Seam gap \(d.maximumSeamGapMm,format:.number.precision(.fractionLength(2))) mm")}.font(.caption).monospacedDigit()
        Text("Minimum length \(d.minimumStructuralRatio,format:.number.precision(.fractionLength(3)))× · P95 length error \(d.structuralP95RelativeError*100,format:.number.precision(.fractionLength(2)))%")
          .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        if let p=d.preparation {
          Text(p.status == .preparing ? "\(d.status == .running ? "Preparing assembly":"Preparation paused") · \(p.passes)/\(p.maximumPasses) passes" : p.status == .pending ? "Source pose · Run prepares the assembly before physical time starts." : p.status == .ready ? "Assembly ready · preparation meets the declared length-error gate." : "Preparation failed · physical time is blocked.")
            .font(.caption).foregroundStyle(p.status == .failed ? Color.red:Color.secondary)
          if p.status != .pending {Text("Candidate length error: \(p.maximumRelativeError*100,format:.number.precision(.fractionLength(2)))% max · \(p.p95RelativeError*100,format:.number.precision(.fractionLength(2)))% P95").font(.caption).monospacedDigit().foregroundStyle(.secondary)}
        }
        if let join=d.initialJoin {
          Text("Initial join projection: \(join.projectedMaximumStructuralRatio,format:.number.precision(.fractionLength(3)))× · before structural relaxation")
            .font(.caption).foregroundStyle(.secondary)
            .help("Records the first projection of initially separate declared panels. Current frame stretch is shown above. Ideal seam and support reactions are not estimated.")
        }
        if d.maximumSurfacePenetrationMm>0.01 {Text("Contact penetration: \(d.maximumSurfacePenetrationMm,format:.number.precision(.fractionLength(3))) mm. Use smaller steps or a finer mesh.").font(.caption).foregroundStyle(.orange)}
        if d.status == .timeLimit {Text("Study time limit reached. Reset to run again.").font(.caption).foregroundStyle(.secondary)}
      }
      if let error=controller.lastError {Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
      Text("Cloth study · declared material parameters, static contacts. Predictive fit and self-collision are not available.").font(.caption).foregroundStyle(.secondary)
    }
  }
  private func perform(_ action:()throws -> Void) {do {try action()}catch {controller.report(error)}}
}

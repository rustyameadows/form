import AppKit
import Combine
import CryptoKit
import FormCore

@MainActor protocol StudioImageGenerationProvider {
  func generate(_ request:StudioGenerationRequest,progress:@escaping(Double)->Void)async throws->[Data]
}

/// A deliberately local visual fixture, not an AI implementation. It neither
/// receives credentials nor owns a transport. Every result identifies the demo.
@MainActor struct LocalStudioImageGenerationProvider:StudioImageGenerationProvider {
  var delayNanoseconds:UInt64=90_000_000
  func generate(_ request:StudioGenerationRequest,progress:@escaping(Double)->Void)async throws->[Data] {
    let input=try StudioGenerationDemoRenderer.prepare(request)
    for step in 1...3 {try await Task.sleep(nanoseconds:delayNanoseconds);try Task.checkCancellation();progress(Double(step)*0.1)}
    if request.options.failureFixture != .none {throw StudioGenerationError.fixture(request.options.failureFixture)}
    var output=[Data]()
    for index in 0..<request.options.count {
      try Task.checkCancellation()
      let png=try StudioGenerationDemoRenderer.render(request,input:input,index:index)
      output.append(png);progress(0.3+0.7*Double(index+1)/Double(request.options.count))
      try await Task.sleep(nanoseconds:delayNanoseconds)
    }
    try Task.checkCancellation()
    return output
  }
}

enum StudioConnectionPreviewState:String {case disconnected,testing,demoReady,authenticationFailed,rateLimited,offline
  var title:String {switch self {case .disconnected:return "Not connected";case .testing:return "Testing local preview";case .demoReady:return "Demo connection ready";case .authenticationFailed:return "Demo authentication error";case .rateLimited:return "Demo rate limit";case .offline:return "Demo offline"}}
}

/// UI state rehearsal only. SecureField contents stay in the view; this API has
/// no secret parameter, credential storage, environment lookup, or client.
@MainActor final class OpenAIConnectionPreviewController:ObservableObject {
  @Published private(set) var state:StudioConnectionPreviewState = .disconnected
  @Published var fixture:StudioGenerationFailureFixture = .none
  @Published private(set) var detail:String?="Local preview only. No credentials or requests are sent."
  private var generation=0
  func useDemoConnection(){generation+=1;state = .demoReady;detail="Demo mode is ready. Images are made locally, with no AI request."}
  func reset(){generation+=1;state = .disconnected;detail="Local preview only. No credentials or requests are sent."}
  func testPreview()async {
    generation+=1;let token=generation,value=fixture;state = .testing
    do {try await Task.sleep(nanoseconds:180_000_000);try Task.checkCancellation()}
    catch {if generation==token {state = .disconnected;detail="Preview test cancelled."};return}
    guard generation==token else{return}
    switch value {case .none:state = .demoReady;case .authentication,.refused:state = .authenticationFailed;case .rateLimit:state = .rateLimited;case .offline:state = .offline}
    detail=value == .none ? "Demo mode is ready. No service was contacted.":value.message
  }
}

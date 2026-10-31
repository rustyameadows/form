import Foundation
import FormCore

enum StudioGenerationModel:String,Codable,CaseIterable {case sunburst="gpt-image-2.5-sunburst",flare="gpt-image-2.5-flare"
  // The raw values are retained for existing local history. These are demo
  // configurations, not verified API model identifiers or availability claims.
  var title:String {self == .sunburst ? "Sunburst · Local demo":"Flare · Local demo"}
}
enum StudioGenerationAspect:String,Codable,CaseIterable {case square,landscape,portrait
  var title:String {rawValue.capitalized}
  var ratio:Double {self == .square ? 1:self == .landscape ? 1.5:2.0/3}
}
enum StudioGenerationSize:String,Codable,CaseIterable {case small,medium,large
  var title:String {rawValue.capitalized}
  var longEdge:Int {self == .small ? 512:self == .medium ? 768:1024}
}
enum StudioGenerationQuality:String,Codable,CaseIterable {case draft,standard,high
  var title:String {rawValue.capitalized}
}
enum StudioGenerationFailureFixture:String,Codable,CaseIterable {case none,authentication,rateLimit,offline,refused
  var title:String {switch self {case .none:return "Successful demo";case .authentication:return "Authentication error";case .rateLimit:return "Rate limit";case .offline:return "Offline";case .refused:return "Refused request"}}
  var message:String {switch self {case .none:return "Local demo completed.";case .authentication:return "Demo authentication failure. No credential was checked.";case .rateLimit:return "Demo rate limit. Retry when ready; no service was contacted.";case .offline:return "Demo offline failure. No network request was attempted.";case .refused:return "Demo refusal. Revise the request to exercise the retry flow."}}
}
struct StudioImageGenerationOptions:Codable,Equatable {
  var model:StudioGenerationModel = .sunburst
  var aspect:StudioGenerationAspect = .landscape
  var size:StudioGenerationSize = .medium
  var quality:StudioGenerationQuality = .high
  var count=1
  var failureFixture:StudioGenerationFailureFixture = .none
  var pixels:(width:Int,height:Int) {let n=size.longEdge;return aspect == .square ? (n,n):aspect == .landscape ? (n,n*2/3):(n*2/3,n)}
  func validate()throws {guard StudioGenerationConfigurationRegistry.counts.contains(count) else{throw FormError.invalid("Choose one, two, or four demo images.")}}
  var redactedMetadata:[String:String] {["model":model.rawValue,"aspect":aspect.rawValue,"size":size.rawValue,"quality":quality.rawValue,"count":String(count),"failure_fixture":failureFixture.rawValue,"transport":"none","mode":"local_demo"]}
}
/// The same local-only choices are used in Studio and Canvas. A future network
/// provider must supply its own verified capabilities rather than reuse these.
enum StudioGenerationConfigurationRegistry {
  static let models=StudioGenerationModel.allCases
  static let aspects=StudioGenerationAspect.allCases
  static let sizes=StudioGenerationSize.allCases
  static let qualities=StudioGenerationQuality.allCases
  static let counts=[1,2,4]
  static let maximumReferences=8
  static let providerLabel="Local demo · no AI request"
}
struct StudioGenerationReference:Codable,Equatable,Identifiable {
  enum Role:String,Codable,CaseIterable {case style,subject,composition;var title:String{rawValue.capitalized}}
  var assetID:UUID,role:Role
  var id:UUID {assetID}
}
enum StudioGenerationPhase:String,Codable {case idle,capturing,queued,preparing,generating,waitingForEditor,writing,finished
  var title:String {switch self {case .idle:return "Ready";case .capturing:return "Capturing scene";case .queued:return "Queued";case .preparing:return "Preparing local demo";case .generating:return "Making demo images";case .waitingForEditor:return "Finish the current edit to place image";case .writing:return "Saving to Library";case .finished:return "Results"}}
}
struct StudioGenerationCapture:Codable,Equatable,Identifiable {
  var id:UUID,createdAt:Date,projectID:UUID,projectName:String
  var scene:StudioComposition,camera:CameraState
  var designSHA256:String,draftSHA256:String
  var inputAssetID:UUID,width:Int,height:Int
  var warnings:[String]
  var context:StudioGenerationInputContext?=nil
  var sceneID:UUID {scene.id}
}
struct StudioGenerationRun:Codable,Equatable,Identifiable {
  enum Status:String,Codable {case running,succeeded,failed,cancelled,stale;var title:String {rawValue.capitalized}}
  var id:UUID,createdAt:Date,completedAt:Date?
  var status:Status,capture:StudioGenerationCapture
  var prompt:String,style:String,references:[StudioGenerationReference],options:StudioImageGenerationOptions
  var outputAssetIDs:[UUID]=[]
  var error:String?
  var isMock=true
  var provider="Local demo · no AI request"
  var inputContext:StudioGenerationInputContext? {capture.context}
}
struct StudioGenerationPromptPreset:Codable,Equatable,Identifiable {
  var id:UUID,name:String,prompt:String
  static var builtins:[Self] {[
    .init(id:UUID(uuidString:"21B6F53F-1DD1-48F9-B89F-933B031E2101")!,name:"Faithful product",prompt:"Create a polished studio product photograph from this scene input. Preserve the products, arrangement, proportions, artwork and readable wording. Improve natural lighting and material realism with a restrained neutral backdrop."),
    .init(id:UUID(uuidString:"21B6F53F-1DD1-48F9-B89F-933B031E2102")!,name:"Soft editorial",prompt:"Use the captured products and arrangement for a soft editorial image. Keep their geometry, branding and colors intact. Add gentle daylight, subtle shadows and a warm, quiet background."),
    .init(id:UUID(uuidString:"21B6F53F-1DD1-48F9-B89F-933B031E2103")!,name:"Bold campaign",prompt:"Create a bold campaign image using the exact products and composition in the scene input. Preserve every product's form, artwork and text. Use a confident colored backdrop, crisp lighting and clear separation."),
    .init(id:UUID(uuidString:"21B6F53F-1DD1-48F9-B89F-933B031E2104")!,name:"Clean catalog",prompt:"Make a clean catalog photograph on a white background with soft contact shadows. Preserve the exact product identities, proportions, arrangement, printed artwork and readable text from the scene input."),
    .init(id:UUID(uuidString:"21B6F53F-1DD1-48F9-B89F-933B031E2105")!,name:"Dramatic light",prompt:"Keep the captured products, geometry, arrangement and branding unchanged. Use directional studio light and a dark restrained backdrop for depth, while keeping every product and its printed artwork clearly legible."),
    .init(id:UUID(uuidString:"21B6F53F-1DD1-48F9-B89F-933B031E2106")!,name:"Material detail",prompt:"Faithfully emphasize the declared material surfaces and existing finishes with natural detailed highlights. Preserve the products, composition, geometry and readable artwork. Do not invent labels, seams, textures or finishes absent from the input.")
  ]}
}
struct StudioGenerationStylePreset:Codable,Equatable,Identifiable {
  var id:UUID,name:String,instructions:String,references:[StudioGenerationReference]
  static var builtins:[Self] {[
    .init(id:UUID(uuidString:"6C24FDC3-0715-48F5-ADDE-7EB0BEB26101")!,name:"Faithful studio",instructions:"Faithful studio lighting, clear product details, restrained background.",references:[]),
    .init(id:UUID(uuidString:"6C24FDC3-0715-48F5-ADDE-7EB0BEB26102")!,name:"Soft editorial",instructions:"Soft editorial light, warm neutral surroundings, gentle contrast and generous space.",references:[]),
    .init(id:UUID(uuidString:"6C24FDC3-0715-48F5-ADDE-7EB0BEB26103")!,name:"Bold backdrop",instructions:"A bold colored backdrop, crisp product silhouette and confident contrast.",references:[])
  ]}
}
enum StudioGenerationError:LocalizedError {
  case fixture(StudioGenerationFailureFixture),stale,invalid(String)
  var errorDescription:String? {switch self {case .fixture(let fixture):return fixture.message;case .stale:return "The scene or project changed. Capture the current composition before creating another image.";case .invalid(let message):return message}}
}
struct StudioGenerationReferenceImage:Equatable {
  let assetID:UUID,name:String,png:Data
}
struct StudioGenerationRequest {
  enum Source:String {case studioScene,canvas}
  let inputPNG:Data?,prompt:String,style:String,references:[StudioGenerationReference],options:StudioImageGenerationOptions
  var context:StudioGenerationInputContext?
  let source:Source,referenceImages:[StudioGenerationReferenceImage]
  init(inputPNG:Data?=nil,prompt:String,style:String,references:[StudioGenerationReference],options:StudioImageGenerationOptions,
    context:StudioGenerationInputContext?=nil,source:Source = .studioScene,referenceImages:[StudioGenerationReferenceImage]=[]) {
    self.inputPNG=inputPNG;self.prompt=prompt;self.style=style;self.references=references;self.options=options
    self.context=context;self.source=source;self.referenceImages=referenceImages
  }
}

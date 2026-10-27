import AppKit
import FormCore
import FormMeshAssets
import LabRendering
import SwiftUI

/// Embed once in RootView.background; it observes the coordinator, not only StudioStore.
struct ModelAssetImportPresenter:View {
  @ObservedObject var coordinator:ModelAssetCoordinator
  let store:StudioStore
  init(store:StudioStore) {self.store=store;coordinator=store.modelAssets}
  var body:some View {Color.clear.frame(width:0,height:0).sheet(item:Binding(get:{coordinator.review},set:{value in
    if value==nil,let current=coordinator.review {coordinator.cancel(current)}else{coordinator.review=value}
  })) {_ in ModelImportView(store:store)}}
}
struct ModelImportView:View {
  @ObservedObject var store:StudioStore
  @ObservedObject private var coordinator:ModelAssetCoordinator
  init(store:StudioStore) {self.store=store;coordinator=store.modelAssets}
  var body:some View {
    if let review=coordinator.review {ModelImportReviewContents(store:store,coordinator:coordinator,review:review)}
    else {Text("No pending model import.").padding(30)}
  }
}
private struct ModelImportReviewContents:View {
  @ObservedObject var store:StudioStore
  @ObservedObject var coordinator:ModelAssetCoordinator
  @ObservedObject var review:ModelImportReview
  var body:some View {
    VStack(alignment:.leading,spacing:16) {
      HStack {
        VStack(alignment:.leading,spacing:4) {
          Text("Import 3D model").font(.system(size: 26, weight: .semibold))
          Text(review.url.lastPathComponent).font(.system(size:12)).foregroundStyle(Palette.secondary)
        }
        Spacer();Button("Cancel") {coordinator.cancel(review)}.keyboardShortcut(.cancelAction)
      }
      HStack {
        TextField("Model name",text:$review.name).textFieldStyle(.roundedBorder)
        Picker("Source units",selection:Binding<String>(get:{review.sourceUnit?.rawValue ?? "declared"},set:{value in review.sourceUnit=MeshSourceUnit(rawValue:value)})) {
          Text(review.url.pathExtension.lowercased()=="stl" ? "Choose units…":"Declared meters").tag("declared")
          ForEach(MeshSourceUnit.allCases,id:\.self){Text($0.rawValue.capitalized).tag($0.rawValue)}
        }.frame(width:260)
        Button(review.state=="choose_units" ? "Read model":"Re-read with units") {coordinator.prepare(review)}.disabled(review.state=="preparing" || review.url.pathExtension.lowercased()=="stl" && review.sourceUnit==nil)
      }.disabled(review.state=="publishing")
      if ["preparing","publishing"].contains(review.state) {HStack{ProgressView().controlSize(.small);Text(review.state=="publishing" ? "Saving immutable source resources…":"Reading mesh parts, materials and source resources…").font(.system(size:12))}.frame(maxWidth:.infinity,minHeight:180)}
      else if let reference=review.reference {
        HStack(alignment:.top,spacing:22) {
          VStack(alignment:.leading,spacing:12) {
            if let scene=review.preparedScene {ModelImportPreview(scene:scene,reference:reference).frame(height:240).background(Color.black.opacity(0.025),in:RoundedRectangle(cornerRadius:10))}
            Label("Imported visual mesh",systemImage:"cube.transparent").font(.system(size:16,weight:.medium))
            Text("View, position, make colorways and map UV artwork. This is a source-preserving visual object; original CAD features, sewing patterns and manufacturing readiness are not inferred.")
              .font(.system(size:12)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
            let size=reference.boundsMM.size
            Text(String(format:"%.2f × %.2f × %.2f mm",size.x,size.y,size.z)).font(.system(size:17,design:.monospaced))
            Text("\(reference.vertexCount.formatted()) vertices · \(reference.triangleCount.formatted()) triangles\n\(reference.parts.count) parts · \(reference.materials.count) material slots")
              .font(.system(size:12)).foregroundStyle(Palette.secondary)
            Text(reference.unitDeclaration+". "+reference.coordinateConvention).font(.system(size:11)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
            Text("Table placement anchors the imported bounds at their bottom center; original source transforms remain retained.").font(.system(size:11)).foregroundStyle(Palette.secondary)
            let notes=reference.warnings+review.renderWarnings
            if !notes.isEmpty {
              Divider();Text("IMPORT NOTES").font(.system(size:10,weight:.semibold)).tracking(1)
              ScrollView {VStack(alignment:.leading,spacing:5){ForEach(Array(Set(notes)).sorted(),id:\.self){Text($0).font(.system(size:10)).foregroundStyle(Palette.accent).fixedSize(horizontal:false,vertical:true)}}}.frame(maxHeight:110)
            }
          }.frame(maxWidth:.infinity,alignment:.leading)
          ScrollView {
            VStack(alignment:.leading,spacing:10) {
              Text("PARTS & MATERIALS").font(.system(size:10,weight:.semibold)).tracking(1)
              ForEach(reference.parts) {part in
                VStack(alignment:.leading,spacing:3) {
                  Text(part.name).font(.system(size:12,weight:.medium))
                  Text("\(part.triangleCount.formatted()) triangles · "+(part.uvSets.isEmpty ? "No UVs":part.uvSets.map{"UV\($0)"}.joined(separator:", "))).font(.system(size:10)).foregroundStyle(Palette.secondary)
                };Divider()
              }
              ForEach(reference.materials) {material in Text(material.name+" · "+material.textureChannels.joined(separator:", ")).font(.system(size:11))}
            }.frame(maxWidth:.infinity,alignment:.leading)
          }.frame(width:290,height:320)
        }
      }else {Text("Choose source units and read the model to inspect its actual geometry before importing.").font(.system(size:13)).foregroundStyle(Palette.secondary).frame(maxWidth:.infinity,minHeight:180)}
      if let error=review.error {Text(error).font(.system(size:12)).foregroundStyle(Palette.ink).fixedSize(horizontal:false,vertical:true)}
      HStack {
        Text("Original files and normalized geometry stay in this project. No hardware is contacted.").font(.system(size:11)).foregroundStyle(Palette.secondary)
        Spacer()
        Button("Import model") {do{try coordinator.commit(review)}catch{review.error=error.localizedDescription}}.buttonStyle(.borderedProminent).tint(Palette.ink).keyboardShortcut(.defaultAction).disabled(review.state != "ready")
      }
    }.padding(28).frame(width:900).background(Palette.paper)
  }
}

struct ModelAssetInspector:View {
  @EnvironmentObject var store:StudioStore
  let object:ProductObject
  @State private var slot=0
  @State private var color=Color.gray
  @State private var colorChanged=false
  @State private var metallic=0.0
  @State private var roughness=0.7
  @State private var sourceID:UUID?
  @State private var error=""
  private var reference:MeshAssetReference? {object.meshAsset}
  private func perform(_ args:[String:Any]) {do{_ = try store.modelAssets.call(args.merging(["object_id":object.id.uuidString]){_,new in new});error=""}catch{self.error=error.localizedDescription}}
  private func synchronizeSlot() {
    guard let reference,let material=reference.materials.first(where:{$0.index==slot}) else{return}
    let override=reference.materialOverrides.first{$0.materialIndex==slot}
    func display(_ value:Double)->Double {
      guard reference.format=="glb" || reference.format=="gltf" else{return value}
      return value<=0.0031308 ? 12.92*value:1.055*pow(value,1/2.4)-0.055
    }
    color=override?.colorHex.map{Color(nsColor:NSColor(hex:$0))} ?? Color(.sRGB,red:display(material.baseColor[0]),green:display(material.baseColor[1]),blue:display(material.baseColor[2]),opacity:material.baseColor[3])
    metallic=override?.metallic ?? material.metallic;roughness=override?.roughness ?? material.roughness
    colorChanged=false
  }
  var body:some View {
    if let reference {
      VStack(alignment:.leading,spacing:12) {
        SectionLabel("IMPORTED VISUAL MESH")
        Text(reference.sourceFileName).font(.system(size:11,weight:.medium)).lineLimit(2)
        let size=reference.boundsMM.size,s=ModelAssetCoordinator.scale(object)
        Text(String(format:"%.1f × %.1f × %.1f mm",size.x*s,size.y*s,size.z*s)).font(.system(size:11,design:.monospaced))
        Text("\(reference.parts.count) parts · \(reference.triangleCount.formatted()) triangles\nUniform scale and placement; source CAD history unavailable.").font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
        if let issue=store.modelAssets.issue(for:object) {
          Text(issue).font(.system(size:10)).foregroundStyle(Palette.ink)
          Button("Retry loading") {store.modelAssets.retry(object,assets:store.repository.url(for:store.project!.id).appendingPathComponent("Assets"))}.font(.system(size:10))
        }
        if !reference.materials.isEmpty {
          Picker("Material slot",selection:$slot) {ForEach(reference.materials){Text($0.name).tag($0.index)}}.font(.system(size:11)).onChange(of:slot){_,_ in synchronizeSlot()}
          ColorPicker("Surface color",selection:Binding(get:{color},set:{color=$0;colorChanged=true}),supportsOpacity:false).font(.system(size:11))
          Text("Textured slots keep their weave contrast in a derived colorway; original texture bytes stay retained.").font(.system(size:9)).foregroundStyle(Palette.secondary)
          HStack{Text("Metallic");Slider(value:$metallic,in:0...1)}.font(.system(size:10))
          HStack{Text("Roughness");Slider(value:$roughness,in:0...1)}.font(.system(size:10))
          HStack {
            Button("Apply material") {
              var args:[String:Any]=["command":"material","material_index":slot,"metallic":metallic,"roughness":roughness]
              if colorChanged {args["color"]=NSColor(color).hexString}
              perform(args)
            }
            Button("Reset") {perform(["command":"material","material_index":slot,"clear":true]);synchronizeSlot()}
          }.font(.system(size:10)).disabled(object.locked)
          Divider()
          Text("UV artwork").font(.system(size:11,weight:.medium))
          Picker("Source",selection:$sourceID) {
            Text("Choose artwork…").tag(UUID?.none)
            ForEach(store.project?.objects.filter{$0.recipeID=="artboard" && !$0.isCanvasWorkspace && $0.artworkSourceID==nil && $0.artwork != nil} ?? []){Text($0.name).tag(Optional($0.id))}
          }.font(.system(size:10))
          HStack {
            Button("Map to this slot") {if let sourceID {perform(["command":"artwork","material_index":slot,"source_object_id":sourceID.uuidString])}}
              .disabled(object.locked || sourceID==nil || !reference.parts.contains{$0.materialIndex==slot && $0.uvSets.contains(0)})
            Button("Clear") {perform(["command":"artwork","material_index":slot,"clear":true])}.disabled(object.locked)
          }.font(.system(size:10))
          Text("UV0 appearance mapping. Physical print size and continuity across seams are unverified. One artwork source drives this object's mapped slots.")
            .font(.system(size:9)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
        }
        DisclosureGroup("Parts and source notes") {
          ForEach(reference.parts){Text($0.name).font(.system(size:9))}
          ForEach(reference.warnings,id:\.self){Text($0).font(.system(size:9)).foregroundStyle(Palette.secondary)}
        }.font(.system(size:10))
        if !error.isEmpty {Text(error).font(.system(size:10)).foregroundStyle(Palette.ink).fixedSize(horizontal:false,vertical:true)}
      }.onAppear {slot=reference.materials.first?.index ?? 0;sourceID=object.artworkSourceID;synchronizeSlot()}
    }
  }
}

private struct ModelImportPreview:NSViewRepresentable {
  let scene:MeshAssetPreparedScene,reference:MeshAssetReference
  @MainActor final class Coordinator {
    var renderer:RealityKitSceneRenderer?
    var key=""
    var task:Task<Void,Never>?
    var id=UUID()
  }
  func makeCoordinator()->Coordinator {Coordinator()}
  func makeNSView(context:Context)->NSView {
    do {let renderer=try RealityKitSceneRenderer(frame:.init(x:0,y:0,width:500,height:240));context.coordinator.renderer=renderer;renderer.nativeView.setAccessibilityLabel("Imported model preview");return renderer.nativeView}
    catch {let text=NSTextField(labelWithString:"3D preview unavailable: "+error.localizedDescription);text.lineBreakMode = .byWordWrapping;return text}
  }
  func updateNSView(_ view:NSView,context:Context) {
    let coordinator=context.coordinator
    guard coordinator.key != reference.normalizedSHA256,let renderer=coordinator.renderer else{return}
    coordinator.key=reference.normalizedSHA256;coordinator.task?.cancel();renderer.reset()
    let size=reference.boundsMM.size,maximum=max(1,max(size.x,max(size.y,size.z))),target=SIMD3<Double>(0,size.y/2,0),camera=SceneCameraPayload.looking(from:target+SIMD3(maximum*0.16,maximum*0.08,maximum*1.8),at:target)
    try? renderer.setCamera(camera);try? renderer.setLighting(.init(background:.init(242.0/255,242.0/255,242.0/255,1)))
    coordinator.task=Task {
      do {let appearance=try MeshAssetSceneAdapter.appearance(scene,reference:reference)
        for payload in MeshAssetSceneAdapter.renderables(appearance,objectID:coordinator.id) {guard !Task.isCancelled else{return};try await renderer.upsertAsync(payload)}
        renderer.requestDraw()
      }catch {view.toolTip=error.localizedDescription}
    }
  }
  static func dismantleNSView(_ view:NSView,coordinator:Coordinator) {coordinator.task?.cancel();coordinator.renderer?.reset();coordinator.renderer=nil}
}

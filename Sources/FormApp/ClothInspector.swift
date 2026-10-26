import SwiftUI
import FormCore
import FormGraphics

struct ClothInspector:View {
  @EnvironmentObject var store:StudioStore
  @ObservedObject var controller:ClothPreviewController
  let object:ProductObject
  @State private var showingSettings=false
  private var study:ClothStudy? {guard let project=store.project else{return nil};return try? AssemblyProducts.study(for:object,in:project)}
  var body:some View {
    VStack(alignment:.leading,spacing:12) {
      SectionLabel("CLOTH STUDY")
      ClothPreviewControls(controller:controller).controlSize(.small)
      Button("Solver & contact settings…") {showingSettings=true}.buttonStyle(.bordered).disabled(object.locked)
      if let study {
        Text("\(study.mesh.triangles.count) triangles · \(study.mesh.massesKg.reduce(0,+)*1000,format:.number.precision(.fractionLength(1))) g declared mass")
          .font(.caption).foregroundStyle(.secondary)
      }
      Text("Initial source is saved. Preview resets on source changes, switching cloth studies, or closing the project.").font(.caption).foregroundStyle(.secondary)
    }
    .onAppear {activate()}.onChange(of:object.id) {_,_ in activate()}
    .sheet(isPresented:$showingSettings) {if let study {ClothSettingsEditor(objectID:object.id,settings:study.settings).environmentObject(store)}}
  }
  private func activate() {do {try store.cloth.activate(object.id)}catch {controller.report(error)}}
}

private struct ClothSettingsEditor:View {
  @EnvironmentObject var store:StudioStore
  @Environment(\.dismiss) private var dismiss
  let objectID:UUID
  @State var settings:ClothSettings
  @State private var error:String?
  var body:some View {
    VStack(alignment:.leading,spacing:18) {
      Text("Cloth settings").font(.title2)
      Text("Declared distance-constraint parameters. These are not calibrated fabric measurements.").font(.callout).foregroundStyle(.secondary)
      Form {
        Section("Fixed integration") {
          value("Frame step (seconds)",value:$settings.frameStepSeconds)
          Stepper("Substeps: \(settings.substeps)",value:$settings.substeps,in:1...16)
          Stepper("Iterations: \(settings.iterations)",value:$settings.iterations,in:1...24)
          value("Maximum study duration (seconds)",value:$settings.maximumSimulationSeconds)
          value("Velocity damping (per second)",value:$settings.velocityDampingPerSecond)
        }
        Section("Distance compliance (m/N)") {
          value("Warp",value:$settings.warpComplianceMPerN);value("Weft",value:$settings.weftComplianceMPerN)
          value("Shear",value:$settings.shearComplianceMPerN);value("Distance bending proxy",value:$settings.bendDistanceComplianceMPerN)
          value("Seams",value:$settings.seamComplianceMPerN)
        }
        Section("Gravity and static contacts") {
          value("Gravity X (m/s²)",value:$settings.gravityMPerSecondSquared.x);value("Gravity Y (m/s²)",value:$settings.gravityMPerSecondSquared.y);value("Gravity Z (m/s²)",value:$settings.gravityMPerSecondSquared.z)
          value("Contact thickness (mm)",value:$settings.collisionThicknessMm);value("Friction coefficient",value:$settings.friction)
        }
      }.formStyle(.grouped)
      if let error {Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)}
      HStack {Text("Apply resets the preview and is undoable.").font(.caption).foregroundStyle(.secondary);Spacer();Button("Cancel") {dismiss()};Button("Apply") {save()}.buttonStyle(.borderedProminent)}
    }.padding(24).frame(width:560,height:700)
  }
  private func value(_ label:String,value:Binding<Double>)->some View {TextField(label,value:value,format:.number.precision(.fractionLength(0...12))).textFieldStyle(.roundedBorder)}
  private func save() {
    do {try settings.validate();store.finishArtworkEditing();_ = try store.clothCall(["command":"configure","object_id":objectID.uuidString,"settings":try jsonObject(settings)],source:"Studio");store.changed();dismiss()}catch {self.error=error.localizedDescription}
  }
}

struct ClothAttachmentInspector:View {
  @EnvironmentObject var store:StudioStore
  let object:ProductObject
  let project:Project
  private var surfaces:[ProductObject] {project.objects.filter {$0.isFlexibleSurface && $0.id != object.id}}
  private var attachment:ClothAttachment? {object.clothAttachment}
  private var assemblyAttachment:PatternAssemblyAttachment? {object.patternAssemblyAttachment}
  private var surface:ProductObject? {surfaces.first {$0.id==(assemblyAttachment?.surfaceObjectID ?? attachment?.surfaceObjectID)}}
  private var assemblyProduct:PatternAssemblyProduct? {guard let surface else{return nil};return try? AssemblyProducts.product(for:surface,in:project)}
  private var assemblyPanel:PatternAssemblyPanel? {assemblyProduct?.panels.first{$0.id==assemblyAttachment?.anchor.panel}}
  private var assemblyIssue:String? {
    guard let attachment=assemblyAttachment else{return nil}
    guard let product=assemblyProduct else{return "The source assembly is invalid. Repair the original pattern or choose another surface."}
    do {_ = try attachment.anchor.resolve(in:product);return nil}catch{return error.localizedDescription}
  }
  private var point:Point2 {
    if let a=assemblyAttachment,let p=assemblyPanel {return .init(a.anchor.materialPointMm.x/p.materialSizeMm.x,a.anchor.materialPointMm.y/p.materialSizeMm.y)}
    guard let surface,let anchor=attachment?.anchor else {return .init(0.5,0.5)};return (try? surface.cloth?.mesh.materialPoint(anchor)) ?? .init(0.5,0.5)
  }
  var body:some View {
    if !surfaces.isEmpty {
      VStack(alignment:.leading,spacing:10) {
        SectionLabel("CLOTH PLACEMENT")
        Picker("Surface",selection:Binding<UUID?>(get:{assemblyAttachment?.surfaceObjectID ?? attachment?.surfaceObjectID},set:{id in if let id {attach(to:id)}else {change(["command":"detach"])}})) {
          Text("Independent on Table").tag(UUID?.none)
          ForEach(surfaces) {surface in Text(surface.name).tag(Optional(surface.id))}
        }.disabled(object.locked || object.textile?.attachment != nil)
        if let issue=assemblyIssue {Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
        if let a=assemblyAttachment,let surface,let product=assemblyProduct,let panel=assemblyPanel {
          Picker("Panel",selection:Binding(get:{panel.panelIndex},set:{attach(to:surface.id,panel:$0)})) {ForEach(product.panels,id:\.panelIndex) {p in Text("\(p.name) / copy \(p.id.copy)").tag(p.panelIndex)}}
          coordinate("Across (mm)",value:a.anchor.materialPointMm.x) {attach(to:surface.id,u:$0/panel.materialSizeMm.x)}
          coordinate("Down (mm)",value:a.anchor.materialPointMm.y) {attach(to:surface.id,v:$0/panel.materialSizeMm.y)}
          coordinate("Clearance (mm)",value:a.anchor.normalOffsetMm) {attach(to:surface.id,offset:$0)}
          coordinate("Angle (°)",value:a.rotationDegrees) {attach(to:surface.id,rotation:$0)}
          Button("Detach to Table") {change(["command":"detach"])}.buttonStyle(.borderless).disabled(object.locked)
          Text("Saved against the original panel's physical material point; derived triangle IDs can change.").font(.caption).foregroundStyle(.secondary)
        } else if let attachment,let surface,let mesh=surface.cloth?.mesh {
          let panels=Array(Set(mesh.panelIDs ?? [0])).sorted(),panel=mesh.panelID(forTriangle:attachment.anchor.triangle)
          if panels.count>1 {Picker("Panel",selection:Binding(get:{panel},set:{v in attach(to:surface.id,panel:v)})) {ForEach(panels,id:\.self) {p in Text("Panel \(p+1)").tag(p)}}}
          coordinate("Across (%)",value:point.x*100) {attach(to:surface.id,u:$0/100)}
          coordinate("Down (%)",value:point.y*100) {attach(to:surface.id,v:$0/100)}
          coordinate("Clearance (mm)",value:attachment.anchor.normalOffsetMm) {attach(to:surface.id,offset:$0)}
          coordinate("Angle (°)",value:attachment.rotationDegrees) {attach(to:surface.id,rotation:$0)}
          Button("Detach to Table") {change(["command":"detach"])}.buttonStyle(.borderless).disabled(object.locked)
          Text("The attachment follows this material point at its physical size.").font(.caption).foregroundStyle(.secondary)
        }
      }.font(.system(size:11))
    }
  }
  private func coordinate(_ label:String,value:Double,change:@escaping(Double)->Void)->some View {HStack {Text(label);Spacer();TextField(label,value:Binding(get:{value},set:change),format:.number.precision(.fractionLength(0...2))).textFieldStyle(.roundedBorder).frame(width:72)}.disabled(object.locked)}
  private func attach(to id:UUID,u:Double? = nil,v:Double? = nil,panel:Int? = nil,offset:Double? = nil,rotation:Double? = nil) {
    let currentPanel=assemblyPanel?.panelIndex ?? surface?.cloth?.mesh.panelID(forTriangle:attachment?.anchor.triangle ?? 0) ?? 0
    change(["command":"attach","surface_object_id":id.uuidString,"u":u ?? point.x,"v":v ?? point.y,"panel":panel ?? currentPanel,"offset_mm":offset ?? assemblyAttachment?.anchor.normalOffsetMm ?? attachment?.anchor.normalOffsetMm ?? 1,"rotation":rotation ?? assemblyAttachment?.rotationDegrees ?? attachment?.rotationDegrees ?? 0])
  }
  private func change(_ values:[String:Any]) {do {var args=values;args["object_id"]=object.id.uuidString;_ = try store.clothCall(args,source:"Studio");store.changed()}catch {store.error=error.localizedDescription}}
}

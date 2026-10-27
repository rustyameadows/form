import AppKit
import SwiftUI
import FormCore
import FormGraphics

struct PatternAssemblyInspector:View {
  @EnvironmentObject var store:StudioStore
  let object:ProductObject
  @State private var editing=false
  var body:some View {
    if let definition=object.patternAssembly {
      VStack(alignment:.leading,spacing:10) {
        Text("Original pattern assembly").font(.headline)
        Text("\(definition.panels.count) panels · \(definition.seamIDs.count) source seams · \(definition.pins.count) declared supports").font(.caption).foregroundStyle(.secondary)
        Button("Panels, seams & supports…") {editing=true}.accessibilityLabel("Edit assembly panels seams and supports").disabled(object.locked)
        Button("Edit original pattern on Canvas") {
          store.showSurface(.artwork);store.artworkSession.activate(definition.sourceObjectID)
        }.accessibilityLabel("Edit original assembly pattern on Canvas")
        if let issue=store.scene?.diagnostics["cloth_issues"] as? [String:String],let message=issue[object.id.uuidString] {Text(message).font(.caption).foregroundStyle(Palette.ink).textSelection(.enabled)}
        Text("Open cloth · original stitch contours and explicit poses. No self-collision, calibrated fit or zipper simulation.").font(.caption).foregroundStyle(.secondary)
      }.sheet(isPresented:$editing) {PatternAssemblyEditor(objectID:object.id,definition:definition).environmentObject(store)}
    }
  }
}

struct PatternAssemblyEditor:View {
  @EnvironmentObject var store:StudioStore
  @Environment(\.dismiss) private var dismiss
  let objectID:UUID
  @State var definition:PatternAssemblyDefinition
  @State private var issue:String?
  private var source:Artwork? {store.project?.objects.first(where:{$0.id==definition.sourceObjectID})?.artwork}
  private var fabrics:[FormCore.Material] {
    var values=store.materials.filter{$0.category=="Fabric"}
    for panel in definition.panels where !values.contains(where:{$0.id==panel.material.id}) {values.append(panel.material)}
    return values
  }
  var body:some View {
    VStack(alignment:.leading,spacing:16) {
      Text("Pattern assembly").font(.title2)
      Text("Original material dimensions stay fixed. Arrange rigid panels and choose explicitly paired source seams; Apply rebuilds the derived surface as one undoable edit.").font(.callout).foregroundStyle(.secondary)
      TabView {
        Form {ForEach(definition.panels.indices,id:\.self) {i in panel(i)}}.formStyle(.grouped).tabItem {Text("Panels")}
        Form {
          Section("Paired source seams") {
            if let source {ForEach(source.sewingSeams ?? []) {seam in
              Toggle(isOn:Binding(get:{definition.seamIDs.contains(seam.id)},set:{enabled in if enabled {definition.seamIDs.append(seam.id)}else {definition.seamIDs.removeAll{$0==seam.id}}})) {
                VStack(alignment:.leading) {Text(seam.name);Text("Edge \(seam.first.edge+1), copy \(seam.first.copy) ↔ edge \(seam.second.edge+1), copy \(seam.second.copy) · \(seam.reversed ? "reversed":"same arc direction")").font(.caption).foregroundStyle(.secondary)}
              }
            }}
            Text("Correspondence and direction belong to the original pattern's Pair seam edges editor.").font(.caption).foregroundStyle(.secondary)
          }
          Section("Declared supports") {
            ForEach(definition.pins.indices,id:\.self) {i in pin(i)}
            Button("Add source-edge support") {addPin()}
          }
        }.formStyle(.grouped).tabItem {Text("Seams & supports")}
        Form {
          Section("Physical approximation") {
            scalar("Maximum edge (mm)",value:$definition.maximumEdgeMm)
            scalar("Boundary deviation (mm)",value:$definition.boundaryToleranceMm)
            Stepper("Vertex limit: \(definition.maximumVertices)",value:$definition.maximumVertices,in:128...4096,step:128)
            Text("Source curves remain original. Finer derived meshes consume more of the explicit work budget; exhausted budgets reject the rebuild.").font(.caption).foregroundStyle(.secondary)
          }
          Section("Limits") {Text("No self-collision, inferred garment construction, air pressure, calibrated fabric properties or verified fit. Supports and static contacts are explicit. Solver parameters are edited in Cloth settings.").font(.callout).foregroundStyle(.secondary)}
        }.formStyle(.grouped).tabItem {Text("Mesh & limits")}
      }
      if let issue {Text(issue).font(.caption).foregroundStyle(Palette.ink).textSelection(.enabled)}
      HStack {Text("Current motion is transient and resets on Apply.").font(.caption).foregroundStyle(.secondary);Spacer();Button("Cancel") {dismiss()};Button("Apply") {save()}.buttonStyle(.borderedProminent).accessibilityLabel("Apply assembly declaration")}
    }.padding(24).frame(width:680,height:760)
  }
  private func title(_ id:PatternPanelID)->String {let e=source?.elements.first{$0.id==id.elementID};return "\(e?.sewingPiece?.name ?? "Source piece") / copy \(id.copy)"}
  private func panel(_ i:Int)->some View {
    Section(title(definition.panels[i].panel)) {
      Picker("Fabric assignment",selection:Binding(get:{definition.panels[i].material.id},set:{id in if let value=fabrics.first(where:{$0.id==id}) {definition.panels[i].material=value}})) {ForEach(fabrics) {Text($0.name).tag($0.id)}}
      scalar("Declared areal mass (GSM)",value:$definition.panels[i].densityGSM)
      vector("Origin (mm)",value:$definition.panels[i].pose.originMm)
      vector("Rotation (degrees)",value:Binding(get:{definition.panels[i].pose.eulerDegrees},set:{definition.panels[i].pose.setEulerDegrees($0)}))
      Toggle("Reverse material face",isOn:Binding(get:{definition.panels[i].pose.materialFront==1},set:{definition.panels[i].pose.materialFront=$0 ? 1:-1}))
      scalar("Fabric origin X (mm)",value:$definition.panels[i].textureOriginMm.x);scalar("Fabric origin Y (mm)",value:$definition.panels[i].textureOriginMm.y)
    }
  }
  private func pin(_ i:Int)->some View {
    VStack(alignment:.leading,spacing:8) {
      HStack {Picker("Panel",selection:Binding(get:{definition.pins[i].panel},set:{id in changePinPanel(i,id)})) {ForEach(definition.panels,id:\.panel) {panel in Text(title(panel.panel)).tag(panel.panel)}};Spacer();Button("Remove") {definition.pins.remove(at:i)}}
      if let e=source?.elements.first(where:{$0.id==definition.pins[i].panel.elementID}),let source,let edges=try? SewingCurves.boundaries(e,in:source).flatMap(\.edges) {
        Picker("Original edge",selection:Binding(get:{definition.pins[i].edgeID},set:{id in if let edge=edges.first(where:{$0.id==id}),let end=edge.endID {definition.pins[i].edgeID=id;definition.pins[i].endID=end}})) {ForEach(edges.filter{$0.id != nil},id:\.id) {edge in Text("Edge \(edge.index+1) · \(edge.length,format:.number.precision(.fractionLength(1))) mm").tag(edge.id!)}}
      }
      scalar("Arc fraction (0–1)",value:$definition.pins[i].fraction)
      Toggle("Explicit world target",isOn:Binding(get:{definition.pins[i].targetMm != nil},set:{definition.pins[i].targetMm=$0 ? initialTarget(i):nil}))
      if definition.pins[i].targetMm != nil {vector("Target (mm)",value:Binding(get:{definition.pins[i].targetMm!},set:{definition.pins[i].targetMm=$0}))}
    }
  }
  private func initialTarget(_ i:Int)->Vector3 {
    guard let panel=definition.panels.first(where:{$0.panel==definition.pins[i].panel}),let source,let e=source.elements.first(where:{$0.id==panel.panel.elementID}),let boundaries=try? SewingCurves.boundaries(e,in:source),let edge=boundaries.flatMap(\.edges).first(where:{$0.id==definition.pins[i].edgeID}) else {return .init()}
    let p=edge.sample(fraction:definition.pins[i].fraction).point,points=boundaries.flatMap(\.points),origin=Point2(points.map(\.x).min()!,points.map(\.y).min()!)
    return panel.pose.point(.init(p.x-origin.x,p.y-origin.y))
  }
  private func changePinPanel(_ i:Int,_ id:PatternPanelID) {
    guard let source,let e=source.elements.first(where:{$0.id==id.elementID}),let edge=try? SewingCurves.boundaries(e,in:source).filter({!$0.isHole}).flatMap(\.edges).first,let edgeID=edge.id,let endID=edge.endID else {return}
    definition.pins[i].panel=id;definition.pins[i].edgeID=edgeID;definition.pins[i].endID=endID
  }
  private func addPin() {
    guard let panel=definition.panels.first,let source,let e=source.elements.first(where:{$0.id==panel.panel.elementID}),let edge=try? SewingCurves.boundaries(e,in:source).filter({!$0.isHole}).flatMap(\.edges).first,let id=edge.id,let end=edge.endID else {return}
    definition.pins.append(.init(panel:panel.panel,edgeID:id,endID:end,fraction:0.5))
  }
  private func scalar(_ label:String,value:Binding<Double>)->some View {TextField(label,value:value,format:.number.precision(.fractionLength(0...8))).textFieldStyle(.roundedBorder)}
  private func vector(_ label:String,value:Binding<Vector3>)->some View {HStack {Text(label);Spacer();scalar("X",value:value.x);scalar("Y",value:value.y);scalar("Z",value:value.z)}}
  private func save() {
    NSApp.keyWindow?.makeFirstResponder(nil)
    do {store.finishArtworkEditing();_ = try store.clothCall(["command":"configure","object_id":objectID.uuidString,"assembly":try jsonObject(definition)],source:"Studio");store.changed();dismiss()}catch {issue=error.localizedDescription}
  }
}

extension StudioStore {
  func createPatternAssembly(sourceID:UUID) {
    do {finishArtworkEditing();_ = try clothCall(["command":"assemble","object_id":sourceID.uuidString],source:"Studio");showSurface(.table);changed()}catch {self.error=error.localizedDescription}
  }
}

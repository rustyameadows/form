import FormCore
import SwiftUI

struct TextileInspector: View {
  @EnvironmentObject var store:StudioStore
  let object:ProductObject
  let project:Project
  @State private var showingEmbroidery=false
  @State private var showingProduction=false
  private var spec:TextileProduct {object.textile ?? TextileProduct.defaults(for:object.recipeID)!}
  private func update(_ change:(inout TextileProduct)->Void) {
    var value=spec;change(&value)
    do {store.update(object,["textile":try jsonObject(value)])} catch {store.error=error.localizedDescription}
  }
  private var availableZones:[TextileAttachment.Zone] {
    guard let id=spec.attachment?.garmentID,let host=project.objects.first(where:{$0.id==id}) else{return []}
    if MerchandiseBlanks.garmentIDs.contains(host.recipeID){return MerchandiseBlanks.zones(host).map(\.id)}
    return [.leftChest,.rightChest,.leftSleeve,.rightSleeve,.collar,.back]
  }
  private func regionName(_ zone:TextileAttachment.Zone)->String {
    guard let id=spec.attachment?.garmentID,let host=project.objects.first(where:{$0.id==id}) else{return zone.name}
    return MerchandiseBlanks.zones(host).first(where:{$0.id==zone})?.name ?? zone.name
  }
  var body:some View {
    VStack(alignment:.leading,spacing:12) {
      SectionLabel(spec.kind == .garment ? "GARMENT BLANK":"TEXTILE COMPONENT")
      Text(spec.measurementsVerified ? "Declared measurements verified":"Concept measurements · verify a physical sample")
        .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      if spec.kind == .garment {
        if MerchandiseBlanks.garmentIDs.contains(object.recipeID), object.recipeID != "curvedCap" {Toggle("Show back",isOn:Binding(get:{spec.laidFaceDown ?? false},set:{v in update{$0.laidFaceDown=v}}))}
        if MerchandiseBlanks.garmentIDs.contains(object.recipeID) {
          ForEach(MerchandiseBlanks.zones(object),id:\.id) {zone in Text(String(format:"%@ · %.1f × %.1f mm",zone.name,zone.width,zone.height)).font(.system(size:9)).foregroundStyle(Palette.secondary)}
          Text("Independent decoration regions; sewing patterns and cloth studies remain separate.").font(.system(size:9)).foregroundStyle(Palette.secondary)
        }

        Picker("Trim fabric",selection:Binding(get:{spec.trimMaterialID ?? TextileProduct.defaults(for:object.recipeID)?.trimMaterialID ?? object.materialID},set:{v in update{$0.trimMaterialID=v}})) {ForEach(store.materials.filter{$0.fabric != nil}){m in Text(m.name).tag(m.id)}}
        TextField("Blank / product name",text:Binding(get:{spec.blankName ?? ""},set:{v in update{$0.blankName=v}})).textFieldStyle(InspectorTextFieldStyle())
        TextField("Size",text:Binding(get:{spec.size ?? ""},set:{v in update{$0.size=v}})).textFieldStyle(InspectorTextFieldStyle())
      } else {
        if object.recipeID=="textilePrint" {
          Text("Direct surface artwork").font(.system(size:11,weight:.medium))
          Text("Artwork colors come from the linked source. Cap regions follow the actual curved crown.").font(.system(size:9)).foregroundStyle(Palette.secondary)
        } else {
        Picker("Process",selection:Binding(get:{spec.process},set:{v in update{$0.process=v}})) {
          ForEach(TextileProduct.Process.allCases.filter{$0 != .decoratedBlank && $0 != .directPrint},id:\.self) {p in Text(p.name).tag(p)}
        }
        TextField("Border treatment",text:Binding(get:{spec.border ?? ""},set:{v in update{$0.border=v}})).textFieldStyle(InspectorTextFieldStyle())
        TextField("Backing",text:Binding(get:{spec.backing ?? ""},set:{v in update{$0.backing=v}})).textFieldStyle(InspectorTextFieldStyle())
        TextField("Attachment method",text:Binding(get:{spec.attachmentMethod ?? ""},set:{v in update{$0.attachmentMethod=v}})).textFieldStyle(InspectorTextFieldStyle())
        }
        Picker("Garment",selection:Binding<UUID?>(get:{spec.attachment?.garmentID},set:{id in
          if let id,let host=project.objects.first(where:{$0.id==id}) {update{$0.attachment = .init(garmentID:id,zone:MerchandiseBlanks.zones(host).first?.id ?? .leftChest,clearance:object.recipeID=="textilePrint" ? 0:1)}}
          else {
            let placement=project.detachedTextilePlacement(object)
            var value=spec;value.attachment=nil;value.laidFaceDown=placement.underside
            do {store.update(object,["textile":try jsonObject(value),"position":[placement.position.x,placement.position.y,placement.position.z],"rotation":placement.rotation])} catch {store.error=error.localizedDescription}
          }
        })) {
          Text("Independent on Table").tag(UUID?.none)
          ForEach(project.objects.filter{$0.recipeID=="bomberJacket" && object.recipeID != "textilePrint" || MerchandiseBlanks.garmentIDs.contains($0.recipeID) && ($0.recipeID != "curvedCap" || object.recipeID=="textilePrint")}) {g in Text(g.name).tag(Optional(g.id))}
        }
        if let attachment=spec.attachment {
          Picker("Region",selection:Binding(get:{attachment.zone},set:{zone in update{$0.attachment?.zone=zone}})) {
            ForEach(availableZones,id:\.self) {zone in Text(regionName(zone)).tag(zone)}
          }
          HStack {
            PlacementField("Across",value:attachment.offset.x) {v in update{$0.attachment?.offset.x=v}}
            PlacementField("Down",value:attachment.offset.y) {v in update{$0.attachment?.offset.y=v}}
          }
          HStack {
            Text("Angle");Spacer()
            TextField("Attachment angle",value:Binding(get:{attachment.rotation},set:{v in update{$0.attachment?.rotation=v}}),format:.number.precision(.fractionLength(0...1)))
              .textFieldStyle(InspectorTextFieldStyle()).frame(width:70)
            Text("°").foregroundStyle(Palette.secondary)
          }
          Button("Focus garment") {
            store.select(attachment.garmentID);store.scene?.focusSelection()
          }.buttonStyle(.borderless)
        }
        if object.supportsArtworkFace {DecorationPreparationAction(store:store,objectID:object.id).buttonStyle(.borderless)}
        if [.embroideredPatch,.directEmbroidery].contains(spec.process) || spec.embroidery != nil {
          Button(spec.embroidery == nil ? "Digitize embroidery…":"Edit stitch program…") {showingEmbroidery=true}
            .buttonStyle(.bordered).disabled(object.locked)
          if spec.embroidery != nil {Button("Production jobs & packet…") {showingProduction=true}.buttonStyle(.borderless)}
          if let issue=store.scene?.embroideryIssue(for:object.id) {
            Text("Embroidery needs attention: "+issue).font(.system(size:10)).foregroundStyle(Palette.ink).fixedSize(horizontal:false,vertical:true)
          }
          Text(spec.embroidery == nil ? "Artwork appearance study. Configure digitizing to generate actual stitches.":"Actual stitches drive the physical face. Open Embroidery for needle paths, process settings, hoop checks, and DST output.")
            .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
        }
      }
      if object.recipeID != "textilePrint" {
      Picker("Fabric",selection:Binding(get:{object.materialID},set:{store.update(object,["material_id":$0])})) {
        ForEach(store.materials.filter{$0.fabric != nil}) {material in Text(material.name).tag(material.id)}
      }
      if let fabric=project.material(object.materialID).fabric {
        Text([fabric.composition,fabric.weightGSM.map{String(format:"%.0f GSM",$0)},fabric.usableWidth.map{String(format:"%.0f mm usable width",$0)}].compactMap{$0}.joined(separator:" · "))
          .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      }
      }
      TextField("Product / process notes",text:Binding(get:{spec.notes ?? ""},set:{v in update{$0.notes=v}}),axis:.vertical)
        .lineLimit(2...5).textFieldStyle(InspectorTextFieldStyle())
    }.font(.system(size:11))
      .sheet(isPresented:$showingEmbroidery) {EmbroideryEditor(object:object,project:project).environmentObject(store)}
      .sheet(isPresented:$showingProduction) {ProductionJobsView(objectID:object.id).environmentObject(store)}
  }
}

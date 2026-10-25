import FormCore
import SwiftUI

struct TextileInspector: View {
  @EnvironmentObject var store:StudioStore
  let object:ProductObject
  let project:Project
  @State private var showingEmbroidery=false
  private var spec:TextileProduct {object.textile ?? TextileProduct.defaults(for:object.recipeID)!}
  private func update(_ change:(inout TextileProduct)->Void) {
    var value=spec;change(&value)
    do {store.update(object,["textile":try jsonObject(value)])} catch {store.error=error.localizedDescription}
  }
  var body:some View {
    VStack(alignment:.leading,spacing:12) {
      SectionLabel(spec.kind == .garment ? "GARMENT BLANK":"TEXTILE COMPONENT")
      Text(spec.measurementsVerified ? "Declared measurements verified":"Concept measurements · verify a physical sample")
        .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      if spec.kind == .garment {
        TextField("Blank / product name",text:Binding(get:{spec.blankName ?? ""},set:{v in update{$0.blankName=v}})).textFieldStyle(.roundedBorder)
        TextField("Size",text:Binding(get:{spec.size ?? ""},set:{v in update{$0.size=v}})).textFieldStyle(.roundedBorder)
      } else {
        Picker("Process",selection:Binding(get:{spec.process},set:{v in update{$0.process=v}})) {
          ForEach(TextileProduct.Process.allCases.filter{$0 != .decoratedBlank},id:\.self) {p in Text(p.name).tag(p)}
        }
        TextField("Border treatment",text:Binding(get:{spec.border ?? ""},set:{v in update{$0.border=v}})).textFieldStyle(.roundedBorder)
        TextField("Backing",text:Binding(get:{spec.backing ?? ""},set:{v in update{$0.backing=v}})).textFieldStyle(.roundedBorder)
        TextField("Attachment method",text:Binding(get:{spec.attachmentMethod ?? ""},set:{v in update{$0.attachmentMethod=v}})).textFieldStyle(.roundedBorder)
        Picker("Garment",selection:Binding<UUID?>(get:{spec.attachment?.garmentID},set:{id in
          if let id {update{$0.attachment = .init(garmentID:id,zone:.leftChest)}}
          else {
            let placement=project.textilePlacement(object)
            var value=spec;value.attachment=nil;value.laidFaceDown=placement.underside
            do {store.update(object,["textile":try jsonObject(value),"position":[placement.position.x,placement.position.y,placement.position.z],"rotation":placement.rotation])} catch {store.error=error.localizedDescription}
          }
        })) {
          Text("Independent on Table").tag(UUID?.none)
          ForEach(project.objects.filter{$0.recipeID=="bomberJacket"}) {g in Text(g.name).tag(Optional(g.id))}
        }
        if let attachment=spec.attachment {
          Picker("Region",selection:Binding(get:{attachment.zone},set:{zone in update{$0.attachment?.zone=zone}})) {
            ForEach(TextileAttachment.Zone.allCases,id:\.self) {zone in Text(zone.name).tag(zone)}
          }
          HStack {
            PlacementField("Across",value:attachment.offset.x) {v in update{$0.attachment?.offset.x=v}}
            PlacementField("Down",value:attachment.offset.y) {v in update{$0.attachment?.offset.y=v}}
          }
          HStack {
            Text("Angle");Spacer()
            TextField("Attachment angle",value:Binding(get:{attachment.rotation},set:{v in update{$0.attachment?.rotation=v}}),format:.number.precision(.fractionLength(0...1)))
              .textFieldStyle(.roundedBorder).frame(width:70)
            Text("°").foregroundStyle(Palette.secondary)
          }
          Button("Focus garment") {
            store.select(attachment.garmentID);store.scene?.focusSelection()
          }.buttonStyle(.borderless)
        }
        if [.embroideredPatch,.directEmbroidery].contains(spec.process) || spec.embroidery != nil {
          Button(spec.embroidery == nil ? "Digitize embroidery…":"Edit stitch program…") {showingEmbroidery=true}
            .buttonStyle(.bordered).disabled(object.locked)
          Text(spec.embroidery == nil ? "Artwork appearance study. Configure digitizing to generate actual stitches.":"Regenerable stitch source configured. Open Embroidery for actual needle paths, hoop checks, and DST output.")
            .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
        }
      }
      Picker("Fabric",selection:Binding(get:{object.materialID},set:{store.update(object,["material_id":$0])})) {
        ForEach(store.materials.filter{$0.fabric != nil}) {material in Text(material.name).tag(material.id)}
      }
      if let fabric=project.material(object.materialID).fabric {
        Text([fabric.composition,fabric.weightGSM.map{String(format:"%.0f GSM",$0)},fabric.usableWidth.map{String(format:"%.0f mm usable width",$0)}].compactMap{$0}.joined(separator:" · "))
          .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      }
      TextField("Product / process notes",text:Binding(get:{spec.notes ?? ""},set:{v in update{$0.notes=v}}),axis:.vertical)
        .lineLimit(2...5).textFieldStyle(.roundedBorder)
    }.font(.system(size:11))
      .sheet(isPresented:$showingEmbroidery) {EmbroideryEditor(object:object,project:project).environmentObject(store)}
  }
}

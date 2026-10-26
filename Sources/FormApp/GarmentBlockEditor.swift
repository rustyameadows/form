import FormCore
import SwiftUI

struct GarmentBlockEditor:View {
  @EnvironmentObject var store:StudioStore
  @Environment(\.dismiss) private var dismiss
  @StateObject private var controller:GarmentBlockController
  @StateObject private var review=PhysicalDocumentController()
  init(session:ArtworkSession,controller:GarmentBlockController?=nil) {
    _controller=StateObject(wrappedValue:controller ?? GarmentBlockController(session:session))
  }
  var body:some View {
    VStack(alignment:.leading,spacing:13) {
      HStack {
        Text("Garment blocks and sizes").font(.system(size:24,design:.serif))
        Spacer()
        Picker("Block",selection:Binding(get:{controller.blockID},set:{controller.select($0)})) {
          Text("New original block").tag(Optional<UUID>.none)
          ForEach(controller.blocks){Text($0.name).tag(Optional($0.id))}
        }.frame(width:320).accessibilityLabel("Managed garment block")
        Button("Done"){dismiss()}.keyboardShortcut(.cancelAction)
      }
      Text("Field gathered skirt · declared body measurements, nominal finished dimensions and full raw sewing extents. Construction guidance; fit, elastic behavior and sew-out are unverified.")
        .font(.system(size:10)).foregroundStyle(Palette.secondary)
      HStack(alignment:.top,spacing:20) {
        GarmentBlockDraftControls(draft:controller.draft,materials:store.materials,onChange:{controller.refreshPreview()})
          .frame(width:350)
        VStack(alignment:.leading,spacing:10) {
          Text("Proposed size pages · source changes only when applied").font(.system(size:11,weight:.medium))
          if let proof=controller.proof {
            PhysicalDocumentNavigation(controller:review)
            PhysicalDocumentCanvas(controller:review,data:proof,identifier:controller.identity)
              .frame(maxWidth:.infinity,maxHeight:.infinity).clipShape(RoundedRectangle(cornerRadius:6))
          } else {
            ContentUnavailableView("No valid proposal",systemImage:"scissors",description:Text(controller.error))
              .frame(maxWidth:.infinity,maxHeight:.infinity)
          }
          ScrollView {
            VStack(alignment:.leading,spacing:7) {
              ForEach(controller.resolved,id:\.sizeID) {size in
                HStack {
                  VStack(alignment:.leading,spacing:2) {
                    Text(size.label).fontWeight(.medium).lineLimit(1)
                    Text(String(format:"body %.1f / %.1f · nominal C %.1f / L %.1f · raw side %.1f mm",size.waist,size.hip,size.bodyCircumference,size.bodyLength,size.rawHeight)).foregroundStyle(Palette.secondary).lineLimit(1).minimumScaleFactor(0.85)
                  }
                  Spacer()
                  if controller.blockID != nil {
                    Button("Export source PDF"){controller.exportSize(size.sizeID)}
                      .disabled(!controller.blocks.contains{b in b.id==controller.blockID && b.bindings.contains{$0.sizeID==size.sizeID}})
                      .accessibilityLabel("Export source PDF for "+size.label)
                    Button("Reveal source") {controller.reveal(size.sizeID);dismiss()}
                      .disabled(!controller.blocks.contains{b in b.id==controller.blockID && b.bindings.contains{$0.sizeID==size.sizeID}})
                      .accessibilityLabel("Reveal source for "+size.label)
                  }
                }.font(.system(size:9,design:.monospaced))
              }
            }
          }.frame(maxHeight:110)
          if !controller.updateNeeded.isEmpty {
            Text("Saved chart has pending source updates. Apply explicitly; existing source is unchanged.").font(.system(size:10)).foregroundStyle(Palette.accent)
          }
        }
      }.frame(maxHeight:.infinity)
      if !controller.conflicts.isEmpty {
        Text("Source needs review").font(.system(size:11,weight:.medium))
        ScrollView {VStack(alignment:.leading,spacing:3){ForEach(Array(controller.conflicts.enumerated()),id:\.offset){_,message in Text(message).font(.system(size:10)).foregroundStyle(Palette.accent)}}}.frame(maxHeight:65)
      }
      if !controller.error.isEmpty {Text(controller.error).font(.system(size:10)).foregroundStyle(.red)}
      if !controller.draft.error.isEmpty {Text(controller.draft.error).font(.system(size:10)).foregroundStyle(.red)}
      HStack {
        if controller.blockID != nil {
          Button("Detach block metadata"){controller.detach()}.accessibilityLabel("Detach garment block metadata")
          Text("Preserves every source piece.").font(.system(size:9)).foregroundStyle(Palette.secondary)
          Spacer()
          if controller.externalChange {Button("Reload saved chart"){controller.select(controller.blockID)}}
          Button("Save chart only"){controller.apply("configure")}.disabled(controller.proof==nil || controller.externalChange)
            .accessibilityLabel("Save garment chart only")
          Button("Create independent revision"){controller.apply("create_revision")}.disabled(controller.proof==nil)
            .accessibilityLabel("Create independent garment revision")
          Button("Apply chart to source"){controller.apply("update")}
            .disabled(controller.proof==nil || controller.externalChange || !controller.conflicts.isEmpty)
            .accessibilityLabel("Apply garment chart to source").buttonStyle(.borderedProminent)
        } else {
          Text("Generate creates editable pieces and size metadata in one Undo. Preview never changes the project.").font(.system(size:10)).foregroundStyle(Palette.secondary)
          Spacer()
          Button("Generate editable sizes"){controller.apply("create")}.disabled(controller.proof==nil)
            .accessibilityLabel("Generate editable garment sizes").buttonStyle(.borderedProminent)
        }
      }
      if !review.error.isEmpty {Text(review.error).font(.system(size:10)).foregroundStyle(.red)}
    }.padding(24).frame(width:1180,height:850).background(Palette.paper)
      .onAppear{controller.refreshPreview()}
      .onChange(of:store.revision){_,_ in controller.refreshContext()}
  }
}

struct GarmentBlockDraftControls:View {
  @ObservedObject var draft:GarmentBlockDraft
  let materials:[FormCore.Material]
  var onChange:()->Void
  @State private var section=0
  private func field(_ field:GarmentBlockDraft.Field)->some View {
    HStack(spacing:5) {
      Text(field.label).foregroundStyle(Palette.secondary)
      Spacer(minLength:3)
      TextField(field.label,text:Binding(get:{draft.values[field.rawValue] ?? ""},set:{draft.values[field.rawValue]=$0}))
        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width:72)
        .accessibilityLabel(field.label+" in millimeters")
      Text("mm").foregroundStyle(Palette.secondary)
    }.font(.system(size:10))
  }
  var body:some View {
    VStack(alignment:.leading,spacing:12) {
      TextField("Block name",text:$draft.name).textFieldStyle(.roundedBorder).accessibilityLabel("Garment block name")
      Picker("Block controls",selection:$section) {
        Text("Measurements").tag(0);Text("Construction").tag(1);Text("Sizes").tag(2)
      }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Garment block controls")
      Group {
        if section == 0 {
        ScrollView {VStack(alignment:.leading,spacing:12) {
          ForEach([GarmentBlockDraft.Field.waist,.hip,.depth,.length,.ease],id:\.rawValue){field($0)}
          Text("Body values describe the declared wearer. Body circumference is max(waist, hip) plus additional fabric; nominal length is a separate garment dimension.").font(.system(size:10)).foregroundStyle(Palette.secondary)
          Divider();Text("Declared grading per step").font(.system(size:11,weight:.medium))
          ForEach([GarmentBlockDraft.Field.waistGrade,.hipGrade,.depthGrade,.lengthGrade],id:\.rawValue){field($0)}
          Text("Sample values are original concept dimensions, not a standardized size chart.").font(.system(size:10)).foregroundStyle(Palette.secondary)
        }.padding(10)}
        } else if section == 1 {
        ScrollView {VStack(alignment:.leading,spacing:12) {
          ForEach([GarmentBlockDraft.Field.side,.casing,.underturn,.hem,.elasticWidth,.elasticAdjustment,.elasticOverlap],id:\.rawValue){field($0)}
          Text("The hem uses two equal turns (30 mm means two 15 mm turns), then stitches its inner folded edge. Full side seams include casing and hem extensions. Raw top/bottom boundaries are not seam-pairing edges. The back casing stitch guide leaves a 25 mm insertion opening.").font(.system(size:10)).foregroundStyle(Palette.secondary)
          Picker("Body fabric",selection:$draft.materialID){Text("Unspecified").tag("");ForEach(materials.filter{$0.fabric != nil}){Text($0.name).tag($0.id)}}
          Picker("Elastic trim",selection:$draft.elasticMaterialID){Text("Unspecified").tag("");ForEach(materials.filter{$0.fabric != nil}){Text($0.name).tag($0.id)}}
          Text("Elastic cut length = declared loop target + lap overlap. Its stretch and worn fit are not predicted.").font(.system(size:10)).foregroundStyle(Palette.secondary)
        }.font(.system(size:10)).padding(10)}
        } else {
        VStack(alignment:.leading,spacing:10) {
          Picker("Base input row",selection:Binding(get:{draft.baseSizeID},set:{draft.rebase($0)})) {
            ForEach(draft.rows){Text($0.label).tag($0.id)}
          }.font(.system(size:10)).accessibilityLabel("Garment chart base row")
          Text("Blank overrides use the declared grade rule. Rebase preserves the current resolved measurements; choose a different base before removing its row.").font(.system(size:9)).foregroundStyle(Palette.secondary)
          ScrollView {VStack(alignment:.leading,spacing:11) {
            ForEach($draft.rows){$row in
              VStack(alignment:.leading,spacing:6) {
                HStack {
                  TextField("Size label",text:$row.label).textFieldStyle(.roundedBorder).accessibilityLabel("Size label")
                  TextField("Step",text:$row.step).textFieldStyle(.roundedBorder).frame(width:42).disabled(row.id==draft.baseSizeID)
                    .accessibilityLabel("Grade step for "+row.label)
                  Button{draft.removeSize(row.id)}label:{Image(systemName:"minus.circle")}.buttonStyle(.borderless)
                    .disabled(row.id==draft.baseSizeID || draft.rows.count<=1).accessibilityLabel("Detach size "+row.label+" when applied")
                }
                HStack {overrideField("Waist",text:$row.waist);overrideField("Hip",text:$row.hip)}.disabled(row.id==draft.baseSizeID)
                HStack {overrideField("Hip depth",text:$row.depth);overrideField("Length",text:$row.length)}
                  .disabled(row.id==draft.baseSizeID)
                if row.id==draft.baseSizeID {Text("Base: edit the Measurements tab.").font(.system(size:9)).foregroundStyle(Palette.secondary)}
              }.padding(8).background(Palette.ink.opacity(0.035),in:RoundedRectangle(cornerRadius:5))
            }
          }}
          Button("Add size"){draft.addSize()}.disabled(draft.rows.count>=12).accessibilityLabel("Add garment size")
          Text("Removing a size detaches its metadata when applied; all existing source artwork remains.").font(.system(size:9)).foregroundStyle(Palette.secondary)
        }.padding(10)
        }
      }
      if !draft.error.isEmpty {Text(draft.error).font(.system(size:10)).foregroundStyle(.red)}
    }.onChange(of:draft.signature){_,_ in onChange()}
  }
  private func overrideField(_ name:String,text:Binding<String>)->some View {
    HStack(spacing:4) {
      Text(name).foregroundStyle(Palette.secondary).frame(minWidth:42,alignment:.leading)
      TextField("Graded",text:text).textFieldStyle(.roundedBorder).frame(minWidth:45)
        .accessibilityLabel(name+" size override in millimeters")
    }.font(.system(size:9))
  }
}

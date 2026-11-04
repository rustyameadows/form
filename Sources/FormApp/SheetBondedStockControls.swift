import AppKit
import FormCore
import SwiftUI

extension SheetStockControlEditing {
  static func addPly(front:Bool,in stock:inout PaperStock)throws {
    var candidate=stock
    if candidate.plies==nil {
      candidate.plies=[.init(name:stock.name,color:stock.profile?.color ?? "#F7F5EF",thicknessMM:stock.resolvedThicknessMM,profile:stock.profile,gsm:stock.gsm)]
    }
    guard (candidate.plies?.count ?? 0)<16 else{throw FormError.invalid("A bonded stock supports at most16 physical plies.")}
    let ply=PaperPly(name:front ? "Face layer":"Backing",color:"#E9E3D4",thicknessMM:0.1,profile:.init(texture:.smooth,color:"#E9E3D4"))
    if front{candidate.plies!.append(ply)}else{candidate.plies!.insert(ply,at:0)}
    candidate.thicknessMM=candidate.resolvedThicknessMM;try candidate.validate();stock=candidate
  }
  static func editPly(_ id:UUID,in stock:inout PaperStock,_ edit:(inout PaperPly)->Void) {
    guard let index=stock.plies?.firstIndex(where:{$0.id==id}) else{return}
    edit(&stock.plies![index]);stock.thicknessMM=stock.resolvedThicknessMM
  }
  static func editPlySurface(_ id:UUID,in stock:inout PaperStock,_ edit:(inout PaperSurfaceProfile)->Void) {
    let inherited=stock.profile
    editPly(id,in:&stock){ply in
      var surface=ply.profile ?? inherited ?? .init()
      if ply.profile==nil {surface.color=ply.color}
      edit(&surface);ply.profile=surface
    }
  }
  static func removePly(_ id:UUID,in stock:inout PaperStock) {
    guard (stock.plies?.count ?? 0)>1,stock.plies?.contains(where:{$0.id==id})==true else{return}
    stock.plies?.removeAll{$0.id==id};stock.thicknessMM=stock.resolvedThicknessMM
  }
  static func movePly(_ id:UUID,towardFront:Bool,in stock:inout PaperStock) {
    guard let index=stock.plies?.firstIndex(where:{$0.id==id}) else{return}
    let next=index+(towardFront ? 1: -1)
    guard let count=stock.plies?.count,(0..<count).contains(next) else{return}
    stock.plies!.swapAt(index,next)
  }
}

/// The same physical layer editor serves publications, cases and independent
/// cut pieces. A backing is material with caliper, never a second print side.
struct SheetBondedStockControls:View {
  @Binding var stock:PaperStock
  let targetID:String
  let caliperIsDerived:Bool
  var onEditingChanged:(Bool)->Void = {_ in}
  @State private var issue:String?
  var body:some View {
    DisclosureGroup("Bonded layers & backing") {
      VStack(alignment:.leading,spacing:9) {
        Text("Physical plies are ordered back to front; their colors appear on the cut edge. Printing remains separate.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
        if caliperIsDerived {Text("The linked part caliper scales these declared layer proportions together.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
        ForEach(stock.plies ?? []){ply in
          DisclosureGroup(ply.name) {plyControls(ply).padding(.top,8)}
        }
        HStack {
          Button("Add backing"){add(front:false)}.buttonStyle(InspectorActionStyle())
          Button("Add face layer"){add(front:true)}.buttonStyle(InspectorActionStyle())
        }.disabled((stock.plies?.count ?? 0)>=16)
        if let issue{Text(issue).font(InspectorStyle.captionFont).foregroundStyle(.orange)}
      }.padding(.top,8)
    }
  }
  private func value(_ ply:PaperPly)->PaperPly{stock.plies?.first{$0.id==ply.id} ?? ply}
  private func edit(_ id:UUID,_ change:(inout PaperPly)->Void) {
    var candidate=stock;SheetStockControlEditing.editPly(id,in:&candidate,change);stock=candidate;issue=nil
  }
  private func add(front:Bool) {
    do{var candidate=stock;try SheetStockControlEditing.addPly(front:front,in:&candidate);stock=candidate;issue=nil}catch{issue=error.localizedDescription}
  }
  private func profile(_ id:UUID,_ change:(inout PaperSurfaceProfile)->Void) {
    var candidate=stock;SheetStockControlEditing.editPlySurface(id,in:&candidate,change);stock=candidate;issue=nil
  }
  private func plyControls(_ ply:PaperPly)->some View {
    let current=value(ply),surface=current.profile ?? stock.profile ?? .init(color:current.color)
    return VStack(alignment:.leading,spacing:8) {
      PublicationCommittedField(title:"Layer name",value:current.name,allowsEmpty:false){name in edit(ply.id){$0.name=name}}.textFieldStyle(InspectorTextFieldStyle())
      ArtworkUnitField("Layer caliper",value:current.thicknessMM,unit:.mm){amount in edit(ply.id){$0.thicknessMM=amount}}
      InspectorColorPicker("Layer color",selection:Binding(get:{Color(nsColor:NSColor(hex:SheetParentStockEditing.color(of:value(ply))))},set:{color in
        var candidate=stock;SheetParentStockEditing.setColor(NSColor(color).hexString,plyID:ply.id,in:&candidate);stock=candidate
      }),supportsOpacity:false,targetID:targetID+"-ply-"+ply.id.uuidString,onEditingChanged:onEditingChanged)
      Picker("Layer texture",selection:Binding(get:{surface.texture},set:{texture in profile(ply.id){$0.texture=texture}})) {
        ForEach(PaperSurfaceProfile.Texture.allCases,id:\.self){Text($0.rawValue.capitalized).tag($0)}
      }.inspectorPicker()
      DisclosureGroup("Layer surface detail") {
        VStack(spacing:8) {
          ScalarArtworkField("Roughness",value:surface.roughness,unit:""){amount in profile(ply.id){$0.roughness=amount}}
          ScalarArtworkField("Opacity",value:surface.opacity,unit:""){amount in profile(ply.id){$0.opacity=amount}}
          ArtworkUnitField("Texture scale",value:surface.textureScaleMM,unit:.mm){amount in profile(ply.id){$0.textureScaleMM=amount}}
          ArtworkUnitField("Texture depth",value:surface.textureDepthMM,unit:.mm){amount in profile(ply.id){$0.textureDepthMM=amount}}
        }.padding(.top,8)
      }
      HStack {
        Button("Toward back"){var candidate=stock;SheetStockControlEditing.movePly(ply.id,towardFront:false,in:&candidate);stock=candidate}.buttonStyle(InspectorActionStyle()).disabled(stock.plies?.first?.id==ply.id)
        Button("Toward front"){var candidate=stock;SheetStockControlEditing.movePly(ply.id,towardFront:true,in:&candidate);stock=candidate}.buttonStyle(InspectorActionStyle()).disabled(stock.plies?.last?.id==ply.id)
      }
      Button("Remove layer"){var candidate=stock;SheetStockControlEditing.removePly(ply.id,in:&candidate);stock=candidate}.buttonStyle(InspectorActionStyle()).disabled((stock.plies?.count ?? 0)<=1)
    }
  }
}

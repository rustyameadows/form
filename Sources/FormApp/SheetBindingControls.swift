import AppKit
import FormCore
import SwiftUI

/// The same source/instance pose controls; bindings decide which saved authority
/// is edited. Reader labels come from physical faces, including real blank slots.
struct SheetPoseControls:View {
  @Binding var openingDegrees:Double
  @Binding var activeSpread:Int
  @Binding var bendMM:Double
  let document:PublicationDocument?
  let leaves:[ResolvedSheetAssemblyLeaf]
  var onEditingChanged:(Bool)->Void = {_ in}
  static func spreadLabel(_ index:Int,document:PublicationDocument?,leaves:[ResolvedSheetAssemblyLeaf])->String {
    func label(_ id:UUID?)->String? {
      guard let id,let document,let page=document.pages.first(where:{$0.id==id}) else{return nil}
      return document.pageLabel(for:page.objectID)
    }
    let left=index>0 && index<=leaves.count ? label(leaves[index-1].backPageID):nil
    let right=leaves.indices.contains(index) ? label(leaves[index].frontPageID):nil
    if let left,let right{return "Pages \(left)–\(right)"}
    if let label=left ?? right{return "Page \(label)"}
    return "Blank faces · \(index+1)"
  }
  var body:some View {
    VStack(alignment:.leading,spacing:8) {
      ScalarArtworkField("Opening",value:openingDegrees,unit:"°",accessibilityName:"Sheet opening"){openingDegrees=$0}
      InspectorSlider(value:$openingDegrees,in:0...180,label:"Sheet opening",onEditingChanged:onEditingChanged)
      Picker("Reader spread",selection:$activeSpread) {
        ForEach(Array(0...leaves.count),id:\.self){index in Text(Self.spreadLabel(index,document:document,leaves:leaves)).tag(index)}
      }.inspectorPicker().accessibilityIdentifier("sheet-reader-spread")
      ArtworkUnitField("Page bend",value:bendMM,unit:.mm,accessibilityName:"Sheet page bend"){bendMM=$0}
    }
  }
}

struct SheetFastenerControls:View {
  @Binding var binding:SheetBindingDefinition
  var body:some View {
    VStack(alignment:.leading,spacing:8) {
      Picker("Binding",selection:$binding.style) {
        Text("None").tag(SheetBindingStyle.none)
        Text("Saddle stitch").tag(SheetBindingStyle.saddleStitch)
        Text("Side staple").tag(SheetBindingStyle.sideStaple)
      }.inspectorPicker().accessibilityIdentifier("sheet-binding-style")
      if binding.style != .none {
        Picker("Fasteners",selection:Binding(get:{binding.count},set:{count in var value=binding;value.count=count;value.positionsMM=nil;binding=value})) {
          ForEach(1...8,id:\.self){Text(String($0)).tag($0)}
        }.inspectorPicker()
        DisclosureGroup("Fastener dimensions") {
          VStack(spacing:8) {
            ArtworkUnitField("Head / tail inset",value:binding.endMarginMM,unit:.mm){amount in var value=binding;value.endMarginMM=amount;value.positionsMM=nil;binding=value}
            ArtworkUnitField("Crown length",value:binding.crownLengthMM,unit:.mm){binding.crownLengthMM=$0}
            ArtworkUnitField("Wire diameter",value:binding.wireDiameterMM,unit:.mm){binding.wireDiameterMM=$0}
            ArtworkUnitField("Clinch length",value:binding.clinchLengthMM,unit:.mm){binding.clinchLengthMM=$0}
            if binding.style == .sideStaple {
              ArtworkUnitField("Edge inset",value:binding.edgeInsetMM,unit:.mm){binding.edgeInsetMM=$0}
              ArtworkUnitField("Margin flex",value:binding.flexWidthMM,unit:.mm){binding.flexWidthMM=$0}
            }
            if let positions=binding.positionsMM {
              ForEach(positions.indices,id:\.self){index in
                ArtworkUnitField("Center \(index+1)",value:positions[index],unit:.mm){binding.positionsMM?[index]=$0}
              }
            }
          }.padding(.top,8)
        }.font(InspectorStyle.labelFont)
      }
    }
  }
}

/// Edits the same effective face properties consumed by Canvas, Table and PDF.
/// Keep a ply's cut-edge color and an explicit face-profile color in agreement.
enum SheetParentStockEditing {
  static func color(of ply:PaperPly)->String {ply.profile?.color ?? ply.color}
  static func setColor(_ color:String,plyID:UUID,in stock:inout PaperStock) {
    guard let index=stock.plies?.firstIndex(where:{$0.id==plyID}) else{return}
    stock.plies![index].color=color
    if stock.plies![index].profile != nil {stock.plies![index].profile!.color=color}
  }
  static func texture(in stock:PaperStock)->PaperSurfaceProfile.Texture? {
    let inherited=stock.profile?.texture ?? PaperSurfaceProfile().texture
    guard let plies=stock.plies,!plies.isEmpty else{return inherited}
    let faces=[plies.first,plies.last].compactMap{$0}.map{$0.profile?.texture ?? inherited}
    guard let first=faces.first else{return inherited}
    return faces.allSatisfy{$0==first} ? first:nil
  }
  static func setTexture(_ texture:PaperSurfaceProfile.Texture,in stock:inout PaperStock) {
    var profile=stock.profile ?? .init();profile.texture=texture;stock.profile=profile
    for index in stock.plies?.indices ?? 0..<0 where stock.plies![index].profile != nil {
      stock.plies![index].profile!.texture=texture
    }
  }
}

/// A physical parent owns stock and print intent once. Both derived viewing
/// leaves and all four canonical page projections consume these same bindings.
struct SheetParentStockControls:View {
  @EnvironmentObject private var store:StudioStore
  @Binding var parent:SheetAssemblyParentSheet
  let ordinal:Int
  let targetID:String
  var onEditingChanged:(Bool)->Void = {_ in}
  private func stock(_ update:(inout PaperStock)->Void) {var value=parent;update(&value.stock);parent=value}
  var body:some View {
    DisclosureGroup("Sheet \(ordinal+1) · \(parent.stock.name)") {
      VStack(alignment:.leading,spacing:8) {
        Picker("Printing",selection:$parent.printIntent) {
          Text("Full color").tag(SheetParentPrintIntent.color)
          Text("K-only ink").tag(SheetParentPrintIntent.blackOnly)
        }.inspectorPicker()
        Menu("Choose stock") {
          ForEach(Array(PaperAppearanceCommands.presets.enumerated()),id:\.offset){_,preset in
            Button(preset.name){stock{$0=preset}}
          }
          if store.library.materials.contains(where:{$0.paperStock != nil}) {
            Divider()
            ForEach(store.library.materials.filter{$0.paperStock != nil}){material in
              Button(material.name){if let preset=material.paperStock {stock{$0=preset}}}
            }
          }
        }.menuStyle(.borderlessButton).font(InspectorStyle.labelFont)
        ArtworkUnitField("Caliper",value:parent.stock.resolvedThicknessMM,unit:.mm){amount in stock {value in
          let old=value.resolvedThicknessMM;value.thicknessMM=amount
          if value.plies != nil,old>0 {for index in value.plies!.indices {value.plies![index].thicknessMM *= amount/old}}
        }}
        ScalarArtworkField("Weight",value:parent.stock.gsm ?? 100,unit:"gsm"){amount in stock{$0.gsm=amount}}
        let profile=parent.stock.profile ?? PaperSurfaceProfile()
        Picker("Texture",selection:Binding<PaperSurfaceProfile.Texture?>(get:{SheetParentStockEditing.texture(in:parent.stock)},set:{texture in
          if let texture {stock {SheetParentStockEditing.setTexture(texture,in:&$0)}}
        })) {
          Text("Mixed").tag(PaperSurfaceProfile.Texture?.none)
          ForEach(PaperSurfaceProfile.Texture.allCases,id:\.self){Text($0.rawValue.capitalized).tag(Optional($0))}
        }.inspectorPicker()
        if let plies=parent.stock.plies {
          ForEach(plies){ply in
            InspectorColorPicker(ply.name,selection:Binding(get:{Color(nsColor:NSColor(hex:SheetParentStockEditing.color(of:ply)))},set:{color in stock {value in
              SheetParentStockEditing.setColor(NSColor(color).hexString,plyID:ply.id,in:&value)
            }}),supportsOpacity:false,targetID:targetID+ply.id.uuidString,onEditingChanged:onEditingChanged)
          }
        }else{
          InspectorColorPicker("Stock color",selection:Binding(get:{Color(nsColor:NSColor(hex:profile.color ?? "#F7F5EF"))},set:{color in stock {value in
            var p=value.profile ?? .init();p.color=NSColor(color).hexString;value.profile=p
          }}),supportsOpacity:false,targetID:targetID,onEditingChanged:onEditingChanged)
        }
        Text("\(String(format:"%.1f",parent.sizeMM.x)) × \(String(format:"%.1f",parent.sizeMM.y)) mm · four physical print slots")
          .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
      }.padding(.top,8)
    }.font(InspectorStyle.labelFont)
  }
}

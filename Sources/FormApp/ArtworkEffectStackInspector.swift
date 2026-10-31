import AppKit
import FormCore
import SwiftUI

extension ArtworkSession {
  /// Effect rows address the inspected layer explicitly. Changing one row must
  /// not replace a different selected layer's independently authored stack.
  func editEffectStack(elementID:UUID,structural:Bool=false,_ edit:(inout ArtworkEffectStack)->Void) {
    guard let store,let objectID,selection.contains(elementID) else{return}
    if structural {InspectorColorPanelController.shared.close()}
    NotificationCenter.default.post(name:.formCommitArtworkFields,object:nil)
    canvas?.finishText()
    guard selection.contains(elementID),let current=sourceArtwork.elements.first(where:{$0.id==elementID}),
      var stack=current.effectStack else{return}
    if structural {store.engine.endInteraction()}
    defer{if structural {store.engine.endInteraction()}}
    edit(&stack)
    do {
      try stack.validate()
      let values=try JSONSerialization.jsonObject(with:JSONEncoder.form.encode(stack))
      try store.engine.call("form_appearance",arguments:["command":"update","object_id":objectID.uuidString,
        "element_ids":[elementID.uuidString],"values":["effect_stack":values]],source:"Studio")
      store.changed()
    } catch {store.error=error.localizedDescription}
  }
}

struct ArtworkEffectStackInspector:View {
  @ObservedObject var session:ArtworkSession
  let element:ArtworkElement
  let stack:ArtworkEffectStack
  var body:some View {
    VStack(alignment:.leading,spacing:12) {
      ForEach(Array(stack.effects.indices),id:\.self) { index in
        ArtworkEffectRow(session:session,elementID:element.id,index:index,effect:stack.effects[index],count:stack.effects.count)
        Divider()
      }
      Menu("Add effect") {
        Button("Drop shadow"){add("drop-shadow")}
        Button("Inner shadow"){add("inner-shadow")}
        Button("Layer blur"){add("blur")}
      }.disabled(stack.effects.count>=16)
      if stack.effects.isEmpty {Text("No effects").foregroundStyle(Palette.secondary)}
    }
  }
  private func add(_ kind:String) {
    session.editEffectStack(elementID:element.id,structural:true) { value in
      guard value.effects.count<16 else{return}
      value.effects.append(.init(kind:kind,offset:kind == "blur" ? .init():.init(2,2),blur:1,
        opacity:kind == "blur" ? 1:0.35))
    }
  }
}

private struct ArtworkEffectRow:View {
  @EnvironmentObject var store:StudioStore
  @ObservedObject var session:ArtworkSession
  let elementID:UUID
  let index:Int
  let effect:ArtworkEffect
  let count:Int
  private var title:String {effect.kind == "blur" ? "Layer blur":effect.kind == "inner-shadow" ? "Inner shadow":"Drop shadow"}
  private var swatch:ArtworkSwatch? {store.project?.swatches?.first{$0.id==effect.swatchID}}
  private var colorEditing:(Bool)->Void {
    store.inspectorInteraction("appearance-\(session.objectID?.uuidString ?? "")-\(elementID.uuidString)")
  }
  private func update(_ edit:(inout ArtworkEffect)->Void) {
    session.editEffectStack(elementID:elementID) { stack in
      guard stack.effects.indices.contains(index) else{return};edit(&stack.effects[index])
    }
  }
  var body:some View {
    VStack(alignment:.leading,spacing:9) {
      HStack {
        Toggle(title,isOn:.init(get:{effect.enabled},set:{value in update{$0.enabled=value}})).inspectorToggle()
          .accessibilityIdentifier("effect-\(index)-enabled")
        Spacer(minLength:0)
        Button {move(-1)} label:{Image(systemName:"arrow.up")}.disabled(index==0).help("Move effect earlier")
        Button {move(1)} label:{Image(systemName:"arrow.down")}.disabled(index==count-1).help("Move effect later")
        Button {session.editEffectStack(elementID:elementID,structural:true){if $0.effects.indices.contains(index){$0.effects.remove(at:index)}}}
          label:{Image(systemName:"minus.circle")}.help("Remove effect")
      }.buttonStyle(.borderless)
      VStack(alignment:.leading,spacing:9) {
        ArtworkUnitField("Blur",value:effect.blur,unit:session.unit){value in update{$0.blur=value}}
          .accessibilityIdentifier("effect-\(index)-blur")
        if effect.kind != "blur" { shadowControls }
      }.disabled(!effect.enabled)
    }
  }
  private var shadowControls:some View {
    VStack(alignment:.leading,spacing:9) {
      HStack {
        ArtworkUnitField("Offset X",value:effect.offset.x,unit:session.unit){value in update{$0.offset.x=value}}
        ArtworkUnitField("Offset Y",value:effect.offset.y,unit:session.unit){value in update{$0.offset.y=value}}
      }
      ArtworkUnitField("Spread",value:effect.spread,unit:session.unit){value in update{$0.spread=value}}
      InspectorColorPicker("Shadow color",selection:.init(get:{Color(nsColor:NSColor(hex:swatch?.color ?? effect.color))},
        set:{value in update{$0.color=NSColor(value).hexString;$0.swatchID=nil}}),supportsOpacity:false,
        targetID:session.inspectorColorTarget("effect-\(index)"),onEditingChanged:colorEditing)
        .disabled(swatch?.printInk != nil)
      Menu(swatch?.name ?? "Local color") {
        Button("Local color · detach"){let color=swatch?.color ?? effect.color;update{$0.swatchID=nil;$0.color=color}}
          .disabled(effect.swatchID==nil || swatch?.printInk != nil)
        ForEach(store.project?.swatches ?? []) {value in
          Button(value.name){update{$0.swatchID=value.id;$0.color=value.color}}
        }
        Divider()
        Button("Manage palette…"){session.showingPalette=true}
      }.menuStyle(.borderlessButton)
      ScalarArtworkField("Opacity",value:effect.opacity*100,unit:"%"){value in update{$0.opacity=value/100}}
      Picker("Blend",selection:Binding(get:{effect.blendMode ?? "normal"},set:{value in update{$0.blendMode=value == "normal" ? nil:value}})) {
        ForEach(AppearanceCommands.blendModes,id:\.self){Text($0.replacingOccurrences(of:"-",with:" ").capitalized).tag($0)}
      }
      if effect.kind == "drop-shadow" {
        Toggle("Hide behind layer",isOn:.init(get:{effect.knockout},set:{value in update{$0.knockout=value}})).inspectorToggle()
      }
    }
  }
  private func move(_ delta:Int) {
    session.editEffectStack(elementID:elementID,structural:true) { stack in
      guard stack.effects.indices.contains(index),stack.effects.indices.contains(index+delta) else{return}
      stack.effects.swapAt(index,index+delta)
    }
  }
}

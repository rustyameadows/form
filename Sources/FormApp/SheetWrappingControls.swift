import Foundation
import FormCADModel
import FormCore
import SwiftUI

/// One material editor for wrapping on both ordered-sheet planes and ordinary
/// authored paper panels. Printed artwork remains a separate canonical source.
struct SheetWrappingControls:View {
  @Binding var wrap:SheetPanelWrap?
  var parameters:[String]=[]
  let targetID:String
  var onEditingChanged:(Bool)->Void = {_ in}
  private func update(_ edit:(inout SheetPanelWrap)->Void) {
    guard var value=wrap else{return};edit(&value);wrap=value
  }
  var body:some View {
    DisclosureGroup("Wrapping & turn-ins") {
      VStack(spacing:8) {
        Toggle("Wrapped panel",isOn:Binding(get:{wrap != nil},set:{wrap=$0 ? .init(stock:.init(thicknessMM:0.12),turnInMM:0):nil})).inspectorToggle()
        if let current=wrap {
          SheetStockControls(stock:Binding(get:{wrap?.stock ?? current.stock},set:{value in update{$0.stock=value}}),targetID:targetID,caliperIsDerived:current.stockThickness != nil,onEditingChanged:onEditingChanged)
          Toggle("Parameterized wrap caliper",isOn:Binding(get:{wrap?.stockThickness != nil},set:{enabled in update{$0.stockThickness=enabled ? CADScalar(current.stock.resolvedThicknessMM):nil}})).inspectorToggle()
          if let thickness=wrap?.stockThickness {
            SheetExpressionField(title:"Wrap caliper",value:Binding(get:{wrap?.stockThickness ?? thickness},set:{value in update{$0.stockThickness=value}}),parameters:parameters)
          }
          SheetExpressionField(title:"Turn-in",value:Binding(get:{wrap?.turnInMM ?? current.turnInMM},set:{value in update{$0.turnInMM=value}}),parameters:parameters)
          SheetExpressionField(title:"Corner radius",value:Binding(get:{wrap?.cornerRadiusMM ?? current.cornerRadiusMM},set:{value in update{$0.cornerRadiusMM=value}}),parameters:parameters)
        }
      }.padding(.top,8)
    }.font(InspectorStyle.labelFont).accessibilityElement(children:.contain).accessibilityLabel("Panel wrapping")
  }
}

/// The native binding targets stable source identities and re-reads the complete
/// current definition before replacing only this panel's wrapping declaration.
@MainActor enum PaperPanelWrappingEditing {
  @discardableResult static func replace(session:ArtworkSession,projectID:UUID,objectID:UUID,panelID:String,wrap:SheetPanelWrap?)->Bool {
    guard let store=session.store else{return false}
    do {
      guard let project=store.project,project.id==projectID,
        let object=project.objects.first(where:{$0.id==objectID}),!object.locked,
        var definition=try PaperConstruction.definition(for:object).authored,
        let index=definition.panels.firstIndex(where:{$0.id==panelID}) else {
        throw FormError.missing("The paper panel changed. Choose its current wrapping controls.")
      }
      var features=definition.panels[index].features ?? .init()
      guard features.wrap != wrap else{return true}
      features.wrap=wrap;definition.panels[index].features=features
      _=try definition.net()
      _=try store.engine.call("form_construction",arguments:["command":"configure","object_id":objectID.uuidString,"definition":try jsonObject(definition)],source:"Studio")
      store.changed();return true
    }catch{store.error=error.localizedDescription;return false}
  }
}

struct PaperPanelWrappingControls:View {
  @EnvironmentObject private var store:StudioStore
  let projectID:UUID
  let objectID:UUID
  let panel:PlanarPanelDefinition
  let parameters:[String]
  private var currentWrap:SheetPanelWrap? {
    guard let project=store.project,project.id==projectID,
      let object=project.objects.first(where:{$0.id==objectID}),
      let definition=try? PaperConstruction.definition(for:object) else{return nil}
    return definition.authored?.panels.first{$0.id==panel.id}?.features?.wrap
  }
  var body:some View {
    VStack(alignment:.leading,spacing:7) {
      Text(panel.name).font(InspectorStyle.headingFont)
      SheetWrappingControls(wrap:Binding(get:{currentWrap},set:{value in
        _=PaperPanelWrappingEditing.replace(session:store.artworkSession,projectID:projectID,objectID:objectID,panelID:panel.id,wrap:value)
      }),parameters:parameters,targetID:"paper-wrap-\(projectID)-\(objectID)-\(panel.id)",onEditingChanged:store.inspectorInteraction("paper-wrap-\(objectID)-\(panel.id)"))
    }
  }
}

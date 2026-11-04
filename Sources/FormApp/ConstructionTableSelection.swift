import Foundation
import FormCADModel
import FormCore
import FormGeometry

/// Ephemeral Table navigation, never an edit to the construction or Canvas.
struct ConstructionTableTarget:Equatable {
  enum Kind:String {case joint,fastener}
  var ownerID:UUID,kind:Kind,jointID:String
  var attachmentID:String?,componentID:String?,fastenerDefinitionID:String?,fastenerInstanceID:String?
  var panelIDs:[String]
  func metadata()->[String:Any] {
    ["object_id":ownerID.uuidString,"kind":kind.rawValue,"joint_id":jointID,
      "attachment_id":attachmentID as Any? ?? NSNull(),"component_id":componentID as Any? ?? NSNull(),
      "fastener_definition_id":fastenerDefinitionID as Any? ?? NSNull(),"fastener_instance_id":fastenerInstanceID as Any? ?? NSNull(),"panel_ids":panelIDs]
  }
}
@MainActor enum ConstructionTableSelection {
  static func resolve(object:ProductObject,source:PaperGeometry.RenderSource,jointID:String,attachmentID:String?=nil,componentID:String?=nil,
    fastenerDefinitionID:String?=nil,fastenerInstanceID:String?=nil)throws->ConstructionTableTarget? {
    guard let definition=source.definition.authored,definition.version>=4,
      let join=source.net.joins.first(where:{$0.id==jointID}),let context=source.context else{return nil}
    func active(_ record:PlanarJointAttachmentDefinition)throws->Bool {
      try record.enabled.map{try CADExpression.evaluate($0.expression,variables:context.values)>0.5} ?? true
    }
    let attachments=try (definition.jointAttachments ?? []).filter{record in
      guard record.joinID==jointID else{return false};return try active(record)
    }
    if let attachmentID,!attachments.contains(where:{$0.id==attachmentID}) {return nil}
    let candidates=attachments.filter{attachmentID==nil || $0.id==attachmentID}
    var attachment=candidates.first,fastenerID=fastenerDefinitionID
    if let instance=fastenerInstanceID,fastenerID==nil,let colon=instance.lastIndex(of:":") {fastenerID=String(instance[..<colon])}
    if let fastenerID {
      guard let declaration=candidates.first(where:{$0.staples?.contains(where:{$0.id==fastenerID})==true}),
        let staple=declaration.staples?.first(where:{$0.id==fastenerID}) else{return nil}
      let count=Int(try CADExpression.evaluate(staple.count.expression,variables:context.values).rounded())
      if let instance=fastenerInstanceID {
        guard instance.hasPrefix(fastenerID+":"),let index=Int(instance.dropFirst(fastenerID.count+1)),(0..<count).contains(index) else{return nil}
      }
      attachment=declaration
    } else if fastenerInstanceID != nil {return nil}
    if let componentID {
      guard let tape=candidates.first(where:{$0.tape?.componentID==componentID}) else{return nil};attachment=tape
    }
    let tapes=candidates.compactMap{$0.tape?.componentID}.filter(context.enabledIDs.contains)
    var panels=[join.firstPanelID,join.secondPanelID]
    for id in tapes {panels+=context.ownership[id] ?? []}
    let selectedAttachment=(attachmentID != nil || componentID != nil || fastenerID != nil) ? attachment?.id:nil
    return .init(ownerID:object.id,kind:fastenerID==nil ? .joint:.fastener,jointID:jointID,attachmentID:selectedAttachment,
      componentID:componentID,fastenerDefinitionID:fastenerID,fastenerInstanceID:fastenerInstanceID,panelIDs:Array(Set(panels)).sorted())
  }
  static func hit(node:MeshNode,object:ProductObject,source:PaperGeometry.RenderSource)throws->ConstructionTableTarget? {
    guard let definition=source.definition.authored,definition.version>=4 else{return nil}
    var current:MeshNode?=node
    while let value=current {
      if let name=value.name,name.hasPrefix(PlanarFastenerGeometry.prefix) {
        let instance=String(name.dropFirst(PlanarFastenerGeometry.prefix.count))
        for attachment in definition.jointAttachments ?? [] {
          for staple in attachment.staples ?? [] where instance.hasPrefix(staple.id+":") {
            if let result=try resolve(object:object,source:source,jointID:attachment.joinID,attachmentID:attachment.id,
              fastenerDefinitionID:staple.id,fastenerInstanceID:instance) {return result}
          }
        }
      }
      current=value.parent
    }
    if let panelID=PaperGeometry.panelID(from:node),let component=source.context?.pieceByPanel[panelID] {
      for attachment in definition.jointAttachments ?? [] where attachment.tape?.componentID==component.id {
        if let result=try resolve(object:object,source:source,jointID:attachment.joinID,attachmentID:attachment.id,componentID:component.id) {return result}
      }
    }
    return nil
  }
}
extension StudioStore {
  @discardableResult func selectConstructionTarget(objectID:UUID,jointID:String,attachmentID:String?=nil,componentID:String?=nil,
    fastenerDefinitionID:String?=nil,fastenerInstanceID:String?=nil)->Bool {
    guard let object=project?.objects.first(where:{$0.id==objectID}),let source=try? PaperGeometry.renderSource(for:object),
      let target=try? ConstructionTableSelection.resolve(object:object,source:source,jointID:jointID,attachmentID:attachmentID,componentID:componentID,
        fastenerDefinitionID:fastenerDefinitionID,fastenerInstanceID:fastenerInstanceID) else{return false}
    if primary?.id != objectID {select(objectID)}
    paperSelectionObjectID=objectID;paperSelectedPanelID=nil;paperSelectedFoldID=nil
    constructionTableTarget=target;changed(save:false);return true
  }
}

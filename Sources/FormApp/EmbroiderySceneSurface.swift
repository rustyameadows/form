import AppKit
import FormCore
import FormGraphics
import SceneKit

@MainActor enum EmbroiderySceneSurface {
  static let containerName="Textile decoration"
  static let faceName="Textile face surface"
  static func update(_ root:SCNNode,object:ProductObject,project:Project,assets:URL,textureLimit:Int) {
    guard let container=root.name==containerName ? root:root.childNode(withName:containerName,recursively:true) else {return}
    let existing=container.childNode(withName:faceName,recursively:false)
    let w=object["width"],h=object["depth"],thickness=object["height"]
    if object.textile?.embroidery != nil {
      let node=existing ?? SCNNode(geometry:SCNPlane(width:w/100,height:h/100))
      node.name=faceName;node.categoryBitMask=2
      node.position = .init(0,(thickness+0.15)/100,0);node.eulerAngles.x = -.pi/2
      if existing==nil {container.addChildNode(node)}
      // SceneKit clones share geometry/materials. A local copy prevents one
      // decoration's settings from changing another cached instance's surface.
      node.geometry=node.geometry?.copy() as? SCNGeometry
      do {
        let resources=try EmbroiderySurface.resources(object:object,project:project,fontRevision:GeometryFactory.fontRevision,textureLimit:textureLimit)
        let material=SCNMaterial();material.name="Actual generated embroidery"
        material.lightingModel = .physicallyBased;material.diffuse.contents=resources.diffuse
        material.normal.contents=resources.normal;material.normal.intensity=0.65
        material.roughness.contents=0.72;material.metalness.contents=0
        material.isDoubleSided=true;material.transparencyMode = .aOne
        material.diffuse.wrapS = .clamp;material.diffuse.wrapT = .clamp
        node.geometry?.materials=[material];node.isHidden=false
      } catch {node.isHidden=true}
    } else {
      existing?.removeFromParentNode()
      if let art=project.surfaceArtwork(object) {
        let node=GeometryFactory.artworkPlane(art,width:w,depth:h,y:thickness+0.15,assets:assets,textureLimit:textureLimit)
        node.name=faceName;container.addChildNode(node)
      }
    }
  }
  static func status(object:ProductObject,project:Project,textureLimit:Int)->(digest:String?,issue:String?) {
    guard object.textile?.embroidery != nil else {return (nil,nil)}
    do {return (try EmbroiderySurface.resources(object:object,project:project,fontRevision:GeometryFactory.fontRevision,textureLimit:textureLimit).program.sourceDigest,nil)}
    catch {return (nil,error.localizedDescription)}
  }
}

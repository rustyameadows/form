import CryptoKit
import Foundation

public enum GarmentBlockSources {
  private struct OwnedSource: Codable {
    var id:UUID
    var name:String?
    var kind:String
    var width:Double
    var height:Double
    var path:VectorPath?
    var piece:SewingPatternPiece?
  }
  public static func fingerprint(_ element:ArtworkElement)throws->String {
    let source=OwnedSource(id:element.id,name:element.name,kind:element.kind,width:element.width,
      height:element.height,path:element.path,piece:element.sewingPiece)
    return digest(try JSONEncoder.form.encode(source))
  }
  public static func fingerprint(_ seam:SewingSeam)throws->String {digest(try JSONEncoder.form.encode(seam))}
  private static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  public static func isRigid(_ transform:Affine2)->Bool {
    let values=[transform.a,transform.b,transform.c,transform.d,transform.tx,transform.ty]
    return values.allSatisfy(\.isFinite) && abs(hypot(transform.a,transform.b)-1)<1e-8
      && abs(hypot(transform.c,transform.d)-1)<1e-8 && abs(transform.a*transform.c+transform.b*transform.d)<1e-8
  }
  public static func conflicts(_ block:GarmentBlock,in project:Project)throws->[String] {
    var result:[String]=[]
    for ref in block.bindings {
      let label=(block.sizes.first{$0.id==ref.sizeID}?.label ?? "Removed size")+" / "+ref.role.rawValue
      guard let owner=project.objects.first(where:{$0.id==ref.objectID}),let art=owner.artwork,
        let element=art.elements.first(where:{$0.id==ref.elementID}) else {
        result.append(label+": source is missing; Update will not recreate it.");continue
      }
      if owner.locked || art.isLocked(element) {result.append(label+": source is locked.")}
      if !isRigid(art.worldTransform(element)) {result.append(label+": nonrigid source transform needs review.")}
      if try fingerprint(element) != ref.fingerprint {result.append(label+": source geometry or owned construction metadata was edited; keep it or create a revision.")}
    }
    for ref in block.seams {
      guard let seam=project.objects.first(where:{$0.id==ref.objectID})?.artwork?.sewingSeams?.first(where:{$0.id==ref.seamID}) else {
        result.append("A recorded "+ref.name+" side seam is missing; Update will not recreate it.");continue
      }
      if try fingerprint(seam) != ref.fingerprint {result.append("A recorded "+ref.name+" side seam was edited; keep it or create a revision.")}
    }
    return result
  }
  public static func updateNeededSizes(_ block:GarmentBlock,in project:Project)throws->Set<UUID> {
    var result=Set<UUID>()
    for row in block.sizes {
      let size=try block.resolved(row),refs=block.bindings.filter{$0.sizeID==row.id}
      if refs.isEmpty {result.insert(row.id);continue}
      for ref in refs {
        guard let source=project.objects.first(where:{$0.id==ref.objectID})?.artwork?.elements.first(where:{$0.id==ref.elementID}) else {continue}
        let proposed=piece(block:block,size:size,role:ref.role,preserving:source)
        if try fingerprint(proposed) != fingerprint(source) {result.insert(row.id)}
      }
    }
    return result
  }
  /// Source geometry is the complete raw-height sewing reference, not the nominal finished hem.
  public static func piece(block:GarmentBlock,size:GarmentResolvedSize,role:GarmentPieceRole,
    preserving old:ArtworkElement?=nil)->ArtworkElement {
    let style=block.style
    let width=role == .elastic ? size.elasticCutLength:size.panelWidth
    let height=role == .elastic ? style.elasticWidth:size.rawHeight
    var e=old ?? ArtworkElement(kind:"path",x:0,y:0,width:width,height:height,color:"#737D77")
    e.kind="path";e.width=width;e.height=height;e.name=block.name+" / "+size.label+" / "+role.rawValue
    let points=[Point2(0,0),.init(width,0),.init(width,height),.init(0,height)]
    let previous=old?.path?.contours.first
    let nodes=points.enumerated().map { i,point -> BezierNode in
      var node=BezierNode(point)
      if let prior=previous?.nodes,prior.count==4 {node.id=prior[i].id}
      return node
    }
    var contour=VectorContour(nodes,closed:true)
    contour.id=previous?.id ?? UUID()
    e.path = .init(width:width,height:height,contours:[contour])
    func edge(_ index:Int)->SewingConstructionEdge {
      .init(edge:index,edgeID:nodes[index].id,endID:nodes[(index+1)%4].id)
    }
    var piece=SewingPatternPiece(name:e.name!)
    piece.cutQuantity=1;piece.materialID=role == .elastic ? style.elasticMaterialID:style.materialID
    piece.seamAllowance=role == .elastic ? 0:style.sideAllowance
    piece.edgeAllowances=role == .elastic ? [:]:[0:0,2:0]
    piece.grainAngle=role == .elastic ? 0:90
    piece.unstitchedEdges=(role == .elastic ? [0,1,2,3]:[0,2]).map(edge)
    if role == .elastic {
      piece.notes=String(format:"Declared elastic cut guide %.1f × %.1f mm; target lap %.1f mm gives a requested relaxed loop %.1f mm. Check the actual elastic and waist on a test piece before attaching. No stretched/worn circumference or fit is predicted.",width,height,style.elasticOverlap,size.elasticLoop)
    } else {
      func guide(_ offset:Double,_ kind:SewingConstructionGuide.Kind,_ label:String,_ index:Int)->SewingConstructionGuide {
        var value=SewingConstructionGuide(edge:edge(0),offset:offset,kind:kind,label:label)
        if let oldGuides=old?.sewingPiece?.constructionGuides,oldGuides.indices.contains(index) {value.id=oldGuides[index].id}
        return value
      }
      var casing=guide(size.waistFold+style.casingDepth,.stitch,"Casing stitching reference",4)
      if role == .back {casing.opening=25}
      piece.constructionGuides=[guide(style.casingTurnUnder,.fold,"Top turn-under",0),
        guide(size.waistFold,.fold,"Nominal waist fold",1),guide(size.hemFold,.fold,"Nominal hem fold",2),
        guide(size.rawHeight-style.hemAllowance/2,.fold,"First half-hem turn",3),casing,
        guide(size.hemFold-style.hemAllowance/2,.stitch,"Hem stitching reference",5)]
      let hipPosition=(size.waistFold+size.waistToHip)/size.rawHeight
      piece.notches=[1,3].enumerated().map { position,index in
        var notch=SewingNotch(edge:index,position:index == 1 ? hipPosition:1-hipPosition)
        notch.edgeID=nodes[index].id;notch.endID=nodes[(index+1)%4].id;notch.depth=min(3,style.sideAllowance/2)
        if let oldNotches=old?.sewingPiece?.notches,oldNotches.indices.contains(position) {notch.id=oldNotches[position].id}
        return notch
      }
      piece.notes=String(format:"Declared body waist %.1f / hip %.1f mm; nominal body circumference %.1f and finished length %.1f mm. Sew both side seams through the full %.1f mm raw height, including casing/hem extensions; finish allowances. Turn the hem twice by %.1f mm and stitch its inner folded edge. Turn the top first %.1f then %.1f mm; stitch the casing with a 25 mm back opening. Thread the declared elastic, lap %.1f mm, secure and test its behavior before closing the opening. Input dimensions are construction guidance, not verified fit.",size.waist,size.hip,size.bodyCircumference,size.bodyLength,size.rawHeight,style.hemAllowance/2,style.casingTurnUnder,style.casingDepth,style.elasticOverlap)
    }
    e.sewingPiece=piece
    if old == nil {e.fillEnabled=false;e.stroke = .init(color:"#737D77",width:0.25)}
    return e
  }
  public static func sideSeam(_ name:String,block:GarmentBlock,size:GarmentResolvedSize,
    front:ArtworkElement,back:ArtworkElement,id:UUID=UUID())->SewingSeam {
    let firstEdge=name == "right" ? 1:3,secondEdge=name == "right" ? 3:1
    func endpoint(_ e:ArtworkElement,_ index:Int)->SewingSeamEnd {
      var end=SewingSeamEnd(elementID:e.id,edge:index)
      end.edgeID=e.path!.contours[0].nodes[index].id;end.endID=e.path!.contours[0].nodes[(index+1)%4].id
      return end
    }
    var seam=SewingSeam(name:block.name+" / "+size.label+" / "+name+" side, full raw height",
      first:endpoint(front,firstEdge),second:endpoint(back,secondEdge))
    seam.id=id;seam.reversed=true
    return seam
  }
}

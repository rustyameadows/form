import AppKit
import FormCore
import FormGeometry
import FormMeshAssets
import FormCADModeling

@MainActor enum PrintMeshBuilder {
  static func mesh(
    object: ProductObject, project: Project, assets: URL, configuration: PrintConfiguration
  ) throws -> PrintMesh {
    guard !PaperConstruction.isPaper(object) else{throw FormError.invalid("This is a folded paper construction. Use Paper Fabricate for its flat print/cut/score files; it is not an FDM print solid.")}
    if object.meshAsset != nil || object.cadRepresentation != nil {
      return try sourceMesh(object:object,assets:assets,configuration:configuration)
    }
    guard !object.isFlexibleSurface else {throw FormError.invalid(ClothStudy.unsupportedPrintReason)}
    guard !TextileDesign.recipeIDs.contains(object.recipeID) else {
      throw FormError.invalid("This is a textile presentation product. Export its linked artwork; it is not an FDM-printable mesh.")
    }
    let root = GeometryFactory.object(object, project: project, assets: assets)
    if object.recipeID == "deskClock" {
      guard DeskClockDesign.components.contains(configuration.component) else {throw FormError.invalid("Choose one desk-clock component; the assembled clock is not one fused print.")}
      let construction=root.childNodes.first
      let component=configuration.component=="Foot (print 4)" ? "Feet":configuration.component
      for node in construction?.childNodes ?? [] where node.name != "deskClock."+component {node.removeFromParentNode()}
      if component=="Feet",let group=construction?.childNodes.first,let foot=group.childNodes.first {
        // One foot in its own fabrication coordinates. Four assembled feet at
        // different depths must never become floating print islands.
        for other in group.childNodes where other !== foot {other.removeFromParentNode()}
        foot.position = .init(0,0.12,0);foot.eulerAngles = .init()
      }
      construction?.enumerateChildNodes {node,_ in if node.name=="display.inlay" {node.removeFromParentNode()}}
    }
    if object.recipeID == "clock" {
      let selected = [
        "Dial": "clock.dial", "Hour hand": "clock.hour", "Minute hand": "clock.minute",
      ][configuration.component]
      for node in root.childNodes
      where node.name == "clock.face" || selected != nil && node.name != selected
        || selected == nil && node.isHidden
      {
        node.removeFromParentNode()
      }
    }
    if object.recipeID == "lamp" {
      let index = ["Base": 0, "Stem": 1, "Shade": 2][configuration.component]
      for (i, node) in root.childNodes.enumerated() where index != nil ? i != index : i == 3 {
        node.removeFromParentNode()
      }
    }
    var triangles: [MeshTriangle] = []
    var failure: Error?
    root.enumerateChildNodes { node, stop in
      guard let original = node.geometry, !(original is MeshPlane) else { return }
      // Parametric primitives can initially expose a unit placeholder mesh.
      // Explicit preparation bakes their dimensions and chamfers even when the
      // object has never appeared in a rendered view. STL needs no materials.
      let geometry = original.copy() as! MeshGeometry
      geometry.materials = []
      guard let source = geometry.sources(for: .vertex).first
      else {
        failure = FormError.invalid("Could not prepare the object's mesh for export.")
        stop.pointee = true
        return
      }
      guard source.usesFloatComponents, [4, 8].contains(source.bytesPerComponent),
        source.componentsPerVector >= 3
      else {
        failure = FormError.invalid("Unsupported mesh vertex format.")
        stop.pointee = true
        return
      }
      func vertex(_ index: Int) -> Vector3 {
        let base = source.dataOffset + index * source.dataStride
        let values: [Double] = source.data.withUnsafeBytes { bytes in
          (0..<3).map { i in
            let offset = base + i * source.bytesPerComponent
            return source.bytesPerComponent == 4
              ? Double(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self))
              : bytes.loadUnaligned(fromByteOffset: offset, as: Double.self)
          }
        }
        let p = node.convertPosition(FormGeometry.MeshVector3(values[0], values[1], values[2]), to: root)
        var point = Vector3(Double(p.x) * 100, -Double(p.z) * 100, Double(p.y) * 100)
        let rotation = configuration.rotation
        for (axis, degrees) in [(0, rotation.x), (1, rotation.y), (2, rotation.z)] {
          let a = degrees * .pi / 180
          let c = cos(a)
          let s = sin(a)
          let old = point
          if axis == 0 {
            point.y = old.y * c - old.z * s
            point.z = old.y * s + old.z * c
          }
          if axis == 1 {
            point.x = old.x * c + old.z * s
            point.z = -old.x * s + old.z * c
          }
          if axis == 2 {
            point.x = old.x * c - old.y * s
            point.y = old.x * s + old.y * c
          }
        }
        let scale = configuration.scalePercent / 100
        return .init(point.x * scale, point.y * scale, point.z * scale)
      }
      for element in geometry.elements {
        guard [.triangles, .triangleStrip].contains(element.primitiveType) else { continue }
        let data = element.data
        let width = element.bytesPerIndex
        guard [1, 2, 4].contains(width) else { continue }
        let indices: [Int] = data.withUnsafeBytes { bytes in
          (0..<data.count / width).map { i in
            if width == 1 { return Int(bytes[i]) }
            if width == 2 {
              return Int(bytes.loadUnaligned(fromByteOffset: i * width, as: UInt16.self))
            }
            return Int(bytes.loadUnaligned(fromByteOffset: i * width, as: UInt32.self))
          }
        }
        let count =
          element.primitiveType == .triangles ? indices.count / 3 : max(0, indices.count - 2)
        for i in 0..<count {
          let a: Int
          let b: Int
          let c: Int
          if element.primitiveType == .triangles {
            a = indices[i * 3]
            b = indices[i * 3 + 1]
            c = indices[i * 3 + 2]
          } else {
            a = indices[i]
            b = indices[i + (i % 2 == 0 ? 1 : 2)]
            c = indices[i + (i % 2 == 0 ? 2 : 1)]
          }
          guard a < source.vectorCount, b < source.vectorCount, c < source.vectorCount else {
            continue
          }
          if a != b, b != c, a != c { triangles.append(.init(vertex(a), vertex(b), vertex(c))) }
        }
      }
    }
    if let failure { throw failure }
    guard !triangles.isEmpty else {
      throw FormError.invalid("This object has no printable solid geometry.")
    }
    return .init(triangles: triangles)
  }

  /// Stable source identities are embedded in labels so repeated names remain unambiguous.
  nonisolated static func sourceComponents(_ object:ProductObject)->[String]? {
    if let reference=object.meshAsset {
      var seen=Set<String>()
      return reference.parts.compactMap {part in guard seen.insert(part.nodeID).inserted else{return nil};return part.name+" ["+part.nodeID+"]"}
    }
    if let representation=object.cadRepresentation {return representation.components.map{$0.name+" ["+$0.id.uuidString+"]"}}
    return nil
  }

  /// Heavy source reads/topology inspection run independently of the native viewport.
  /// Print coordinates are mm, right-handed Z-up: source (x,y,z) -> (x,-z,y).
  nonisolated static func sourceMesh(object:ProductObject,assets:URL,configuration:PrintConfiguration)throws->PrintMesh {
    let choices=sourceComponents(object) ?? []
    func identity(_ label:String)->Substring? {guard let start=label.lastIndex(of:"["),label.last=="]" else{return nil};return label[label.index(after:start)..<label.index(before:label.endIndex)]}
    guard let selected=choices.firstIndex(where:{$0==configuration.component || identity($0) != nil && identity($0)==identity(configuration.component)}) else{throw FormError.invalid("Choose one named source component. Imported assemblies are not fused into a single print.")}
    var positions:[FormMeshAssets.MeshPoint3]=[],indices:[UInt32]=[]
    if let reference=object.meshAsset {
      let document=try ModelAssetCoordinator.readAsset(reference,assets:assets)
      var nodeIDs:[String]=[]
      for part in reference.parts where !nodeIDs.contains(part.nodeID) {nodeIDs.append(part.nodeID)}
      guard nodeIDs.indices.contains(selected),let node=document.nodes.first(where:{$0.id==nodeIDs[selected]}),node.inSelectedScene,let meshIndex=node.meshIndex else{throw FormError.invalid("The selected imported component is unavailable.")}
      for primitive in document.meshes[meshIndex].primitives {
        try Task.checkCancellation()
        let transformed=try MeshAssetGeometry.transformed(primitive,by:node.worldTransform),base=UInt32(positions.count)
        guard indices.count/3+transformed.indices.count/3<=300_000 else{throw FormError.invalid("Print topology inspection supports at most 300,000 triangles per component. Simplify or repair a fabrication copy first.")}
        positions.append(contentsOf:transformed.positionsMM.map{.init($0.x*object["scalePercent"]/100,$0.y*object["scalePercent"]/100,$0.z*object["scalePercent"]/100)})
        indices.append(contentsOf:transformed.indices.map{$0+base})
      }
    }else if let representation=object.cadRepresentation,let model=object.cadModel {
      try representation.validate(for:model)
      let component=representation.components[selected]
      guard component.valid,component.closed,component.solidCount==1 else{throw FormError.invalid("Choose a single validated closed CAD solid; multi-solid outputs require separate components before printing.")}
      _=try CADSceneAdapter.verifiedAsset(component.brepAsset,sha256:component.brepSHA256,assets:assets,maximumBytes:256*1024*1024)
      let data=try CADSceneAdapter.verifiedAsset(component.meshAsset,sha256:component.meshSHA256,assets:assets,maximumBytes:256*1024*1024),mesh=try CADMeshArchive.decode(data)
      guard mesh.indices.count/3==component.triangleCount,mesh.indices.count/3<=300_000 else{throw FormError.invalid("The CAD fabrication mesh is stale or exceeds the 300,000-triangle topology inspection limit.")}
      positions=mesh.positions.map{.init($0.x,$0.y,$0.z)};indices=mesh.indices
    }else{throw FormError.invalid("No preserved fabrication source is available.")}
    let primitive=MeshAssetPrimitive(id:"print-source",positionsMM:positions,normals:[],indices:indices)
    let report=try MeshTopology.inspect(primitive)
    guard report.isClosedOrientedSurface,report.signedVolumeMM3>1e-9 else{throw FormError.invalid("This component is not a verified outward closed mesh (\(report.boundaryEdges) boundary edges, \(report.nonManifoldEdges) non-manifold edges, \(report.inconsistentlyOrientedEdges) winding conflicts, \(report.degenerateTriangles) degenerate triangles). Repair it before print preparation. Visual garments and open surfaces are not printable solids.")}
    func point(_ index:UInt32)->Vector3 {
      let p=positions[Int(index)];var value=Vector3(p.x,-p.z,p.y)
      for (axis,degrees) in [(0,configuration.rotation.x),(1,configuration.rotation.y),(2,configuration.rotation.z)] {
        let a=degrees*Double.pi/180,c=cos(a),s=sin(a),old=value
        if axis==0 {value.y=old.y*c-old.z*s;value.z=old.y*s+old.z*c}
        if axis==1 {value.x=old.x*c+old.z*s;value.z = -old.x*s+old.z*c}
        if axis==2 {value.x=old.x*c-old.y*s;value.y=old.x*s+old.y*c}
      }
      let scale=configuration.scalePercent/100
      return .init(value.x*scale,value.y*scale,value.z*scale)
    }
    var triangles:[MeshTriangle]=[];triangles.reserveCapacity(indices.count/3)
    for i in stride(from:0,to:indices.count,by:3) {if i%8190==0 {try Task.checkCancellation()};triangles.append(.init(point(indices[i]),point(indices[i+1]),point(indices[i+2])))}
    return .init(triangles:triangles)
  }
}

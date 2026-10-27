import AppKit
import FormCore
import FormGraphics
import FormGeometry
import simd

@MainActor enum MerchandiseGeometry {
  static func point(_ v: Vector3) -> MeshVector3 { .init(v.x / 100, v.y / 100, v.z / 100) }
  static func material(_ id: String, _ project: Project) -> MeshMaterial {
    let m = MeshMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = NSColor(hex: project.material(id).color)
    m.roughness.contents = 0.92
    m.isDoubleSided = true
    return m
  }
  static func cloth(
    _ o: ProductObject, _ project: Project, _ assets: URL, _ limit: Int,
    uvScale: Point2 = .init(1, 1)
  )
    -> MeshMaterial
  {
    let m = GeometryFactory.material(o, project: project)
    m.isDoubleSided = true
    m.diffuse.mipFilter = .linear
    m.diffuse.minificationFilter = .linear
    m.diffuse.maxAnisotropy = 8
    if let design = try? project.resolvedFabricPattern(materialID: o.materialID) {
      m.diffuse.contents = FabricPatternRenderer.texture(
        design, assets: assets, limit: limit, fontRevision: GeometryFactory.fontRevision)
      let size = design.pattern.supertileSize(sourceSize: design.sourceSize)
      let t = Affine2.scale(1 / size.x, 1 / size.y).followed(
        by: design.pattern.latticeTransform.inverse!
      ).followed(by: .scale(uvScale.x, uvScale.y))
      var transform = MeshMatrix4Identity
      transform.m11 = t.a
      transform.m12 = t.b
      transform.m21 = t.c
      transform.m22 = t.d
      transform.m41 = t.tx
      transform.m42 = t.ty
      m.diffuse.contentsTransform = transform
      m.diffuse.wrapS = .repeat
      m.diffuse.wrapT = .repeat
    }
    if (try? project.resolvedFabricPattern(materialID: o.materialID)) == nil {
      var t = MeshMatrix4Identity
      t.m11 = uvScale.x / 32
      t.m22 = uvScale.y / 32
      m.diffuse.contentsTransform = t
      m.diffuse.wrapS = .repeat
      m.diffuse.wrapT = .repeat
    }
    return m
  }
  static func mesh(
    _ points: [Vector3], _ uv: [CGPoint], _ faces: [Int32], _ mat: MeshMaterial, _ name: String
  ) -> MeshNode {
    let vertices = points.map(point)
    let vectors = vertices.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
    var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
    for i in stride(from: 0, to: faces.count, by: 3) {
      let a = Int(faces[i])
      let b = Int(faces[i + 1])
      let c = Int(faces[i + 2])
      let n = simd_cross(vectors[b] - vectors[a], vectors[c] - vectors[a])
      normals[a] += n
      normals[b] += n
      normals[c] += n
    }
    let ns = normals.map { n -> MeshVector3 in
      let v = simd_length_squared(n) > 0 ? simd_normalize(n) : SIMD3<Float>(0, 1, 0)
      return .init(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z))
    }
    let g = MeshGeometry(
      sources: [
        MeshGeometrySource(vertices: vertices), MeshGeometrySource(normals: ns),
        MeshGeometrySource(textureCoordinates: uv),
      ], elements: [MeshGeometryElement(indices: faces, primitiveType: .triangles)])
    g.materials = [mat]
    let node = MeshNode(geometry: g)
    node.name = name
    node.categoryBitMask = 2
    return node
  }
  static func grid(
    columns: Int, rows: Int, sample: (Double, Double) -> Vector3, uv: (Double, Double) -> CGPoint,
    material: MeshMaterial, name: String, reverse: Bool = false,
    skip: ((Double, Double) -> Bool)? = nil
  ) -> MeshNode {
    var vertices: [Vector3] = []
    var tex: [CGPoint] = []
    var triangles: [Int32] = []
    for j in 0...rows {
      for i in 0...columns {
        let u = Double(i) / Double(columns)
        let v = Double(j) / Double(rows)
        vertices.append(sample(u, v))
        tex.append(uv(u, v))
      }
    }
    for j in 0..<rows {
      for i in 0..<columns {
        if skip?((Double(i) + 0.5) / Double(columns), (Double(j) + 0.5) / Double(rows)) == true {
          continue
        }
        let a = Int32(j * (columns + 1) + i)
        let b = a + 1
        let c = a + Int32(columns + 1)
        let d = c + 1
        triangles += reverse ? [a, b, c, b, d, c] : [a, c, b, b, c, d]
      }
    }
    return mesh(vertices, tex, triangles, material, name)
  }
  static func tube(_ points: [Vector3], radius: Double, material: MeshMaterial, name: String)
    -> MeshNode
  {
    let root = MeshNode()
    root.name = name
    for pair in zip(points, points.dropFirst()) {
      let a = SIMD3<Float>(Float(pair.0.x / 100), Float(pair.0.y / 100), Float(pair.0.z / 100))
      let b = SIMD3<Float>(Float(pair.1.x / 100), Float(pair.1.y / 100), Float(pair.1.z / 100))
      let delta = b - a
      guard simd_length(delta) > 0.000001 else { continue }
      let g = MeshCylinder(radius: radius / 100, height: Double(simd_length(delta)))
      g.radialSegmentCount = 5
      g.materials = [material]
      let n = MeshNode(geometry: g)
      n.simdPosition = (a + b) / 2
      n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(delta))
      n.categoryBitMask = 2
      root.addChildNode(n)
    }
    return root.flattenedClone()
  }
  static func shape(
    _ path: NSBezierPath, height: Double, y: Double, material: MeshMaterial, name: String
  ) -> MeshNode {
    path.flatness = 0.0002
    let g = MeshShape(path: path, extrusionDepth: height / 100)
    g.materials = [material]
    let n = MeshNode(geometry: g)
    n.eulerAngles.x = -.pi / 2
    n.position.y = CGFloat(y / 100) - g.boundingBox.min.z
    n.name = name
    n.categoryBitMask = 2
    return n
  }
  static func tee(_ o: ProductObject, project: Project, assets: URL, limit: Int) -> MeshNode {
    let root = MeshNode()
    let w = o["width"]
    let d = o["depth"]
    let s = o["sleeveLength"]
    let sw = o["sleeveWidth"]
    let y = o["loft"]
    let neck = o["neckWidth"]
    let drop = o["neckDrop"]
    let outline = [
      Point2(-w * 0.31, -d / 2), .init(w * 0.31, -d / 2), .init(w / 2 + s, -d * 0.43),
      .init(w / 2 + s, -d * 0.43 + sw), .init(w / 2, -d * 0.43 + sw + 36), .init(w * 0.49, d / 2),
      .init(-w * 0.49, d / 2), .init(-w / 2, -d * 0.43 + sw + 36),
      .init(-w / 2 - s, -d * 0.43 + sw), .init(-w / 2 - s, -d * 0.43),
    ]
    let path = NSBezierPath()
    path.move(to: .init(x: outline[0].x / 100, y: -outline[0].y / 100))
    for p in outline.dropFirst() { path.line(to: .init(x: p.x / 100, y: -p.y / 100)) }
    path.close()
    path.windingRule = .evenOdd
    let neckRect = NSRect(
      x: -neck / 200, y: (d / 2 - drop * 1.1) / 100, width: neck / 100, height: drop / 100)
    path.appendOval(in: neckRect)
    root.addChildNode(
      shape(
        path, height: y - 4, y: 4,
        material: cloth(o, project, assets, limit, uvScale: .init(w + 2 * s, d)),
        name: "Jersey body and short sleeves / open crew neck"))
    let rib = NSBezierPath(
      ovalIn: neckRect.insetBy(dx: -o["collarWidth"] / 100, dy: -o["collarWidth"] / 100))
    rib.windingRule = .evenOdd
    rib.appendOval(in: neckRect)
    root.addChildNode(
      shape(
        rib, height: 2, y: y + 0.3,
        material: material(o.textile?.trimMaterialID ?? "merch-rib", project),
        name: "Independent rib-knit crew collar"))
    let seam = material("merch-rib", project)
    root.addChildNode(
      tube(
        [.init(-w * 0.47, y + 0.35, d / 2 - 14), .init(w * 0.47, y + 0.35, d / 2 - 14)],
        radius: 0.45, material: seam, name: "Double-needle hem"))
    for sign in [-1.0, 1.0] {
      root.addChildNode(
        tube(
          [
            .init(sign * (w / 2 + s - 12), y + 0.4, -d * 0.43 + 6),
            .init(sign * (w / 2 + s - 12), y + 0.4, -d * 0.43 + sw - 6),
          ], radius: 0.45, material: seam, name: "Sleeve hem"))
    }
    return root
  }
  static func cap(_ o: ProductObject, project: Project, assets: URL, limit: Int) -> MeshNode {
    let root = MeshNode()
    let mat = cloth(o, project, assets, limit)
    let r = o["width"] / 2
    let h = o["height"]
    let reach = o["depth"]
    root.addChildNode(
      grid(
        columns: 128, rows: 40,
        sample: { u, v in MerchandiseBlanks.crown(o, angle: (u * 2 - 1) * Double.pi, t: v) },
        uv: { u, v in .init(x: (u * 2 - 1) * Double.pi * r, y: v * h) }, material: mat,
        name: "Four-panel curved crown / actual back opening",
        skip: { u, v in abs((u * 2 - 1) * Double.pi) > Double.pi - 0.28 && v < 0.43 }))
    let trim = material(o.textile?.trimMaterialID ?? "merch-twill", project)
    let seam = material("label-ecru", project)
    for angle in MerchandiseBlanks.capSeamAngles {
      let line = (0...28).map { i -> Vector3 in
        var p = MerchandiseBlanks.crown(o, angle: angle, t: Double(i) / 28)
        p.x *= 1.003
        p.z *= 1.003
        p.y += 0.3
        return p
      }
      root.addChildNode(tube(line, radius: 0.4, material: seam, name: "Crown panel seam"))
    }
    root.addChildNode(
      grid(
        columns: 48, rows: 12,
        sample: { u, v in
          let edge = pow(abs(u - 0.5) * 2, 2)
          let rearX = (u - 0.5) * o["width"] * 0.88
          let rearZ = -sqrt(max(0, r * r - rearX * rearX))
          let frontZ = -r - reach * (1 - 0.3 * edge)
          return .init(
            (u - 0.5) * (o["width"] * 0.88 * (1 - v) + o["brimWidth"] * v),
            o["brimCurve"] + 6 - o["brimCurve"] * edge, rearZ * (1 - v) + frontZ * v)
        }, uv: { u, v in .init(x: u * o["brimWidth"], y: v * reach) }, material: trim,
        name: "Curved twill visor", reverse: true))
    let band = (0...100).map { i in
      let a = Double(i) / 100 * Double.pi * 2
      return Vector3((r - 3) * sin(a), 6, -(r - 3) * cos(a))
    }
    root.addChildNode(tube(band, radius: 3, material: trim, name: "Sweatband / open underside"))
    root.addChildNode(GeometryFactory.box(48, 5, 6, trim, y: 12, z: r - 1, corner: 2))
    let button = MeshSphere(radius: 0.055)
    button.segmentCount = 12
    button.materials = [trim]
    let node = MeshNode(geometry: button)
    node.position = point(.init(0, h + 2, 0))
    node.name = "Covered crown button"
    node.categoryBitMask = 2
    root.addChildNode(node)
    return root
  }
  static func tote(_ o: ProductObject, project: Project, assets: URL, limit: Int) -> MeshNode {
    let root = MeshNode()
    let w = o["width"]
    let d = o["depth"]
    let g = o["gusset"]
    let mat = cloth(o, project, assets, limit)
    let trim = material(o.textile?.trimMaterialID ?? "merch-webbing", project)
    func panel(
      _ name: String, _ sample: @escaping (Double, Double) -> Vector3, _ width: Double,
      _ height: Double, reverse: Bool = false
    ) {
      root.addChildNode(
        grid(
          columns: 16, rows: 20, sample: sample, uv: { u, v in .init(x: u * width, y: v * height) },
          material: mat, name: name, reverse: reverse))
    }
    panel("Front canvas panel", { u, v in .init((u - 0.5) * w, g + 6, (v - 0.5) * d) }, w, d)
    panel("Back canvas panel", { u, v in .init((u - 0.5) * w, 6, (0.5 - v) * d) }, w, d)
    for sign in [-1.0, 1.0] {
      panel(
        sign > 0 ? "Left gusset" : "Right gusset",
        { u, v in .init(sign * w / 2, 6 + u * g, (v - 0.5) * d) }, g, d, reverse: sign > 0)
    }
    panel("Bottom gusset", { u, v in .init((u - 0.5) * w, 6 + v * g, d / 2) }, w, g, reverse: true)
    for y in [6.0, g + 6] {
      let hem = [
        Vector3(-w / 2, y + 0.3, -d / 2 + o["topHem"]), .init(w / 2, y + 0.3, -d / 2 + o["topHem"]),
      ]
      root.addChildNode(tube(hem, radius: 0.65, material: trim, name: "Top turned hem"))
      // Ribbon handles stay connected to the top corners; the open center remains unobstructed.
      let drop = o["handleDrop"]
      let span = o["handleSpan"]
      let hw = o["handleWidth"]
      root.addChildNode(
        grid(
          columns: 48, rows: 1,
          sample: { u, v in
            let a = Double.pi * (1 - u)
            let x = cos(a) * span / 2
            let z = -d / 2 - sin(a) * drop
            let normal = Vector3(cos(a), 0, -sin(a))
            return .init(x + normal.x * (v - 0.5) * hw, y + 2, z + normal.z * (v - 0.5) * hw)
          }, uv: { u, v in .init(x: u * Double.pi * span, y: v * hw) }, material: trim,
          name: y > 10 ? "Front webbing handle" : "Back webbing handle"))
    }
    return root
  }
  static func directArtwork(_ o: ProductObject, project: Project, assets: URL, limit: Int)
    -> MeshNode
  {
    guard let art = project.surfaceArtwork(o) else { return MeshNode() }
    guard let a = o.textile?.attachment,
      let host = project.objects.first(where: { $0.id == a.garmentID }),
      host.recipeID == "curvedCap",
      let zone = MerchandiseBlanks.zones(host).first(where: { $0.id == a.zone })
    else {
      return GeometryFactory.artworkPlane(
        art, width: o["width"], depth: o["depth"], y: o["height"], assets: assets,
        textureLimit: limit)
    }
    let center = MerchandiseBlanks.sample(
      host, zone: zone, u: a.offset.x, v: a.offset.y, clearance: a.clearance
    ).point
    let plane = GeometryFactory.artworkPlane(
      art, width: o["width"], depth: o["depth"], y: 0, assets: assets, textureLimit: limit)
    let mat =
      plane.geometry?.firstMaterial?.copy() as? MeshMaterial ?? material("label-ecru", project)
    let angle = a.rotation * Double.pi / 180
    let c = cos(angle)
    let s = sin(angle)
    let node = grid(
      columns: 48, rows: 16,
      sample: { u, v in
        let x = (u - 0.5) * o["width"]
        let y = (v - 0.5) * o["depth"]
        let p = MerchandiseBlanks.sample(
          host, zone: zone, u: a.offset.x + x * c + y * s, v: a.offset.y - x * s + y * c,
          clearance: a.clearance + o["height"]
        ).point
        return .init(p.x - center.x, p.y - center.y, p.z - center.z)
      }, uv: { u, v in .init(x: u, y: v) }, material: mat,
      name: "Conforming direct artwork / physical arc-mm UV")
    node.renderingOrder = 4
    return node
  }
}

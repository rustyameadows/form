import AppKit
import FormCore
import FormGeometry
import FormGraphics
import LabRendering
import simd

/// Builds a static, ordinary vector element from object-local display geometry.
/// Camera angles belong to the placement; table position and rotation are ignored.
@MainActor enum ObjectViewProjection {
  static func make(object: ProductObject, project: Project, assets: URL,
                   azimuth: Double, elevation: Double, style: String) throws -> ArtworkElement {
    guard azimuth.isFinite, elevation.isFinite else { throw FormError.invalid("Choose finite view angles.") }
    var triangles: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
    if let reference = object.meshAsset {
      let document = try ModelAssetCoordinator.readAsset(reference, assets: assets)
      let scene = try MeshAssetSceneAdapter.prepare(document: document, reference: reference)
      for component in scene.components {
        try append(mesh: component.sourceMesh, transform: component.sourceTransform, to: &triangles)
      }
    } else if object.cadRepresentation != nil {
      var local = object
      local.position = .init(); local.rotation = 0
      let scene = try CADSceneAdapter.prepare(for: local, assets: assets)
      for item in scene.renderables { try append(mesh: item.mesh, transform: item.transform, to: &triangles) }
    } else {
      let root = GeometryFactory.object(object, project: project, assets: assets)
      try collect(root, into: &triangles)
    }
    return try Self.project(triangles, azimuth: azimuth, elevation: elevation, style: style, name: object.name)
  }

  /// Fits an updated view into an existing placement without stretching it or
  /// changing the placement's frame. Empty space is centered around the view.
  static func fit(_ generated: ArtworkElement, into destination: ArtworkElement) -> VectorPath? {
    guard var path = generated.path, path.width > 0, path.height > 0,
      destination.width > 0, destination.height > 0 else { return nil }
    // Existing paths retain their original coordinate frame during resizing.
    // Fitting into it preserves intentional nonuniform placement scaling.
    let frameWidth = destination.path?.width ?? destination.width
    let frameHeight = destination.path?.height ?? destination.height
    guard frameWidth > 0, frameHeight > 0 else { return nil }
    let scale = min(frameWidth / path.width, frameHeight / path.height)
    let x = (frameWidth - path.width * scale) / 2
    let y = (frameHeight - path.height * scale) / 2
    func map(_ p: Point2) -> Point2 { .init(p.x * scale + x, p.y * scale + y) }
    for contour in path.contours.indices {
      for node in path.contours[contour].nodes.indices {
        var value = path.contours[contour].nodes[node]
        value.anchor = map(value.anchor)
        value.incoming = value.incoming.map(map)
        value.outgoing = value.outgoing.map(map)
        path.contours[contour].nodes[node] = value
      }
    }
    path.width = frameWidth; path.height = frameHeight
    return path
  }

  private static let triangleLimit = 20_000
  private static func collect(_ node: MeshNode, into triangles: inout [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)]) throws {
    guard !node.isHidden, node.opacity > 0 else { return }
    if let geometry = node.geometry {
      let matrix = node.worldTransform.raw
      let vertices = geometry.sources(for: .vertex).first?.vectors.map { value -> SIMD3<Double> in
        let p = matrix * SIMD4(value.simd, 1); return .init(p.x, p.y, p.z)
      } ?? []
      for element in geometry.elements {
        let indices = element.indices
        func add(_ a: UInt32, _ b: UInt32, _ c: UInt32) throws {
          guard Int(a) < vertices.count, Int(b) < vertices.count, Int(c) < vertices.count else { return }
          guard triangles.count < triangleLimit else { throw FormError.invalid("This object has too many triangles for a vector view. Use a simpler model.") }
          triangles.append((vertices[Int(a)], vertices[Int(b)], vertices[Int(c)]))
        }
        switch element.primitiveType {
        case .triangles:
          if indices.count >= 3 { for i in stride(from: 0, through: indices.count - 3, by: 3) { try add(indices[i], indices[i+1], indices[i+2]) } }
        case .triangleStrip:
          if indices.count >= 3 { for i in 0..<(indices.count - 2) { try add(indices[i], indices[i+1], indices[i+2]) } }
        case .line, .point: break
        }
      }
    }
    for child in node.childNodes { try collect(child, into: &triangles) }
  }

  private static func append(mesh: SceneMeshPayload, transform: SceneTransformPayload,
                             to triangles: inout [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)]) throws {
    let rotation = simd_quatd(vector: transform.rotationXYZW)
    let points = mesh.positionsMM.map { rotation.act($0 * transform.scale) + transform.translationMM }
    for part in mesh.parts {
      let indices = part.triangleIndices
      if indices.count >= 3 { for i in stride(from: 0, through: indices.count - 3, by: 3) {
        let a = Int(indices[i]), b = Int(indices[i+1]), c = Int(indices[i+2])
        guard a < points.count, b < points.count, c < points.count else { continue }
        guard triangles.count < triangleLimit else { throw FormError.invalid("This object has too many triangles for a vector view. Use a simpler model.") }
        triangles.append((points[a], points[b], points[c]))
      } }
    }
  }

  /// Internal entry point also permits deterministic tests without a renderer.
  static func project(_ triangles: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)],
                      azimuth: Double, elevation: Double, style: String, name: String) throws -> ArtworkElement {
    guard ["silhouette", "lines"].contains(style), azimuth.isFinite, elevation.isFinite else {
      throw FormError.invalid("Choose silhouette or lines and finite view angles.")
    }
    let a = azimuth * .pi / 180, e = elevation * .pi / 180
    let right = SIMD3<Double>(cos(a), 0, -sin(a))
    let up = SIMD3<Double>(-sin(a)*sin(e), cos(e), -cos(a)*sin(e))
    func point(_ p: SIMD3<Double>) -> CGPoint { .init(x: simd_dot(p, right), y: -simd_dot(p, up)) }
    var framing = ObjectViewFraming()
    for (a, b, c) in triangles { try framing.include(a); try framing.include(b); try framing.include(c) }
    let fixedFrame = try framing.bounds()
    let raw = CGMutablePath()
    for (a, b, c) in triangles {
      let p = point(a), q = point(b), r = point(c)
      let cross = (q.x-p.x)*(r.y-p.y)-(q.y-p.y)*(r.x-p.x)
      guard cross.isFinite, abs(cross) > 1e-12 else { continue }
      raw.move(to: p)
      // Keep every projected triangle winding the same way, regardless of face orientation.
      raw.addLine(to: cross > 0 ? q : r); raw.addLine(to: cross > 0 ? r : q); raw.closeSubpath()
    }
    guard !raw.isEmpty else { throw FormError.invalid("This object has no projectable surfaces from that angle.") }
    // Self-union removes triangle seams, producing a true outline including holes.
    let silhouette = raw.union(raw, using: .winding)
    let bounds = silhouette.boundingBoxOfPath
    guard bounds.width > 1e-10, bounds.height > 1e-10 else { throw FormError.invalid("This view has no area.") }
    // The canvas is a fixed square around the object-space bounding sphere.
    // Unlike projected bounds, its scale and center do not change with angle.
    let scale = 60 / (ObjectViewFraming.diameterPadding * fixedFrame.radius)
    let center = point(fixedFrame.center)
    var transform = CGAffineTransform(translationX: 30 - center.x * scale,
                                      y: 30 - center.y * scale).scaledBy(x: scale, y: scale)
    let drawing = CGMutablePath()
    drawing.addPath(silhouette)
    if style == "lines" {
      drawing.addPath(try visibleEdges(triangles, right: right, up: up, bounds: bounds))
    }
    guard let scaled = drawing.copy(using: &transform) else { throw FormError.invalid("Could not build the object view.") }
    var element = try VectorGeometry.element(from: scaled, color: "#292D2C", name: name + " view")
    // element(from:) tightens to painted bounds. Restore its coordinates within
    // the fixed frame, including empty margins and negative/offset model origins.
    if var path = element.path {
      let offset = Affine2.translation(element.x, element.y)
      for i in path.contours.indices {
        path.contours[i].nodes = path.contours[i].nodes.map { PathCommands.transformed($0, by: offset) }
      }
      path.width = 60; path.height = 60; element.path = path
    }
    element.x = 0; element.y = 0; element.width = 60; element.height = 60
    if style == "lines" { element.fillEnabled = false; element.stroke = .init(color: "#292D2C", width: 0.5) }
    else { element.fillEnabled = true }
    return element
  }

  private struct EdgePointKey: Hashable, Comparable {
    var x: Int64, y: Int64, z: Int64
    static func < (a: Self, b: Self) -> Bool {
      if a.x != b.x { return a.x < b.x }; if a.y != b.y { return a.y < b.y }; return a.z < b.z
    }
  }
  private struct EdgeKey: Hashable, Comparable {
    var a: EdgePointKey, b: EdgePointKey
    static func < (a: Self, b: Self) -> Bool { a.a == b.a ? a.b < b.b : a.a < b.a }
  }
  private struct ProjectedTriangle {
    var a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>
  }
  private struct ProjectedEdge {
    var a: SIMD3<Double>, b: SIMD3<Double>, normals: [SIMD3<Double>]
  }

  /// Finds mesh boundary/crease edges and clips them against closer faces. Coplanar
  /// triangle seams are omitted. A spatial grid bounds the amount of interactive work.
  private static func visibleEdges(_ triangles: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)],
                                   right: SIMD3<Double>, up: SIMD3<Double>, bounds: CGRect) throws -> CGPath {
    let depth = simd_cross(right, up), unit = max(bounds.width, bounds.height)
    func projected(_ p: SIMD3<Double>) -> SIMD3<Double> {
      .init((simd_dot(p, right) - bounds.minX) / unit,
            (-simd_dot(p, up) - bounds.minY) / unit, simd_dot(p, depth) / unit)
    }
    let projectedTriangles = triangles.map { ProjectedTriangle(a: projected($0.0), b: projected($0.1), c: projected($0.2)) }
    // Quantize relative to the model, not the table origin; coincident vertices in
    // separate mesh buffers can then share an edge without merging nearby details.
    let center = projectedTriangles.first?.a ?? .zero
    let depthExtent = projectedTriangles.reduce(1.0) { result, t in
      max(result, abs(t.a.z-center.z), abs(t.b.z-center.z), abs(t.c.z-center.z))
    }
    let quantum = max(1e-9, depthExtent * 1e-9)
    func key(_ p: SIMD3<Double>) -> EdgePointKey {
      func part(_ n: Double) -> Int64 { Int64(max(-1e15, min(1e15, ((n / quantum).rounded())))) }
      return .init(x: part(p.x-center.x), y: part(p.y-center.y), z: part(p.z-center.z))
    }
    var edges: [EdgeKey: ProjectedEdge] = [:]
    for t in projectedTriangles {
      let cross = simd_cross(t.b-t.a, t.c-t.a), length = simd_length(cross)
      guard length.isFinite, length > 1e-12 else { continue }
      let normal = cross / length
      for (p, q) in [(t.a,t.b), (t.b,t.c), (t.c,t.a)] {
        let first = key(p), second = key(q)
        guard first != second else { continue }
        let id = first < second ? EdgeKey(a:first,b:second) : EdgeKey(a:second,b:first)
        if edges[id] == nil { edges[id] = .init(a:p,b:q,normals:[normal]) }
        else { edges[id]!.normals.append(normal) }
      }
    }
    let gridSize = 32, workLimit = 2_000_000
    var grid = [[Int]](repeating: [], count: gridSize * gridSize), work = 0
    func cell(_ n: Double) -> Int { max(0, min(gridSize-1, Int(floor(n * Double(gridSize))))) }
    func cells(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> (Int,Int,Int,Int) {
      (cell(min(a.x,b.x,c.x)), cell(max(a.x,b.x,c.x)), cell(min(a.y,b.y,c.y)), cell(max(a.y,b.y,c.y)))
    }
    func cross2(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x*b.y-a.y*b.x }
    for (i,t) in projectedTriangles.enumerated() {
      guard abs(cross2(t.b-t.a,t.c-t.a)) > 1e-12 else { continue }
      let (x0,x1,y0,y1) = cells(t.a,t.b,t.c)
      work += (x1-x0+1)*(y1-y0+1)
      guard work <= workLimit else { throw FormError.invalid("This model is too complex for a line view. Use a simpler model or silhouette.") }
      for y in y0...y1 { for x in x0...x1 { grid[y*gridSize+x].append(i) } }
    }
    let output = CGMutablePath()
    // A face is considered in front only beyond this relative tolerance. This
    // avoids a triangle hiding its own boundary because of floating-point noise.
    let depthEpsilon = max(1e-8, depthExtent * 1e-8)
    for id in edges.keys.sorted() {
      guard let edge = edges[id] else { continue }
      if edge.normals.count > 1 && edge.normals.dropFirst().allSatisfy({ abs(simd_dot(edge.normals[0],$0)) > 0.94 }) { continue }
      let a=edge.a, b=edge.b
      guard hypot(b.x-a.x,b.y-a.y) > 1e-10 else { continue }
      let (x0,x1,y0,y1) = cells(a,b,b)
      var candidates = Set<Int>()
      for y in y0...y1 { for x in x0...x1 { candidates.formUnion(grid[y*gridSize+x]) } }
      work += candidates.count
      guard work <= workLimit else { throw FormError.invalid("This model is too complex for a line view. Use a simpler model or silhouette.") }
      var hidden: [(Double,Double)] = []
      for index in candidates {
        let t=projectedTriangles[index], v=t.b-t.a, w=t.c-t.a, den=cross2(v,w)
        guard abs(den)>1e-12 else { continue }
        // Barycentric coordinates vary linearly along an edge.
        func weights(_ p: SIMD3<Double>) -> SIMD3<Double> {
          let d=p-t.a, beta=cross2(d,w)/den, gamma=cross2(v,d)/den
          return .init(1-beta-gamma,beta,gamma)
        }
        let wa=weights(a), wb=weights(b)
        var low=0.0, high=1.0
        for component in 0..<3 {
          let start=wa[component], delta=wb[component]-start
          if abs(delta)<1e-14 { if start < -1e-10 { high = -1; break } }
          else {
            let boundary = (-1e-10-start)/delta
            if delta>0 { low=max(low,boundary) } else { high=min(high,boundary) }
          }
        }
        guard low<high else { continue }
        let za=wa.x*t.a.z+wa.y*t.b.z+wa.z*t.c.z-a.z-depthEpsilon
        let zb=wb.x*t.a.z+wb.y*t.b.z+wb.z*t.c.z-b.z-depthEpsilon
        let slope=zb-za
        if abs(slope)<1e-14 { if za <= 0 { continue } }
        else { let boundary = -za/slope; if slope>0 { low=max(low,boundary) } else { high=min(high,boundary) } }
        low=max(0,low); high=min(1,high)
        if low<high { hidden.append((low,high)) }
      }
      hidden.sort { $0.0 < $1.0 }
      var cursor=0.0
      func draw(_ start: Double, _ end: Double) {
        guard end-start > 1e-8 else { return }
        let p=a+(b-a)*start, q=a+(b-a)*end
        output.move(to:.init(x:p.x*unit+bounds.minX,y:p.y*unit+bounds.minY))
        output.addLine(to:.init(x:q.x*unit+bounds.minX,y:q.y*unit+bounds.minY))
      }
      for (start,end) in hidden { if start>cursor { draw(cursor,start) }; cursor=max(cursor,end); if cursor>=1 { break } }
      if cursor<1 { draw(cursor,1) }
    }
    return output
  }

}

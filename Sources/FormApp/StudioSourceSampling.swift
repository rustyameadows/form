import AppKit
import FormCore
import FormGraphics
import FormGeometry
import LabRendering
import simd

/// Resolves source demand from the actual frozen scene and output camera.
/// Viewport clipping weights allocation; it never crops or rescales saved artwork.
@MainActor enum StudioSourceSampling {
  private struct Entry {
    let objectID: UUID
    let surface: String?
    let target: SourceTextureSamplingTarget
  }
  static func plans(controller: TableSceneController, project: Project,
    camera: SceneCameraPayload, viewport: CGSize, objectIDs: Set<UUID>, maximumEdge: Int
  ) throws -> [UUID: SourceTextureSamplingPlan] {
    var entries = [Entry]()
    func add(_ id: UUID, surface: String?, width: Double, height: Double,
      demand: (edge: Double, weight: Double)) throws {
      guard entries.count < SourceTextureSampling.maximumTargets else {
        throw FormError.invalid("This final capture has too many physical texture surfaces for its bounded source budget.")
      }
      let key = id.uuidString + "/" + (surface ?? "artwork")
      entries.append(.init(objectID: id, surface: surface,
        target: .init(id: key, sourceWidth: width, sourceHeight: height,
          projectedEdgePixels: demand.edge, visibleWeight: demand.weight)))
    }
    for subject in controller.objectRoot.childNodes {
      guard !subject.isHidden, let name = subject.name, name.hasPrefix("object:"),
        let id = UUID(uuidString: String(name.dropFirst(7))), objectIDs.contains(id),
        let object = project.objects.first(where: { $0.id == id }) else { continue }
      if PaperConstruction.isPaper(object) {
        let paper = try PaperConstruction.definition(for: object), net = try paper.net()
        for panel in net.panels {
          guard let node = subject.childNode(withName: PaperGeometry.panelPrefix + panel.id, recursively: true) else { continue }
          let rect = panel.bounds
          for inside in [false, true] {
            let z = (inside ? -1.0 : 1.0) * paper.stock.resolvedThicknessMM / 200
            let local: [MeshVector3] = [.init(rect.x/100,-rect.y/100,z),
              .init((rect.x+rect.width)/100,-rect.y/100,z),
              .init((rect.x+rect.width)/100,-(rect.y+rect.height)/100,z),
              .init(rect.x/100,-(rect.y+rect.height)/100,z)]
            let world = local.map { node.convertPosition($0, to: nil).simd * 100 }
            let base = node.convertPosition(.init(0,0,0), to: nil).simd
            let tip = node.convertPosition(.init(0,0,inside ? -1:1), to: nil).simd
            let eye = SIMD3(camera.worldFromCameraMM.columns.3.x, camera.worldFromCameraMM.columns.3.y, camera.worldFromCameraMM.columns.3.z)
            let direction: SIMD3<Double>
            switch camera.projection {
            case .perspective: direction = eye - world[0]
            case .orthographic: direction = SIMD3(camera.worldFromCameraMM.columns.2.x,camera.worldFromCameraMM.columns.2.y,camera.worldFromCameraMM.columns.2.z)
            }
            let facing = simd_dot(tip-base,direction) > 0
            let opacity = PaperGeometry.faceAppearance(for: object,stock: paper.stock,project: project,inside: inside).profile.opacity
            var demand = quadDemand(world: world,width: rect.width,height: rect.height,camera: camera,viewport: viewport)
            if !facing { demand.weight *= opacity < 0.999 ? 0.25 : 0 }
            try add(id,surface: SourceTextureSamplingPlan.paperFace(panel.id,inside: inside),
              width: rect.width,height: rect.height,demand: demand)
          }
        }
      } else if let assembly = try AssemblyProducts.product(for: object,in: project),
        let node = subject.childNode(withName: "cloth.surface",recursively: true),let mesh = node.geometry {
        let ordered = assembly.panels.sorted { $0.panelIndex < $1.panelIndex }
        for (slot,panel) in ordered.enumerated() where slot < mesh.elements.count {
          let demand = meshDemand(mesh,node: node,slot: slot,width: panel.materialSizeMm.x,
            height: panel.materialSizeMm.y,camera: camera,viewport: viewport)
          try add(id,surface: SourceTextureSamplingPlan.clothPanel(panel.panelIndex),
            width: panel.materialSizeMm.x,height: panel.materialSizeMm.y,demand: demand)
        }
      } else {
        guard project.surfaceArtwork(object) != nil || object.textile?.embroidery != nil
          || object.surfaceArtworkBindings?.isEmpty == false
          || (try? project.resolvedFabricPattern(materialID: object.materialID)) != nil else { continue }
        let b = controller.localBounds(for: id) ?? subject.boundingBox
        var points = [SIMD3<Double>]()
        for x in [b.min.x,b.max.x] { for y in [b.min.y,b.max.y] { for z in [b.min.z,b.max.z] {
          points.append(subject.convertPosition(.init(x,y,z),to: nil).simd * 100)
        } } }
        let coverage = projectedCoverage(points,camera: camera,viewport: viewport)
        let size = object.artworkSize
        try add(id,surface: nil,width: max(0.001,size.x),height: max(0.001,size.y),
          demand: (max(coverage.bounds.width,coverage.bounds.height),coverage.weight))
      }
    }
    let allocated = try SourceTextureSampling.allocate(entries.map(\.target),maximumEdge: maximumEdge)
    var result = [UUID: SourceTextureSamplingPlan]()
    for entry in entries {
      guard let raster = allocated[entry.target.id] else { continue }
      if var plan = result[entry.objectID] {
        plan.raster.maximumEdge = max(plan.raster.maximumEdge,raster.maximumEdge)
        plan.raster.maximumPixels += raster.maximumPixels
        if let surface = entry.surface { plan.surfaces[surface] = raster }
        result[entry.objectID] = plan
      } else {
        result[entry.objectID] = .init(raster: raster,
          surfaces: entry.surface.map { [$0:raster] } ?? [:],isFinalCapture: true)
      }
    }
    return result
  }

  static func quadDemand(world: [SIMD3<Double>], width: Double, height: Double,
    camera: SceneCameraPayload, viewport: CGSize) -> (edge: Double, weight: Double) {
    let coverage = projectedCoverage(world,camera: camera,viewport: viewport)
    let points = world.compactMap { SceneProjection.project($0,camera: camera,viewport: viewport) }
    guard points.count == 4, width > 0,height > 0 else {
      return (max(coverage.bounds.width,coverage.bounds.height),coverage.weight)
    }
    let source: [CGPoint] = [.zero,.init(x: width,y: 0),.init(x: width,y: height),.init(x: 0,y: height)]
    let density = max(derivative(source[0],source[1],source[2],points[0],points[1],points[2]),
      derivative(source[0],source[2],source[3],points[0],points[2],points[3]))
    return (density * max(width,height),coverage.weight)
  }
  private static func meshDemand(_ mesh: MeshGeometry,node: MeshNode,slot: Int,width: Double,height: Double,
    camera: SceneCameraPayload,viewport: CGSize) -> (edge: Double,weight: Double) {
    let vertices = mesh.sources(for: .vertex).first?.vectors ?? []
    let uv = mesh.sources(for: .texcoord).first?.points ?? []
    let indices = mesh.elements[slot].indices
    var world = [SIMD3<Double>](),density = 0.0
    for index in stride(from: 0,to: indices.count,by: 3) where index+2 < indices.count {
      let ids = [Int(indices[index]),Int(indices[index+1]),Int(indices[index+2])]
      guard ids.allSatisfy({$0 < vertices.count && $0 < uv.count}) else { continue }
      let triangle = ids.map { node.convertPosition(vertices[$0],to: nil).simd * 100 }
      world += triangle
      let projected = triangle.compactMap { SceneProjection.project($0,camera: camera,viewport: viewport) }
      guard projected.count == 3 else { continue }
      let source = ids.map { CGPoint(x: uv[$0].x*width,y: uv[$0].y*height) }
      density = max(density,derivative(source[0],source[1],source[2],projected[0],projected[1],projected[2]))
    }
    let coverage = projectedCoverage(world,camera: camera,viewport: viewport)
    return (max(density*max(width,height),max(coverage.bounds.width,coverage.bounds.height)),coverage.weight)
  }
  private static func derivative(_ a: CGPoint,_ b: CGPoint,_ c: CGPoint,
    _ p: CGPoint,_ q: CGPoint,_ r: CGPoint) -> Double {
    let u = b-a,v = c-a,s = q-p,t = r-p,det = u.x*v.y-v.x*u.y
    guard abs(det)>1e-12 else { return 0 }
    let j00 = (s.x*v.y-t.x*u.y)/det,j01 = (t.x*u.x-s.x*v.x)/det
    let j10 = (s.y*v.y-t.y*u.y)/det,j11 = (t.y*u.x-s.y*v.x)/det
    let trace = j00*j00+j01*j01+j10*j10+j11*j11,area = j00*j11-j01*j10
    let value = sqrt(max(0,(trace+sqrt(max(0,trace*trace-4*area*area)))/2))
    return value.isFinite ? value : 0
  }
  private static func projectedCoverage(_ world: [SIMD3<Double>],camera: SceneCameraPayload,
    viewport: CGSize) -> (bounds: CGRect,weight: Double) {
    let points = world.compactMap { SceneProjection.project($0,camera: camera,viewport: viewport) }
    guard let first = points.first else { return (.zero,0) }
    var bounds = CGRect(origin: first,size: .zero)
    for p in points.dropFirst() { bounds = bounds.union(CGRect(origin: p,size: .zero)) }
    // A near-plane crossing needs conservative full-viewport coverage, never a NaN.
    if points.count != world.count { bounds = bounds.union(CGRect(origin: .zero,size: viewport)) }
    let clipped = bounds.intersection(CGRect(origin: .zero,size: viewport))
    return (bounds,clipped.isNull ? 0 : max(0,clipped.width*clipped.height))
  }
}

private func - (a: CGPoint,b: CGPoint) -> CGPoint { .init(x: a.x-b.x,y: a.y-b.y) }

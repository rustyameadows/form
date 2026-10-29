import AppKit
import CryptoKit
import FormCore
import FormGraphics
import FormGeometry

private func v(_ x:Double,_ y:Double,_ z:Double)->MeshVector3 {.init(x,y,z)}
private func mm(_ value:Double)->CGFloat {CGFloat(value/100)}

@MainActor enum GeometryFactory {
  static func artworkDefinition(_ artwork:Artwork,object:ProductObject)->Artwork {
    object.textile?.embroidery != nil ? artwork.embroideryRenderDefinition:artwork.renderDefinition
  }
  static func geometryParameters(_ object: ProductObject) -> [String: Double] {
    if PaperConstruction.isPaper(object) {return object.parameters.filter{!["fold","foldPercent","opening","openingPercent"].contains($0.key)}}
    return ["clock","deskClock"].contains(object.recipeID)
      ? object.parameters.filter { !["hour", "minute", "hands"].contains($0.key) }
      : object.parameters
  }
  private(set) static var fontRevision = 0
  static func invalidateFontResources() {
    cache.removeAllObjects()
    artworkImages.removeAllObjects()
    EmbroiderySurface.invalidate()
    fontRevision += 1
  }
  private static let cache: NSCache<NSString, MeshNode> = {
    let cache = NSCache<NSString, MeshNode>()
    cache.countLimit = 80
    cache.totalCostLimit = 64_000_000
    return cache
  }()
  private static var surfaceImages: [String: NSImage] = [:]
  static func material(_ object: ProductObject, project: Project) -> MeshMaterial {
    let preset = project.material(object.materialID)
    let result = MeshMaterial()
    result.lightingModel = .physicallyBased
    if ["Wood", "Paper", "Fabric"].contains(preset.category) {
      result.diffuse.contents = surfaceImage(preset.category, color: object.color ?? preset.color)
    } else {
      result.diffuse.contents = NSColor(hex: object.color ?? preset.color)
    }
    result.roughness.contents = preset.roughness
    result.metalness.contents = preset.metallic
    return result
  }
  private static func surfaceImage(_ category: String, color: String) -> NSImage {
    let key = category + color
    if let image = surfaceImages[key] { return image }
    let size = 128
    let base = NSColor(hex: color).usingColorSpace(.sRGB)!
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    let pixels = rep.bitmapData!
    for y in 0..<size {
      for x in 0..<size {
        let noise = Double((x &* 167 + y &* 311 + x &* y &* 13) % 97) / 97 - 0.5
        let grain =
          category == "Wood"
          ? sin(Double(x) * 0.5 + sin(Double(y) * 0.04) * 2) * 0.035 + noise * 0.015
          : category == "Fabric" ? (Double(x % 3 + y % 3) - 2) * 0.012 : noise * 0.022
        let index = y * rep.bytesPerRow + x * 4
        pixels[index] = UInt8(min(255, max(0, (base.redComponent + grain) * 255)))
        pixels[index + 1] = UInt8(min(255, max(0, (base.greenComponent + grain) * 255)))
        pixels[index + 2] = UInt8(min(255, max(0, (base.blueComponent + grain) * 255)))
        pixels[index + 3] = 255
      }
    }
    let image = NSImage(size: .init(width: size, height: size))
    image.addRepresentation(rep)
    if surfaceImages.count >= 80 { surfaceImages.removeAll(keepingCapacity: true) }
    surfaceImages[key] = image
    return image
  }
  static func solid(
    _ geometry: MeshGeometry, _ material: MeshMaterial, at position: MeshVector3 = .init()
  ) -> MeshNode {
    geometry.materials = [material]
    let node = MeshNode(geometry: geometry)
    node.position = position
    node.categoryBitMask = 2
    return node
  }
  static func box(
    _ width: Double, _ height: Double, _ depth: Double, _ material: MeshMaterial, x: Double = 0,
    y: Double = 0, z: Double = 0, corner: Double = 0
  ) -> MeshNode {
    solid(
      MeshBox(
        width: mm(width), height: mm(max(height, 0.1)), length: mm(depth),
        chamferRadius: mm(min(corner, width / 2, height / 2, depth / 2))), material,
      at: v(x / 100, y / 100, z / 100))
  }
  static func object(
    _ sourceObject: ProductObject, project: Project, assets: URL, textureLimit: Int = 2048
  ) -> MeshNode {
    if sourceObject.isFlexibleSurface,let cloth=try? ClothSceneSurface(object:sourceObject,project:project,assets:assets,textureLimit:textureLimit) {return cloth.root}
    var object = sourceObject
    object.artwork = project.surfaceArtwork(sourceObject)
    object.artworkSourceID = nil
    object.artworkFit = nil
    var canonical = object
    let neutral = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    canonical.id = neutral
    canonical.designID = neutral
    canonical.parentIterationID = nil
    canonical.groupID = nil
    canonical.name = ""
    canonical.position = .init()
    canonical.rotation = 0
    canonical.relationship = ""
    canonical.locked = false
    canonical.librarySelection = nil
    canonical.canvasProjectionPositions = nil
    canonical.textile = canonical.textile?.renderDefinition
    canonical.artwork = canonical.artwork.map {artworkDefinition($0,object:object)}
    let artworkData = canonical.artwork.flatMap { try? $0.renderCacheData() }
    canonical.artwork = nil
    canonical.paperConstruction=canonical.paperConstruction.map(PaperGeometry.geometryDefinition)
    canonical.parameters = geometryParameters(object)
    var signature = (try? JSONEncoder.form.encode(canonical)) ?? Data()
    if let artworkData { signature.append(artworkData) }
    if let revision=PaperGeometry.sourceRevision(object,project:project){signature.append(Data(revision.utf8))}
    signature.append((try? JSONEncoder.form.encode(project.material(object.materialID).withoutFabricPattern)) ?? Data())
    if let pattern = try? project.resolvedFabricPattern(materialID: object.materialID) {
      signature.append((try? JSONEncoder.form.encode(pattern.renderDefinition)) ?? Data())
      signature.append(Data("fabric-fonts:\(fontRevision)".utf8))
    }
    if let recipe = project.recipe(object.recipeID) {
      signature.append((try? JSONEncoder.form.encode(recipe)) ?? Data())
    }
    if let materials=project.merchandiseMaterialDependencies(object){signature.append((try? JSONEncoder.form.encode(materials)) ?? Data())}
    if let surface=project.conformedMerchandiseSignature(object){signature.append((try? JSONEncoder.form.encode(surface)) ?? Data())}
    signature.append(Data(assets.path.utf8))
    signature.append(Data("texture-limit:\(textureLimit)".utf8))
    let cacheKey =
      SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined() as NSString
    if let cached = cache.object(forKey: cacheKey) {
      let node = cached.clone()
      if object.recipeID == "clock" { updateClockHands(node, object: object) }
      if object.recipeID == "deskClock" {DeskClockGeometry.updateHands(node,object:object)}
      if PaperConstruction.isPaper(object){try? PaperGeometry.updatePose(node,object:object)}
      return node
    }
    let root = MeshNode()
    let mat = material(object, project: project)
    switch object.recipeID {
    case _ where PaperConstruction.isPaper(object):
      do{root.addChildNode(try PaperGeometry.make(object,project:project,assets:assets,limit:textureLimit))}
      catch{root.name="paper.invalid: "+error.localizedDescription}
    case "crewTee":root.addChildNode(MerchandiseGeometry.tee(object,project:project,assets:assets,limit:textureLimit))
    case "pulloverHoodie", "cuffedBeanie", "hemmedTextile":
      root.addChildNode(StarterTextileGeometry.make(object, project:project, assets:assets, limit:textureLimit))
    case "curvedCap":root.addChildNode(MerchandiseGeometry.cap(object,project:project,assets:assets,limit:textureLimit))
    case "canvasTote":root.addChildNode(MerchandiseGeometry.tote(object,project:project,assets:assets,limit:textureLimit))
    case "textilePrint":root.addChildNode(MerchandiseGeometry.directArtwork(object,project:project,assets:assets,limit:textureLimit))
    case "bomberJacket":
      root.addChildNode(TextileGeometry.bomber(object, project: project, assets: assets, textureLimit: textureLimit))
    case "textilePatch", "textileLabel":
      root.addChildNode(TextileGeometry.decoration(object, project: project, assets: assets, textureLimit: textureLimit))
    case "deskClock":root.addChildNode(DeskClockGeometry.make(object,project:project,assets:assets,limit:textureLimit))
    case "clock":
      let d = object["diameter"]
      let r = d / 2
      let t = object["thickness"]
      let b = object["bore"] / 2
      let profile = NSBezierPath(ovalIn: .init(x: mm(-r), y: mm(-r), width: mm(d), height: mm(d)))
      // Scene units are 100 mm. AppKit's default flatness would reduce a dial to a few edges.
      profile.flatness = mm(0.02)
      profile.windingRule = .evenOdd
      profile.appendOval(in: .init(x: mm(-b), y: mm(-b), width: mm(2 * b), height: mm(2 * b)))
      // A bounded radial mesh keeps the bore and bevels accurate without the
      // excessive cap/chamfer tessellation of an extruded Bezier shape.
      let bevel = min(0.2, t / 4)
      let body = lathe(
        profile: [
          (b + bevel, 0), (r - bevel, 0), (r, bevel), (r, t - bevel),
          (r - bevel, t), (b + bevel, t), (b, t - bevel), (b, bevel),
        ], segments: 256)
      let dial = solid(body, mat)
      dial.name = "clock.dial"
      root.addChildNode(dial)
      if let art = object.artwork {
        let face = MeshShape(path: profile, extrusionDepth: 0.0002)
        let ink = MeshMaterial()
        ink.lightingModel = .physicallyBased
        ink.diffuse.contents = artworkImage(
          art, width: d, depth: d, assets: assets, textureLimit: textureLimit,
          definition: artworkData)
        ink.roughness.contents = 0.9
        let node = solid(face, ink, at: v(0, (t + 0.03) / 100, 0))
        node.eulerAngles.x = -.pi / 2
        node.name = "clock.face"
        root.addChildNode(node)
      }
      func hand(name: String, length: Double, width: Double, y: Double, color: String) {
        let path = NSBezierPath(
          roundedRect: .init(
            x: mm(-width / 2), y: mm(-d * 0.045), width: mm(width), height: mm(length + d * 0.045)),
          xRadius: mm(width / 2), yRadius: mm(width / 2))
        path.flatness = mm(0.02)
        let mesh = MeshShape(path: path, extrusionDepth: mm(0.8))
        let material = MeshMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(hex: color)
        material.roughness.contents = 0.6
        let shape = solid(mesh, material)
        shape.eulerAngles.x = -.pi / 2
        let pivot = MeshNode()
        pivot.name = name
        pivot.position = v(0, y / 100, 0)
        pivot.addChildNode(shape)
        root.addChildNode(pivot)
      }
      hand(name: "clock.hour", length: d * 0.235, width: d * 0.022, y: t + 1.2, color: "#28312D")
      hand(name: "clock.minute", length: d * 0.335, width: d * 0.013, y: t + 2.4, color: "#C96543")
      let brass = MeshMaterial()
      brass.lightingModel = .physicallyBased
      brass.diffuse.contents = NSColor(hex: "#B99363")
      brass.metalness.contents = 0.65
      brass.roughness.contents = 0.4
      let pin = solid(
        MeshCylinder(radius: mm(d * 0.018), height: mm(1.6)), brass, at: v(0, (t + 4) / 100, 0))
      pin.name = "clock.pin"
      root.addChildNode(pin)
      updateClockHands(root, object: object)
    case "lamp":
      let h = object["height"]
      let shadeH = min(object["shadeHeight"], h - 35)
      let base = object["baseDiameter"]
      let stemH = max(20, h - shadeH / 2 - 12)
      let baseGeometry = MeshCylinder(radius: mm(base / 2), height: mm(12))
      baseGeometry.radialSegmentCount = 80
      root.addChildNode(solid(baseGeometry, mat, at: v(0, 0.06, 0)))
      let stem = MeshCylinder(radius: mm(object["stemDiameter"] / 2), height: mm(stemH))
      stem.radialSegmentCount = 32
      root.addChildNode(solid(stem, mat, at: v(0, (stemH / 2 + 12) / 100, 0)))
      let shade = lathe(
        profile: [
          (object["shadeDiameter"] / 2, h - shadeH), (object["topDiameter"] / 2, h),
          (max(object["topDiameter"] / 2 - object["wall"], 1), h),
          (max(object["shadeDiameter"] / 2 - object["wall"], 1), h - shadeH),
        ], segments: 96)
      mat.isDoubleSided = true
      root.addChildNode(solid(shade, mat))
      let bulbMat = MeshMaterial()
      bulbMat.diffuse.contents = NSColor(hex: "#FFF2C8")
      bulbMat.emission.contents = NSColor(hex: "#D5BD81")
      bulbMat.roughness.contents = 1
      let bulb = MeshSphere(radius: mm(24))
      root.addChildNode(solid(bulb, bulbMat, at: v(0, (h - shadeH / 2) / 100, 0)))
    case "paperStack":
      let width = object["width"]
      let depth = object["depth"]
      let count = Int(object["sheets"])
      let thickness = object["thickness"]
      let edge = MeshMaterial()
      edge.diffuse.contents = NSColor(hex: "#C8C6BC")
      edge.roughness.contents = 1
      root.addChildNode(
        box(
          width, Double(count) * thickness, depth, edge, y: Double(count) * thickness / 2,
          corner: 0.15))
      let visible = min(count, 35)
      for i in 0..<visible {
        let y = Double(i) * Double(count) / Double(max(visible, 1)) * thickness
        root.addChildNode(
          box(width + 0.15, thickness * 0.75, depth + 0.15, mat, y: y + thickness / 2, corner: 0.1))
      }
    case "booklet":
      let width = object["width"]
      let depth = object["depth"]
      let h = object["pages"] / 2 * object["thickness"] + 0.8
      let pages = MeshMaterial()
      pages.diffuse.contents = NSColor(hex: "#E6E2D8")
      pages.roughness.contents = 1
      root.addChildNode(box(width - 1, h - 0.6, depth - 1, pages, x: 0.4, y: h / 2, corner: 0.1))
      root.addChildNode(box(width, 0.3, depth, mat, y: 0.15, corner: 0.1))
      root.addChildNode(box(width, 0.3, depth, mat, y: h - 0.15, corner: 0.1))
      root.addChildNode(box(0.8, h, depth, mat, x: -width / 2 + 0.4, y: h / 2))
      if let artwork = object.artwork {
        root.addChildNode(
          artworkPlane(
            artwork, width: width, depth: depth, y: h + 0.03, assets: assets,
            textureLimit: textureLimit, definition: artworkData))
      }
    case "sleeve":
      let width = object["width"]
      let depth = object["depth"]
      let spine = object["height"]
      let stock = object["stock"]
      let tab = object["tab"]
      let angle = object["fold"] / 100 * .pi / 2
      root.addChildNode(box(width, stock, depth, mat, y: stock / 2))
      var parent = root
      var previousWidth = width / 2
      for (i, panelWidth) in [spine, width, spine, tab].enumerated() {
        let hinge = MeshNode()
        hinge.position = v(previousWidth / 100, stock / 200, 0)
        hinge.eulerAngles.z = CGFloat(angle)
        parent.addChildNode(hinge)
        hinge.addChildNode(box(panelWidth, stock, depth, mat, x: panelWidth / 2))
        if i == 1, let artwork = object.artwork {
          let art = artworkPlane(
            artwork, width: panelWidth, depth: depth, y: -stock / 2 - 0.04, assets: assets,
            underside: true, textureLimit: textureLimit, definition: artworkData)
          art.position.x = CGFloat(panelWidth / 200)
          hinge.addChildNode(art)
        }
        parent = hinge
        previousWidth = panelWidth
      }
    case "vase":
      let h = object["height"]
      let radius = object["diameter"] / 2
      let neck = object["neck"] / 2
      let wall = min(object["wall"], neck * 0.8)
      let profile: [(Double, Double)] = [
        (radius * 0.55, 0), (radius * 0.8, h * 0.04), (radius, h * 0.2), (radius * 0.99, h * 0.46),
        (radius * 0.77, h * 0.7), (neck, h * 0.9), (neck, h), (neck - wall, h),
        (neck - wall, h * 0.9), (radius * 0.77 - wall, h * 0.7), (radius * 0.99 - wall, h * 0.46),
        (radius - wall, h * 0.2), (radius * 0.55 - wall, wall), (0, wall), (0, 0),
      ]
      mat.isDoubleSided = true
      root.addChildNode(solid(lathe(profile: profile, segments: 96), mat))
    case "profile":
      let path = NSBezierPath()
      let count = max(3, min(12, Int(object["sides"])))
      for i in 0..<count {
        let a = Double(i) / Double(count) * 2 * .pi
        let point = NSPoint(
          x: mm(object["width"] / 2 * cos(a)), y: mm(object["depth"] / 2 * sin(a)))
        if i == 0 { path.move(to: point) } else { path.line(to: point) }
      }
      path.close()
      let shape = MeshShape(path: path, extrusionDepth: mm(object["height"]))
      shape.chamferRadius = 0.005
      let node = solid(shape, mat)
      node.eulerAngles.x = -.pi / 2
      root.addChildNode(node)
    case "reference", "artboard":
      root.addChildNode(box(object["width"], 0.5, object["depth"], mat, y: 0.25, corner: 0.2))
      if let asset = object.asset, !asset.contains("/"),
        let image = NSImage(contentsOf: assets.appendingPathComponent(asset))
      {
        let surface = MeshMaterial()
        surface.lightingModel = .constant
        surface.diffuse.contents = image
        let plane = MeshPlane(width: mm(object["width"]), height: mm(object["depth"]))
        let node = solid(plane, surface, at: v(0, 0.006, 0))
        node.eulerAngles.x = -.pi / 2
        root.addChildNode(node)
      }
    default:
      if let recipe = project.recipe(object.recipeID) {
        for part in recipe.parts {
          guard let p = try? part.evaluate(object.parameters) else { continue }
          let geo: MeshGeometry
          switch part.kind {
          case "cylinder":
            let c = MeshCylinder(radius: mm(p["radius"] ?? 50), height: mm(p["height"] ?? 100))
            c.radialSegmentCount = 64
            geo = c
          case "cone":
            let c = MeshCone(
              topRadius: mm(p["topRadius"] ?? 0), bottomRadius: mm(p["bottomRadius"] ?? 50),
              height: mm(p["height"] ?? 100))
            c.radialSegmentCount = 64
            geo = c
          case "sphere": geo = MeshSphere(radius: mm(p["radius"] ?? 50))
          case "torus":
            geo = MeshTorus(
              ringRadius: mm(p["ringRadius"] ?? 50), pipeRadius: mm(p["pipeRadius"] ?? 5))
          default:
            let w = p["width"] ?? 100
            let h = p["height"] ?? 100
            let d = p["depth"] ?? 100
            geo = MeshBox(
              width: mm(w), height: mm(h), length: mm(d),
              chamferRadius: mm(min(p["corner"] ?? 1, w / 2, h / 2, d / 2)))
          }
          var partMat = mat
          if let color = part.color {
            partMat = mat.copy() as! MeshMaterial
            partMat.diffuse.contents = NSColor(hex: color)
          }
          let node = solid(
            geo, partMat, at: v((p["x"] ?? 0) / 100, (p["y"] ?? 0) / 100, (p["z"] ?? 0) / 100))
          node.eulerAngles = v(
            (p["rotationX"] ?? 0) * .pi / 180, (p["rotationY"] ?? 0) * .pi / 180,
            (p["rotationZ"] ?? 0) * .pi / 180)
          root.addChildNode(node)
        }
      }
    }
    if let artwork = object.artwork, !PaperConstruction.isPaper(object), !["sleeve", "booklet", "clock", "deskClock", "bomberJacket", "textilePatch", "textileLabel", "crewTee", "curvedCap", "canvasTote", "textilePrint"].contains(object.recipeID),
      object["width"] > 0, object["depth"] > 0
    {
      let top = Double(root.boundingBox.max.y) * 100 + 0.04
      root.addChildNode(
        artworkPlane(
          artwork, width: object["width"], depth: object["depth"], y: top, assets: assets,
          textureLimit: textureLimit, definition: artworkData))
    }
    var imageBytes = 0
    var counted = Set<ObjectIdentifier>()
    func countImages(_ node: MeshNode) {
      for material in node.geometry?.materials ?? [] {
        for property in [material.diffuse,material.normal] {
        if let image = property.contents as? NSImage,
          counted.insert(ObjectIdentifier(image)).inserted
        {
          let pixels =
            image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max()
            ?? Int(image.size.width * image.size.height)
          // Account for the bitmap and a corresponding GPU texture.
          imageBytes += pixels * 8
        }
        }
      }
    }
    countImages(root)
    root.enumerateChildNodes { node, _ in countImages(node) }
    cache.setObject(root.clone(), forKey: cacheKey, cost: max(30_000, imageBytes))
    return root
  }
  static func artworkPlane(
    _ artwork: Artwork, width: Double, depth: Double, y: Double, assets: URL,
    underside: Bool = false, textureLimit: Int = 2048, definition: Data? = nil
  ) -> MeshNode {
    let material = MeshMaterial()
    material.lightingModel = .physicallyBased
    material.diffuse.contents = artworkImage(
      artwork, width: width, depth: depth, assets: assets, textureLimit: textureLimit,
      definition: definition)
    material.roughness.contents = 0.88
    material.isDoubleSided = true
    if underside {
      var transform = MeshMatrix4Identity
      transform.m11 = -1
      transform.m22 = -1
      transform.m41 = 1
      transform.m42 = 1
      material.diffuse.contentsTransform = transform
    }
    let plane = MeshPlane(width: mm(width), height: mm(depth))
    let node = solid(plane, material, at: v(0, y / 100, 0))
    node.eulerAngles.x = underside ? .pi / 2 : -.pi / 2
    return node
  }
  static func updateClockHands(_ root: MeshNode, object: ProductObject) {
    root.childNode(withName: "clock.hour", recursively: true)?.eulerAngles.y = CGFloat(
      -(object["hour"] + object["minute"] / 60) * .pi / 6)
    root.childNode(withName: "clock.minute", recursively: true)?.eulerAngles.y = CGFloat(
      -object["minute"] * .pi / 30)
    for name in ["clock.hour", "clock.minute", "clock.pin"] {
      root.childNode(withName: name, recursively: true)?.isHidden = object["hands"] < 0.5
    }
  }
  private static let artworkImages: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.totalCostLimit = 16_000_000
    cache.countLimit = 24
    return cache
  }()
  static func artworkImage(
    _ art: Artwork, width: Double, depth: Double, assets: URL, textureLimit: Int,
    definition: Data? = nil
  ) -> NSImage {
    var signature = definition ?? (try? art.renderCacheData()) ?? Data()
    signature.append(Data("\(width),\(depth),\(textureLimit),\(fontRevision),\(assets.path)".utf8))
    let key = SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined() as NSString
    if let image = artworkImages.object(forKey: key) { return image }
    let image = ArtworkDrawing.image(
      art, width: width, height: depth, assets: assets,
      pixelsPerMM: min(max(5, 1024 / max(width, depth)), Double(textureLimit) / max(width, depth)))
    let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 1
    artworkImages.setObject(image, forKey: key, cost: pixels * 8)
    return image
  }
  static func lathe(profile: [(Double, Double)], segments: Int) -> MeshGeometry {
    var profile = profile
    if let first = profile.first, let last = profile.last, first.0 != last.0 || first.1 != last.1 {
      profile.append(first)
    }
    var positions: [MeshVector3] = []
    var normals: [MeshVector3] = []
    var coordinates: [CGPoint] = []
    var indices: [Int32] = []
    let perimeter = zip(profile, profile.dropFirst()).reduce(0.0) {
      $0 + hypot($1.1.0 - $1.0.0, $1.1.1 - $1.0.1)
    }
    var travel = 0.0
    for (j, point) in profile.enumerated() {
      let before = profile[max(0, j - 1)]
      let after = profile[min(profile.count - 1, j + 1)]
      if j > 0 { travel += hypot(point.0 - before.0, point.1 - before.1) }
      let dr = after.0 - before.0
      let dy = after.1 - before.1
      let length = max(hypot(dr, dy), 0.0001)
      for i in 0...segments {
        let angle = Double(i) / Double(segments) * 2 * .pi
        positions.append(v(point.0 * cos(angle) / 100, point.1 / 100, point.0 * sin(angle) / 100))
        normals.append(v(dy / length * cos(angle), -dr / length, dy / length * sin(angle)))
        coordinates.append(
          .init(x: Double(i) / Double(segments), y: travel / max(perimeter, 0.001)))
        if j < profile.count - 1 && i < segments {
          let a = Int32(j * (segments + 1) + i)
          let b = a + Int32(segments + 1)
          indices += [a, b, a + 1, a + 1, b, b + 1]
        }
      }
    }
    return MeshGeometry(
      sources: [
        MeshGeometrySource(vertices: positions), MeshGeometrySource(normals: normals),
        MeshGeometrySource(textureCoordinates: coordinates),
      ],
      elements: [MeshGeometryElement(indices: indices, primitiveType: .triangles)])
  }
}

import FormCore
import Foundation

extension FigmaSceneBuilder {
  static let resources: Set<String> = ["DOCUMENT", "CANVAS", "VARIABLE", "VARIABLE_SET", "VARIABLE_COLLECTION", "STYLE", "STYLE_SET", "INTERNAL_ONLY_NODE"]
  func parent(_ node: FigmaValue) -> String? { FigmaArtworkImporter.sourceID(node["parentIndex"]?["guid"]) }
  func visibleSource(_ id: String) -> Bool {
    var next: String? = id, seen = Set<String>()
    while let key = next, let node = nodes[key], seen.insert(key).inserted {
      if node["internalOnly"]?.boolValue == true { return false }; next = parent(node)
    }
    return true
  }
  func build() throws -> FigmaArtworkImportResult {
    guard let values = document.message["nodeChanges"]?.arrayValue, !values.isEmpty,
      values.count <= maximumElements else { throw FigmaClipboardError.limit("1–5,000 scene records") }
    let assetType = document.message["pasteAssetType"]?.stringValue ?? "UNKNOWN"
    guard assetType == "UNKNOWN" else { throw FigmaClipboardError.unsupported("This clipboard contains \(assetType.lowercased()) rather than artwork.") }
    for (index, value) in values.enumerated() {
      try Task.checkCancellation()
      guard let id = FigmaArtworkImporter.sourceID(value["guid"]), nodes[id] == nil else {
        throw FigmaClipboardError.invalid("Scene nodes need unique source identities.")
      }
      if value["phase"]?.stringValue == "REMOVED" { continue }
      nodes[id] = value; order[id] = index
      if let parent = parent(value) { children[parent, default: []].append(id) }
    }
    for id in nodes.keys {
      var seen = Set<String>(), next: String? = id
      while let current = next, let node = nodes[current] {
        guard seen.insert(current).inserted else { throw FigmaClipboardError.invalid("Cyclic scene hierarchy.") }
        guard seen.count <= 64 else { throw FigmaClipboardError.limit("64 scene hierarchy levels") }; next = parent(node)
      }
    }
    for key in children.keys { children[key] = sorted(children[key]!) }
    if let documentNode=values.first(where:{$0["type"]?.stringValue=="DOCUMENT"}) {
      let declared=documentNode["documentColorProfile"] ?? documentNode["colorProfile"]
      if let name=declared?.stringValue,["SRGB","DISPLAY_P3"].contains(name) {documentColorProfile=name}
      else if declared == nil || declared?.stringValue == "LEGACY" {
        issue("document","color-profile","No explicit modern source color profile was supplied; legacy colors are interpreted as sRGB.",severity:"info")
      } else {issue("document","color-profile","The declared source color profile is unsupported.",severity:"error")}
    }
    let roots = sorted(nodes.keys.filter { id in
      guard let node = nodes[id], !Self.resources.contains(node["type"]?.stringValue ?? ""), visibleSource(id) else { return false }
      guard let parent = parent(node), let ancestor = nodes[parent] else { return true }
      return Self.resources.contains(ancestor["type"]?.stringValue ?? "")
    })
    guard !roots.isEmpty else { throw FigmaClipboardError.unsupported("No visible artwork roots are included in this clipboard.") }
    var selected = Set<UUID>()
    for id in roots { selected.insert(try emit(id, parentID: nil, depth: 0)) }
    var art = Artwork(background: "#FFFFFF", elements: elements, bleed: 0); art.backgroundOpacity = 0; art.unit = .mm
    try validateArtwork(art)
    let rootElements = art.elements.filter { selected.contains($0.id) }
    let boxes = rootElements.map { art.bounds(of: $0) }
    let bounds = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
    return .init(artwork: art, assets: assets, selectedRootIDs: selected, issues: issues,
      sourceNodeIDs: sourceIDs, components: components, bounds: bounds)
  }
  func sorted<S: Sequence>(_ ids: S) -> [String] where S.Element == String {
    ids.sorted {
      let a = nodes[$0]?["parentIndex"]?["position"]?.stringValue ?? "", b = nodes[$1]?["parentIndex"]?["position"]?.stringValue ?? ""
      return a == b ? (order[$0] ?? 0) < (order[$1] ?? 0) : a < b
    }
  }
  func metadata(_ node: FigmaValue, id: String) throws -> ArtworkSourceMetadata {
    let bytes = try node.encodedJSON()
    guard bytes.count <= 256*1024, sourceBytes <= 8*1024*1024-bytes.count else { throw FigmaClipboardError.limit("per-layer source metadata") }
    sourceBytes += bytes.count
    return .init(format: "figma", nodeID: id, properties: bytes, version: String(document.version))
  }
  func merged(_ base: FigmaValue, _ overlay: FigmaValue) -> FigmaValue {
    var result = base.objectValue ?? [:]
    for (key,value) in overlay.objectValue ?? [:] { result[key] = value }
    return .object(result)
  }

  @discardableResult func emit(_ id: String, parentID: UUID?, depth: Int,
    override: FigmaValue? = nil, occurrence: String? = nil, overrides: [String: FigmaValue] = [:],
    definition: Bool = false) throws -> UUID {
    try Task.checkCancellation()
    guard depth <= 64, let original = nodes[id] else { throw FigmaClipboardError.invalid("Missing or excessive scene hierarchy.") }
    var node = override.map { merged(original,$0) } ?? original
    if let value = overrides[id] { node = merged(node,value) }
    if materializedKeys[id] == nil, try instanceNeedsExpansion(node,id:id) {
      let key=occurrence.map{$0+"/"+id} ?? id
      return try emit(materializeInstance(id,key:key),parentID:parentID,depth:depth)
    }
    let previousProfile=currentColorProfile
    if node["colorProfile"] != nil,node["colorProfile"]?.stringValue == nil {
      issue(id,"color-profile","Unknown numeric source color profile.",severity:"error")
    }
    var inheritedProfile:String?=node["colorProfile"]?.stringValue
    var ancestor=parent(node)
    while inheritedProfile==nil,let a=ancestor,let record=nodes[a] {inheritedProfile=record["colorProfile"]?.stringValue;ancestor=parent(record)}
    currentColorProfile=inheritedProfile ?? documentColorProfile
    defer {currentColorProfile=previousProfile}
    let type = node["type"]?.stringValue ?? "UNKNOWN", key = materializedKeys[id] ?? occurrence.map { $0 + "/" + id } ?? id
    let width = try number(node["size"]?["x"], 1)*scale, height = try number(node["size"]?["y"], 1)*scale
    guard width >= 0, height >= 0, width <= 10000, height <= 10000 else { throw FigmaClipboardError.invalid("Invalid source node dimensions.") }
    let w = max(width,0.001), h = max(height,0.001)
    let nativeID = UUID(); sourceIDs[key] = nativeID
    var root = ArtworkElement(kind:"group",x:0,y:0,width:w,height:h)
    root.id = nativeID; root.parentID = parentID; root.name = String((node["name"]?.stringValue ?? type.capitalized).prefix(500))
    root.contentSize = .init(w,h); root.affine = definition ? .init() : try matrix(node["transform"], translationScale: scale)
    root.opacity = try number(node["opacity"],1); root.hidden = node["visible"]?.boolValue == false
    root.locked = node["locked"]?.boolValue == true; root.blendMode = blend(node["blendMode"],id:key)
    root.isolatedBlending = node["blendMode"]?.stringValue != "PASS_THROUGH" && node["blendMode"] != nil
    root.sourceMetadata = try metadata(materializedSources[id] ?? node,id:key)
    try effects(node,on:&root,id:key)
    if definition {
      // A component definition owns geometry. Its referencing instance owns
      // root compositing, including inherited opacity/effects, exactly once.
      root.opacity=1;root.blur=nil;root.shadow=nil;root.effectStack=nil;root.blendMode=nil;root.isolatedBlending=false
    }
    if let stack = node["stackMode"]?.stringValue, stack != "NONE" {
      issue(key,"layout","Current layout positions remain editable; auto-layout constraints are retained as source metadata.",severity:"info")
    }
    if node["componentPropDefs"] != nil || node["componentPropAssignments"] != nil {
      issue(key,"component-properties","Resolved component properties are retained; variant switching is not a native behavior.",severity:"info")
    }
    if (type == "INSTANCE" || type == "SYMBOL") && !definition {
      let source = type == "SYMBOL" ? id : FigmaArtworkImporter.sourceID(node["symbolData"]?["symbolID"])
      if let source, nodes[source] != nil {
        let sourceNode=nodes[source]!
        if node["opacity"]==nil {root.opacity=try number(sourceNode["opacity"],1)}
        if node["blendMode"]==nil {
          root.blendMode=blend(sourceNode["blendMode"],id:key)
          root.isolatedBlending=sourceNode["blendMode"]?.stringValue != "PASS_THROUGH" && sourceNode["blendMode"] != nil
        }
        if node["effects"]==nil {try effects(sourceNode,on:&root,id:key)}
        let componentID = try component(source)
        root.component = .init(sourceObjectID:componentID)
        root.contentSize = components.first { $0.id == componentID }!.size
        try append(root); return nativeID
      }
      if type == "INSTANCE" { issue(key,"component","The instance's source definition is absent from the clipboard.",severity:"error") }
    }
    let container = ["FRAME","GROUP","SECTION","SYMBOL","INSTANCE","BOOLEAN_OPERATION"].contains(type)
    if container {
      if type == "BOOLEAN_OPERATION" {
        let operations=["UNION":"union","SUBTRACT":"subtract","INTERSECT":"intersect","XOR":"exclude","EXCLUDE":"exclude"]
        guard node["booleanOperation"] == nil || node["booleanOperation"]?.stringValue.flatMap({operations[$0]}) != nil else {
          throw FigmaClipboardError.unsupported("Unknown native boolean operation.")
        }
        root.booleanOperation=operations[node["booleanOperation"]?.stringValue ?? "UNION"]
        var paintNode=node.objectValue ?? [:]
        if paintNode["fillPaints"]==nil {paintNode["fillPaints"] = .array([])}
        root.paintStack=try textPaintStack(.object(paintNode),width:w,height:h,id:key)
        root.fillEnabled=false;root.gradient=nil;root.fillOpacity=nil
        if node["borderStrokeWeightsIndependent"]?.boolValue == true {
          issue(key,"stroke","Independent side strokes require explicit geometry on a boolean result.",severity:"error")
        }
        try append(root); try emitChildren(id,parentID:nativeID,depth:depth+1,occurrence:occurrence,overrides:overrides)
      } else {
        try append(root)
        try emitContainerContents(node,sourceID:id,root:root,depth:depth,occurrence:occurrence,overrides:overrides,ownSize:.init(w,h))
      }
      return nativeID
    }
    let visuals = try visuals(node,id:key,width:w,height:h)
    if visuals.count == 1, var leaf = visuals.first, leaf.blendMode == nil || leaf.blendMode == "normal" {
      leaf.id=nativeID;leaf.parentID=parentID;leaf.name=root.name;leaf.affine=root.affine
      leaf.opacity=(leaf.opacity ?? 1)*(root.opacity ?? 1);leaf.hidden=root.hidden;leaf.locked=root.locked
      leaf.blendMode=root.blendMode ?? leaf.blendMode;leaf.blur=root.blur;leaf.shadow=root.shadow;leaf.effectStack=root.effectStack;leaf.sourceMetadata=root.sourceMetadata
      leaf.isolatedBlending=root.isolatedBlending
      try append(leaf)
    } else {
      try append(root)
      for var leaf in visuals { leaf.parentID=nativeID; try append(leaf) }
      if visuals.count > 1 { issue(key,"paint-stack","Separate paints remain ordered editable sublayers.",severity:"info") }
    }
    return nativeID
  }

  func component(_ source: String) throws -> UUID {
    if let existing = componentIDs[source] { return existing }
    guard buildingComponents.count < 8, buildingComponents.insert(source).inserted,
      components.count < 64, let node=nodes[source] else { throw FigmaClipboardError.invalid("Cyclic, missing or excessive component definition.") }
    defer { buildingComponents.remove(source) }
    let savedElements=elements,savedIDs=sourceIDs
    elements=[];sourceIDs=[:]
    do {
      try emit(source,parentID:nil,depth:0,definition:true)
      var art=Artwork(background:"#FFFFFF",elements:elements,bleed:0);art.backgroundOpacity=0
      try validateArtwork(art)
      let componentID=UUID(),size=Point2(max(0.01,try number(node["size"]?["x"],1)*scale),max(0.01,try number(node["size"]?["y"],1)*scale))
      components.append(.init(id:componentID,name:String((node["name"]?.stringValue ?? "Imported component").prefix(500)),size:size,artwork:art))
      componentIDs[source]=componentID;componentMaps[source]=sourceIDs
      elements=savedElements;sourceIDs=savedIDs
      return componentID
    } catch { elements=savedElements;sourceIDs=savedIDs;throw error }
  }

  func emitChildren(_ source: String,parentID:UUID,depth:Int,occurrence:String?,overrides:[String:FigmaValue]) throws {
    var masks:[(UUID,String)]=[],contentID:UUID?
    let parentSize=elements.first{$0.id==parentID}?.paintSize ?? .init(1,1)
    func group(_ name:String) -> ArtworkElement {
      var value=ArtworkElement(kind:"group",x:0,y:0,width:parentSize.x,height:parentSize.y)
      value.name=name;value.parentID=parentID;value.contentSize=parentSize;return value
    }
    func beginContent() throws -> UUID {
      var maskID=masks[0].0,mode=masks[0].1
      if masks.count>1 {
        let coverage=group("Mask coverage");try append(coverage)
        for (id,kind) in masks {
          guard let index=elements.firstIndex(where:{$0.id==id}) else {continue}
          elements[index].parentID=coverage.id
          let mask=elements[index],snapshot=Artwork(elements:elements),bounds=snapshot.maskCoverageBounds(of:mask)
          var carrier=ArtworkElement(kind:"rectangle",x:bounds.x,y:bounds.y,width:max(0.001,bounds.width),height:max(0.001,bounds.height),color:"#FFFFFF")
          carrier.name="Mask coverage ink";carrier.parentID=coverage.id;carrier.clipID=id;carrier.clipMode=kind
          try append(carrier)
        }
        maskID=coverage.id;mode="alpha"
      }
      var content=group("Masked contents");content.clipID=maskID;content.clipMode=mode
      try append(content);return content.id
    }
    for child in children[source] ?? [] {
      try Task.checkCancellation()
      guard let node=nodes[child],node["internalOnly"]?.boolValue != true else {continue}
      if node["mask"]?.boolValue == true,node["visible"]?.boolValue == false {
        try emit(child,parentID:contentID ?? parentID,depth:depth,occurrence:occurrence,overrides:overrides);continue
      }
      let isMask=node["mask"]?.boolValue == true
      if isMask {
        if contentID != nil {masks=[];contentID=nil}
        let native=try emit(child,parentID:parentID,depth:depth,occurrence:occurrence,overrides:overrides)
        let raw=node["maskType"],outline=node["maskIsOutline"]?.boolValue == true || raw?.stringValue == "OUTLINE"
        let kind=raw?.stringValue == "LUMINANCE" && !outline ? "luminance-alpha":"alpha"
        if !outline,raw != nil,raw?.stringValue.map({!["ALPHA","LUMINANCE"].contains($0)}) ?? true {
          issue(child,"mask","Unknown mask coverage mode.",severity:"error")
        }
        if outline,let index=elements.firstIndex(where:{$0.id==native}) {
          let element=elements[index]
          guard ["rectangle","ellipse","path","polygon","star","line"].contains(element.kind) else {
            throw FigmaClipboardError.unsupported("A vector mask requires editable fill/stroke coverage; this mask is a group, image or text layer.")
          }
          // Figma vector masks use visible fill AND stroke regions. Preserve
          // their editable coverage, make nonzero ink opaque, and keep authored
          // node opacity/effects outside it. A stroke-only mask stays a ring.
          if var opaque=EffectSilhouetteRenderer.element(element,knockout:false) {
            opaque.opacity=element.opacity;opaque.blur=element.blur;opaque.shadow=element.shadow
            opaque.effectStack=element.effectStack;opaque.isolatedBlending=element.isolatedBlending
            elements[index]=opaque
          }
        }
        masks.append((native,kind))
      } else {
        if !masks.isEmpty,contentID == nil {contentID=try beginContent()}
        try emit(child,parentID:contentID ?? parentID,depth:depth,occurrence:occurrence,overrides:overrides)
      }
    }
    // A trailing mask has no painted content. Keep its source editable without
    // displaying the mask itself as an ordinary visible shape.
    if contentID == nil {for (id,_) in masks {if let index=elements.firstIndex(where:{$0.id==id}) {elements[index].hidden=true}}}
  }
  func emitContainerContents(_ node:FigmaValue,sourceID:String,root:ArtworkElement,depth:Int,
    occurrence:String?,overrides:[String:FigmaValue],ownSize:Point2) throws {
    var background=node.objectValue ?? [:];background["type"] = .string("RECTANGLE")
    background["strokePaints"] = .array([])
    if background["fillPaints"] == nil {background["fillPaints"]=background["backgroundPaints"]}
    if background["fillPaints"] == nil,let color=background["backgroundColor"] {
      background["fillPaints"] = .array([.object(["type":.string("SOLID"),"color":color,"opacity":background["backgroundOpacity"] ?? .double(1)])])
    }
    if (background["fillPaints"]?.arrayValue ?? []).contains(where:{$0["visible"]?.boolValue != false}) {
      for var shape in try visuals(.object(background),id:sourceID,width:ownSize.x,height:ownSize.y) {
        shape.parentID=root.id;shape.name="Frame background";try append(shape)
      }
    }
    var contentParent=root.id
    if node["frameMaskDisabled"]?.boolValue == false && node["resizeToFit"]?.boolValue != true {
      var mask=try baseShapes(.object(background),id:sourceID,width:ownSize.x,height:ownSize.y).first ?? ArtworkElement(kind:"rectangle",x:0,y:0,width:ownSize.x,height:ownSize.y)
      mask.id=UUID();mask.parentID=root.id;mask.hidden=true;mask.name="Frame clipping boundary";try append(mask)
      var content=ArtworkElement(kind:"group",x:0,y:0,width:ownSize.x,height:ownSize.y)
      content.name="Frame contents";content.contentSize=ownSize;content.parentID=root.id;content.clipID=mask.id;try append(content);contentParent=content.id
    }
    try emitChildren(sourceID,parentID:contentParent,depth:depth+1,occurrence:occurrence,overrides:overrides)
    let strokePaints=node["strokePaints"]?.arrayValue ?? []
    if !strokePaints.isEmpty {
      let geometry=try baseShapes(.object(background),id:sourceID,width:ownSize.x,height:ownSize.y)[0]
      for var shape in try stroke(strokePaints,node:node,geometry:geometry,id:sourceID) {shape.parentID=root.id;shape.name="Frame stroke";try append(shape)}
    }
  }
}

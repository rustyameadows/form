import FormCore
import Foundation

/// An occurrence owns its properties. Two instances of the same component never
/// share a mutable node, even when their source GUIDs and override keys match.
private final class FigmaOccurrence {
  let sourceID: String
  let original: FigmaValue
  var properties: FigmaValue
  var children: [FigmaOccurrence] = []
  var componentID: String?
  var componentKeys = Set<String>()
  var key: String
  var geometryScale = Point2(1, 1)
  var inheritedBindings: [String:FigmaValue] = [:]
  var boundaryIndex: [String:[FigmaOccurrence]]?
  init(sourceID: String, original: FigmaValue, properties: FigmaValue, key: String) {
    self.sourceID=sourceID;self.original=original;self.properties=properties;self.key=key
  }
}

extension FigmaSceneBuilder {
  private func spendOccurrenceWork(_ amount:Int=1) throws {
    guard amount>=0,amount<=1_000_000-occurrenceWork else {throw FigmaClipboardError.limit("instance resolution work")}
    occurrenceWork += amount
    try Task.checkCancellation()
  }
  func instanceNeedsExpansion(_ node: FigmaValue, id: String) throws -> Bool {
    guard node["type"]?.stringValue == "INSTANCE",
      let component=FigmaArtworkImporter.sourceID(node["symbolData"]?["symbolID"]),let source=nodes[component] else { return false }
    if !(children[id] ?? []).isEmpty || !(node["symbolData"]?["symbolOverrides"]?.arrayValue ?? []).isEmpty
      || !(node["derivedSymbolData"]?.arrayValue ?? []).isEmpty || !(node["componentPropAssignments"]?.arrayValue ?? []).isEmpty { return true }
    let ownAppearance=["fillPaints","strokePaints","cornerRadius","rectangleCornerRadiiIndependent","frameMaskDisabled",
      "borderStrokeWeightsIndependent","strokeWeight","rectangleTopLeftCornerRadius","rectangleTopRightCornerRadius",
      "rectangleBottomLeftCornerRadius","rectangleBottomRightCornerRadius"]
    if ownAppearance.contains(where:{node[$0] != nil && node[$0] != source[$0]}) { return true }
    let factor=try number(node["symbolData"]?["uniformScaleFactor"],1)
    guard factor>0 else {throw FigmaClipboardError.invalid("Instance uniform scale must be positive.")}
    let sourceSize=try occurrenceSize(source),size=try occurrenceSize(node)
    // A resize uses the component's constraints. Only a saved uniform scale can
    // be represented by the existing native component frame scale directly.
    return abs(size.x-sourceSize.x*factor)>0.0001 || abs(size.y-sourceSize.y*factor)>0.0001
  }

  func materializeInstance(_ id:String,key:String) throws -> String {
    var expanding=Set<String>(),count=0
    let root=try expandOccurrence(id,key:key,bindings:[:],expanding:&expanding,count:&count,depth:0)
    func install(_ occurrence:FigmaOccurrence,parent:String?,depth:Int) throws -> String {
      try Task.checkCancellation()
      guard depth<=64 else {throw FigmaClipboardError.limit("64 instance occurrence levels")}
      let synthetic="figma-occurrence-"+UUID().uuidString
      var fields=occurrence.properties.objectValue ?? [:]
      fields["guid"] = .string(synthetic)
      if occurrence.componentID != nil || fields["type"]?.stringValue == "SYMBOL" {
        fields["type"] = .string("FRAME");fields["symbolData"]=nil;fields["derivedSymbolData"]=nil
      }
      fields["internalOnly"]=nil
      if let parent {fields["parentIndex"] = .object(["guid":.string(parent)])}
      nodes[synthetic] = .object(fields)
      materializedKeys[synthetic]=occurrence.key;materializedSources[synthetic]=occurrence.original
      materializedGeometryScale[synthetic]=occurrence.geometryScale;materializedGeometryScale[occurrence.key]=occurrence.geometryScale
      var childIDs:[String]=[]
      for child in occurrence.children {childIDs.append(try install(child,parent:synthetic,depth:depth+1))}
      children[synthetic]=childIDs
      return synthetic
    }
    let result=try install(root,parent:parent(nodes[id]!),depth:0)
    issue(key,"component","This instance's resolved overrides remain editable layers; original component data is retained.",severity:"info")
    return result
  }

  private func occurrenceSize(_ value:FigmaValue) throws -> Point2 {
    .init(try number(value["size"]?["x"],1),try number(value["size"]?["y"],1))
  }
  private func setOccurrence(_ target:FigmaOccurrence,_ fields:[String:FigmaValue]) {
    target.properties=merged(target.properties,.object(fields))
  }
  private func mergingAssignments(_ inner:[FigmaValue],_ outer:[FigmaValue]) throws -> [FigmaValue] {
    guard inner.count<=10_000,outer.count<=10_000 else {throw FigmaClipboardError.limit("10,000 component property assignments")}
    try spendOccurrenceWork(inner.count+outer.count)
    var result=inner,indices:[String:Int]=[:]
    for (index,value) in inner.enumerated() {if let id=FigmaArtworkImporter.sourceID(value["defID"]) {indices[id]=index}}
    for assignment in outer {
      if let id=FigmaArtworkImporter.sourceID(assignment["defID"]) {
        if let index=indices[id] {result[index]=assignment}
        else {indices[id]=result.count;result.append(assignment)}
      } else {result.append(assignment)}
    }
    return result
  }
  private func occurrenceBindings(_ source:FigmaValue,assignments:[FigmaValue]) throws -> [String:FigmaValue] {
    var values:[String:FigmaValue]=[:]
    for definition in source["componentPropDefs"]?.arrayValue ?? [] {
      try spendOccurrenceWork()
      if let id=FigmaArtworkImporter.sourceID(definition["id"]),definition["isDeleted"]?.boolValue != true {
        values[id]=definition["varValue"]?["value"] ?? definition["initialValue"]
      }
    }
    for assignment in assignments {
      try spendOccurrenceWork()
      if let id=FigmaArtworkImporter.sourceID(assignment["defID"]) {
        values[id]=assignment["varValue"]?["value"] ?? assignment["value"]
      }
    }
    return values
  }
  private func boundOccurrence(_ raw:FigmaValue,bindings:[String:FigmaValue],id:String) throws -> FigmaValue {
    var fields=raw.objectValue ?? [:]
    for ref in raw["componentPropRefs"]?.arrayValue ?? [] where ref["isDeleted"]?.boolValue != true {
      try spendOccurrenceWork()
      guard let key=FigmaArtworkImporter.sourceID(ref["defID"]),let value=bindings[key] else {continue}
      let field=ref["componentPropNodeField"]?.stringValue
      switch field {
      case "VISIBLE": if let v=value["boolValue"] {fields["visible"]=v}
      case "TEXT_DATA":
        if let text=value["textValue"] {fields["textData"]=text;fields["derivedTextData"]=nil}
        else if let text=value["stringValue"] {fields["textData"] = .object(["characters":text]);fields["derivedTextData"]=nil}
      case "OVERRIDDEN_SYMBOL_ID":
        if let guid=value["guidValue"] {var symbol=fields["symbolData"]?.objectValue ?? [:];symbol["symbolID"]=guid;fields["symbolData"] = .object(symbol)}
      case "SLOT_CONTENT_ID": if let guid=value["guidValue"] {fields["slotContent"]=guid}
      case "INHERIT_FILL_STYLE_ID":
        issue(id,"component-properties","A component paint-style binding requires resolved paint data.",severity:fields["fillPaints"] == nil ? "error":"info")
      default: issue(id,"component-properties","An unknown component property binding cannot be resolved.",severity:"error")
      }
    }
    return .object(fields)
  }

  private func expandOccurrence(_ id:String,key:String,bindings:[String:FigmaValue],
    expanding:inout Set<String>,count:inout Int,depth:Int,overlay:FigmaValue?=nil) throws -> FigmaOccurrence {
    try Task.checkCancellation()
    guard depth<=64,count<maximumElements,let original=nodes[id] else {throw FigmaClipboardError.limit("5,000 instance occurrence nodes or 64 levels")}
    guard expanding.insert(id).inserted else {throw FigmaClipboardError.invalid("Cyclic component occurrence.")}
    defer {expanding.remove(id)}
    count+=1
    try spendOccurrenceWork()
    let claimCount=original["symbolData"]?["symbolOverrides"]?.arrayValue?.count ?? 0
    let derivedCount=original["derivedSymbolData"]?.arrayValue?.count ?? 0
    guard claimCount<=10_000,derivedCount<=10_000 else {throw FigmaClipboardError.limit("10,000 instance claims")}
    let bound=try boundOccurrence(original,bindings:bindings,id:key)
    var raw=overlay.map{merged(bound,$0)} ?? bound
    // A root swap selects the definition before expansion; consuming its swap
    // field avoids recursively applying the same structural decision forever.
    if let initial=FigmaArtworkImporter.sourceID(raw["symbolData"]?["symbolID"]) {
      var symbol=raw["symbolData"]?.objectValue ?? [:]
      var aliases:Set<String>=[id,initial,FigmaArtworkImporter.sourceID(nodes[initial]?["overrideKey"]) ?? initial]
      var assignments=raw["componentPropAssignments"]?.arrayValue ?? []
      var claims:[FigmaValue]=[]
      for claim in symbol["symbolOverrides"]?.arrayValue ?? [] {
        try spendOccurrenceWork()
        let path=claim["guidPath"]?["guids"]?.arrayValue ?? []
        if path.isEmpty || (path.count==1 && FigmaArtworkImporter.sourceID(path[0]).map{aliases.contains($0)} == true) {
          var fields=claim.objectValue ?? [:]
          if let replacement=claim["symbolData"]?["symbolID"] {
            symbol["symbolID"]=replacement;fields["symbolData"]=nil
            if let replacementID=FigmaArtworkImporter.sourceID(replacement) {
              aliases.insert(replacementID)
              if let key=FigmaArtworkImporter.sourceID(nodes[replacementID]?["overrideKey"]) {aliases.insert(key)}
            }
          }
          if let values=claim["componentPropAssignments"]?.arrayValue {
            assignments=try mergingAssignments(assignments,values);fields["componentPropAssignments"]=nil
          }
          claims.append(.object(fields))
        } else {claims.append(claim)}
      }
      symbol["symbolOverrides"] = .array(claims)
      raw=merged(raw,.object(["symbolData":.object(symbol),"componentPropAssignments":.array(assignments)]))
    }
    let type=raw["type"]?.stringValue ?? "UNKNOWN"
    let sourceID=type == "INSTANCE" ? FigmaArtworkImporter.sourceID(raw["symbolData"]?["symbolID"]) : nil
    var properties=raw,source=raw,sourceChildren=id
    let actualChildren = !(children[id] ?? []).isEmpty
    if let sourceID {
      guard let definition=nodes[sourceID] else {throw FigmaClipboardError.invalid("An instance component definition is missing.")}
      guard !expanding.contains(sourceID) else {throw FigmaClipboardError.invalid("Cyclic component occurrence.")}
      source=definition
      var inherited=definition.objectValue ?? [:]
      for field in ["guid","parentIndex","transform","internalOnly","componentKey","sourceLibraryKey","publishID","publishedVersion","sharedSymbolVersion","isSymbolPublishable","variantPropSpecs","componentPropDefs","overrideKey"] {inherited[field]=nil}
      properties=merged(.object(inherited),raw)
      sourceChildren=actualChildren ? id:sourceID
    }
    let occurrence=FigmaOccurrence(sourceID:id,original:original,properties:properties,key:key)
    occurrence.componentID=sourceID;occurrence.inheritedBindings=bindings
    if let originalComponent=FigmaArtworkImporter.sourceID(original["symbolData"]?["symbolID"]) {
      occurrence.componentKeys.insert(originalComponent)
      if let alias=FigmaArtworkImporter.sourceID(nodes[originalComponent]?["overrideKey"]) {occurrence.componentKeys.insert(alias)}
    }
    if let sourceID {
      occurrence.componentKeys.insert(sourceID)
      if let key=FigmaArtworkImporter.sourceID(source["overrideKey"]) {occurrence.componentKeys.insert(key)}
    }
    let ownAssignments=raw["componentPropAssignments"]?.arrayValue ?? []
    let scoped=(type == "SYMBOL" || sourceID != nil) ? try occurrenceBindings(source,assignments:ownAssignments):bindings
    if let slot=FigmaArtworkImporter.sourceID(raw["slotContent"]) {
      guard nodes[slot] != nil else {throw FigmaClipboardError.invalid("A component slot's content is missing.")};sourceChildren=slot
    }
    for child in children[sourceChildren] ?? [] {
      guard nodes[child]?["internalOnly"]?.boolValue != true else {continue}
      let childKey=(sourceID != nil && !actualChildren) || key != id ? key+"/"+child:child
      occurrence.children.append(try expandOccurrence(child,key:childKey,bindings:scoped,expanding:&expanding,count:&count,depth:depth+1))
    }
    let overrides=raw["symbolData"]?["symbolOverrides"]?.arrayValue ?? []
    // Apply swaps before ordinary claims so subsequent descendant paths address
    // the replacement component, not stale descendants of its predecessor.
    for claim in overrides where claim["symbolData"]?["symbolID"] != nil || claim["componentPropAssignments"] != nil {
      try spendOccurrenceWork()
      guard let target=try resolveOccurrence(claim,owner:occurrence) else {continue}
      var replacementFields=target.original.objectValue ?? [:]
      var symbol=target.properties["symbolData"]?.objectValue ?? [:]
      if let swap=claim["symbolData"]?["symbolID"] {
        symbol["symbolID"]=swap;replacementFields["fillPaints"]=nil;replacementFields["styleIdForFill"]=nil
      }
      replacementFields["symbolData"] = .object(symbol)
      if let assignments=claim["componentPropAssignments"]?.arrayValue {
        replacementFields["componentPropAssignments"] = .array(try mergingAssignments(
          target.properties["componentPropAssignments"]?.arrayValue ?? [],assignments))
      }
      guard target.componentID != nil else {issue(key,"instance-override","A component swap targeted a non-instance layer.",severity:"error");continue}
      // The owner is already on the expansion stack; a root swap must start a
      // fresh expansion with its effective symbol, while retaining cycle checks.
      var active=expanding;active.remove(target.sourceID)
      let replacement=try expandOccurrence(target.sourceID,key:target.key,bindings:target.inheritedBindings,expanding:&active,count:&count,depth:depth+1,overlay:.object(replacementFields))
      target.properties=replacement.properties;target.children=replacement.children
      target.componentID=replacement.componentID;target.componentKeys.formUnion(replacement.componentKeys);target.boundaryIndex=nil
    }
    for claim in overrides {
      try spendOccurrenceWork()
      guard let target=try resolveOccurrence(claim,owner:occurrence) else {continue}
      var fields=claim.objectValue ?? [:]
      for field in ["guidPath","guid","parentIndex","symbolData","componentPropAssignments","type","overrideKey"] {fields[field]=nil}
      if fields["textData"] != nil {var current=target.properties.objectValue ?? [:];current["derivedTextData"]=nil;target.properties = .object(current)}
      setOccurrence(target,fields)
    }
    if sourceID != nil && !actualChildren {
      let factor=try number(raw["symbolData"]?["uniformScaleFactor"],1)
      guard factor>0 else {throw FigmaClipboardError.invalid("Instance uniform scale must be positive.")}
      if factor != 1 {try scaleOccurrenceContent(occurrence,by:factor)}
      let before=try occurrenceSize(source),after=try occurrenceSize(raw)
      try resizeOccurrence(occurrence,from:.init(before.x*factor,before.y*factor),to:after,
        hasDerived:!(raw["derivedSymbolData"]?.arrayValue ?? []).isEmpty)
      setOccurrence(occurrence,["size":.object(["x":.double(after.x),"y":.double(after.y)])])
    }
    let derivedFields:Set<String>=["derivedTextData","fontSize","lineHeight","letterSpacing","size","transform","fillGeometry","strokeGeometry","vectorData"]
    for entry in raw["derivedSymbolData"]?.arrayValue ?? [] {
      try spendOccurrenceWork()
      guard let target=try resolveOccurrence(entry,owner:occurrence),target !== occurrence else {continue}
      let previousSize=try occurrenceSize(target.properties)
      setOccurrence(target,(entry.objectValue ?? [:]).filter{derivedFields.contains($0.key)})
      if entry["size"] != nil {
        let next=try occurrenceSize(target.properties)
        if previousSize.x>0 {target.geometryScale.x *= next.x/previousSize.x}
        if previousSize.y>0 {target.geometryScale.y *= next.y/previousSize.y}
      }
      if entry["fillGeometry"] != nil || entry["strokeGeometry"] != nil {target.geometryScale = .init(1,1)}
    }
    return occurrence
  }

  private func resolveOccurrence(_ claim:FigmaValue,owner:FigmaOccurrence) throws -> FigmaOccurrence? {
    let raw=claim["guidPath"]?["guids"]?.arrayValue ?? claim["guid"].map{[$0]} ?? []
    guard raw.count<=64 else {throw FigmaClipboardError.limit("64 override path segments")}
    try spendOccurrenceWork(raw.count+1)
    let path=raw.compactMap(FigmaArtworkImporter.sourceID)
    guard path.count==raw.count else {issue(owner.key,"instance-override","An override path has an invalid identity.",severity:"error");return nil}
    var target=owner
    for (index,segment) in path.enumerated() {
      if index==0 && (owner.componentKeys.contains(segment) || segment==owner.sourceID) {continue}
      if target.boundaryIndex == nil {
        var table:[String:[FigmaOccurrence]]=[:]
        func indexNode(_ node:FigmaOccurrence) throws {
          try spendOccurrenceWork()
          table[node.sourceID,default:[]].append(node)
          if let alias=FigmaArtworkImporter.sourceID(node.properties["overrideKey"]),alias != node.sourceID {table[alias,default:[]].append(node)}
          if node.componentID==nil {for child in node.children {try indexNode(child)}}
        }
        for child in target.children {try indexNode(child)}
        target.boundaryIndex=table
      }
      let matches=target.boundaryIndex?[segment] ?? []
      guard matches.count==1 else {
        issue(owner.key,"instance-override","An override path resolves to \(matches.count) layers at \(segment).",severity:"error");return nil
      }
      target=matches[0]
    }
    return target
  }

  private func resizeOccurrence(_ root:FigmaOccurrence,from before:Point2,to after:Point2,hasDerived:Bool) throws {
    guard before != after else {return}
    let autoLayout=root.properties["stackMode"]?.stringValue.map{$0 != "NONE"} ?? false
    for child in root.children {
      try spendOccurrenceWork()
      if autoLayout && child.properties["stackPositioning"]?.stringValue != "ABSOLUTE" {
        if !hasDerived {issue(root.key,"layout","A resized auto-layout instance has no resolved child layout data.",severity:"error")};continue
      }
      for key in ["horizontalConstraint","verticalConstraint"] {
        if let raw=child.properties[key],raw.stringValue.map({!["MIN","MAX","CENTER","STRETCH","SCALE"].contains($0)}) ?? true {
          issue(child.key,"layout","An unknown resize constraint cannot be preserved.",severity:"error")
        }
      }
      let old=try occurrenceSize(child.properties),transform=try matrix(child.properties["transform"])
      func axis(_ position:Double,_ length:Double,_ before:Double,_ after:Double,_ mode:String?) -> (Double,Double) {
        switch mode {
        case "MAX":return (position+after-before,length)
        case "CENTER":return (position+(after-before)/2,length)
        case "STRETCH":return (position,max(0,length+after-before))
        case "SCALE" where before>0:return (position*after/before,length*after/before)
        default:return (position,length)
        }
      }
      let x=axis(transform.tx,old.x,before.x,after.x,child.properties["horizontalConstraint"]?.stringValue)
      let y=axis(transform.ty,old.y,before.y,after.y,child.properties["verticalConstraint"]?.stringValue)
      let new=Point2(x.1,y.1)
      try resizeOccurrence(child,from:old,to:new,hasDerived:hasDerived)
      var matrix=child.properties["transform"]?.objectValue ?? [:];matrix["m02"] = .double(x.0);matrix["m12"] = .double(y.0)
      setOccurrence(child,["size":.object(["x":.double(new.x),"y":.double(new.y)]),"transform":.object(matrix)])
      if old.x>0 {child.geometryScale.x *= new.x/old.x};if old.y>0 {child.geometryScale.y *= new.y/old.y}
    }
  }

  private func scaleOccurrenceContent(_ root:FigmaOccurrence,by factor:Double) throws {
    func scale(_ node:FigmaOccurrence,isRoot:Bool) throws {
      try spendOccurrenceWork()
      var fields=node.properties.objectValue ?? [:]
      let lengths=["fontSize","strokeWeight","cornerRadius","rectangleTopLeftCornerRadius","rectangleTopRightCornerRadius",
        "rectangleBottomRightCornerRadius","rectangleBottomLeftCornerRadius","borderTopWeight","borderRightWeight",
        "borderBottomWeight","borderLeftWeight","paragraphSpacing","stackSpacing","stackCounterSpacing","stackHorizontalPadding",
        "stackVerticalPadding","stackPaddingRight","stackPaddingBottom"]
      for key in lengths {if let value=fields[key] {fields[key] = .double(try number(value)*factor)}}
      for key in ["lineHeight","letterSpacing"] where fields[key]?["units"]?.stringValue == "PIXELS" {
        var metric=fields[key]!.objectValue ?? [:];metric["value"] = .double(try number(metric["value"])*factor);fields[key] = .object(metric)
      }
      for dataKey in ["textData","derivedTextData"] {
        if var data=fields[dataKey]?.objectValue,let styles=data["styleOverrideTable"]?.arrayValue {
          try spendOccurrenceWork(styles.count)
          data["styleOverrideTable"] = .array(try styles.map { style in
            var properties=style.objectValue ?? [:]
            for key in lengths {if let value=properties[key] {properties[key] = .double(try number(value)*factor)}}
            for key in ["lineHeight","letterSpacing"] where properties[key]?["units"]?.stringValue == "PIXELS" {
              var metric=properties[key]!.objectValue ?? [:];metric["value"] = .double(try number(metric["value"])*factor);properties[key] = .object(metric)
            }
            return .object(properties)
          });fields[dataKey] = .object(data)
        }
      }
      if let values=fields["dashPattern"]?.arrayValue {fields["dashPattern"] = .array(try values.map{.double(try number($0)*factor)})}
      if let effects=fields["effects"]?.arrayValue {
        try spendOccurrenceWork(effects.count)
        fields["effects"] = .array(try effects.map{effect in
          var e=effect.objectValue ?? [:]
          for key in ["radius","spread"] {if let value=e[key] {e[key] = .double(try number(value)*factor)}}
          if let offset=e["offset"] {e["offset"] = .object(["x":.double(try number(offset["x"])*factor),"y":.double(try number(offset["y"])*factor)])}
          return .object(e)
        })
      }
      if !isRoot {
        let size=try occurrenceSize(node.properties)
        fields["size"] = .object(["x":.double(size.x*factor),"y":.double(size.y*factor)])
        var transform=fields["transform"]?.objectValue ?? [:]
        transform["m02"] = .double(try number(transform["m02"])*factor);transform["m12"] = .double(try number(transform["m12"])*factor)
        fields["transform"] = .object(transform)
      }
      node.geometryScale.x *= factor;node.geometryScale.y *= factor
      node.properties = .object(fields)
      for child in node.children {try scale(child,isRoot:false)}
    }
    try scale(root,isRoot:true)
  }
}

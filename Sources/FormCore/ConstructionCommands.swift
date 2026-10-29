import CryptoKit
import Foundation
import CoreFoundation
import FormCADModel

/// Agent-authored planar geometry uses the same parameters, source edits and physical artwork as other recipes.
public enum ConstructionCommands {
  public static func isReadOnly(_ args:[String:Any])->Bool {
    ["capabilities","inspect","validate_cases"].contains(args["command"] as? String ?? "inspect")
  }
  public static func call(engine:OperationEngine,arguments args:[String:Any],source:String)throws->Any {
    if let raw=args["command"],!(raw is String){throw FormError.invalid("Construction command must be a string.")}
    let command=args["command"] as? String ?? "inspect"
    let fields:[String:Set<String>]=[
      "capabilities":[],"create":["definition","name","position","material_id"],
      "convert":["object_id","expected_revision"],
      "inspect":["object_id"],"configure":["object_id","definition","expected_revision"],
      "parameter":["object_id","values","expected_revision"],"validate_cases":["object_id","cases","extrema"]]
    guard let allowed=fields[command],Set(args.keys).isSubset(of:allowed.union(["command"])) else{throw FormError.invalid("Unknown construction command or argument.")}
    if command=="capabilities" {
      return ["units":"mm","commands":fields.keys.sorted(),"source":"PlanarConstructionDefinition",
        "definition_fields":["version","name","parameters","derived","size","stockThickness","panels","hinges","joins","rootPanelID","requirements","connections","solidChecks"],
        "source_versions":[1,2],
        "solid_check_metrics":["clearance","interference"],
        "solid_check_relations":CADModelRequirement.Relation.allCases.map(\.rawValue),
        "solid_check_tolerance":"Existing comparison semantics: tolerance applies to == and !=; inequalities use the authored threshold exactly.",
        "solid_check_fields":["id","firstPanelID","secondPanelID","metric","relation","value","message","tolerance"],
        "solid_checks":"Version 2 explicit panel-pair clearance (mm) or interference (mm3) comparisons. Exact sharp centered stock slabs derive from existing polygons and resolved poses. Only declared pairs/conditions are covered; declare hinge/glue allowances explicitly. Run through the installed app; no source, artwork or Undo mutation.",
        "parameter_fields":["name","value","minimum","maximum","unit"],
        "panel_fields":["id","name","role","polygon","artworkRotationDegrees"],
        "hinge_fields":["id","parentPanelID","childPanelID","start","end","angleDegrees","layerOffsetMM","opensWithTop"],
        "connection_fields":["id","firstPanelID","secondPanelID","firstPoint","secondPoint","maximumGapMM"],
        "expressions":"Numbers or arithmetic/math expressions referencing named parameters. Points use {x,y}; size is the full flat source extent.",
        "artwork":"All projections share registered full-net millimeter coordinates; artworkRotationDegrees defines readable panel orientation.",
        "connection_checks":"Neutral-plane panel anchors are measured after the requested fold/opening. Measurements report actual gap and maximumGapMM; they do not solve the assembly.",
        "limits":["panels":64,"parameters":64,"derived":256,"polygon_vertices":2048,"cases":64,"solid_checks":128,"exact_pair_queries":1024,"exact_seconds":10,"polygon_precision_mm":0.001],
        "example":try jsonObject(example()),"fold_and_glue_example":try jsonObject(foldAndGlueExample()),
        "solid_check_example":try jsonObject(solidCheckExample()),
        "legacy_examples":["envelope":try jsonObject(ConstructionExamples.legacyDefinition(PaperConstructionEngine.defaults(recipeID:"paperEnvelope"))),
          "carton":try jsonObject(ConstructionExamples.legacyDefinition(PaperConstructionEngine.defaults(recipeID:"tuckCarton")))]] as [String:Any]
    }
    guard let project=engine.project else{throw FormError.missing("Open a project before authoring a construction.")}
    func decodeDefinition()throws->PlanarConstructionDefinition {
      guard let raw=args["definition"] as? [String:Any],JSONSerialization.isValidJSONObject(raw) else{throw FormError.invalid("Provide a complete construction definition.")}
      let bytes=try JSONSerialization.data(withJSONObject:raw)
      guard bytes.count<=1024*1024 else{throw FormError.invalid("Construction definition exceeds 1 MiB.")}
      try validateDefinitionJSON(raw)
      let definition=try JSONDecoder().decode(PlanarConstructionDefinition.self,from:bytes)
      _ = try definition.net();return definition
    }
    if command=="create" {
      let definition=try decodeDefinition(),id=UUID(),recipe=recipe(definition,id:"construction-"+id.uuidString)
      var object=ProductObject(name:args["name"] as? String ?? definition.name,recipeID:recipe.id,
        parameters:recipe.defaults,materialID:args["material_id"] as? String ?? "paper-superfine",artwork:.init(background:"#FFFFFF"))
      object.id=id
      if let raw=args["position"] {
        guard let values=raw as? [Double],values.count==3,values.allSatisfy({$0.isFinite && abs($0)<=100000}) else{throw FormError.invalid("Construction position must be three finite millimeter values.")}
        object.position = .init(values[0],values[1],values[2])
      }
      object.paperConstruction=try paper(definition)
      try engine.edit("Created \(object.name)",source:source){p in p.recipes.append(recipe);p.objects.append(object)}
      engine.selection=[id]
      return try inspection(engine.project!.objects.first{$0.id==id}!)
    }
    guard let raw=args["object_id"] as? String,let id=UUID(uuidString:raw),
      let object=project.objects.first(where:{$0.id==id}) else{throw FormError.missing("Choose an existing construction object.")}
    if command=="convert" {
      guard !object.locked else{throw FormError.invalid("Unlock the construction before converting its source.")}
      let legacy=try PaperConstruction.definition(for:object)
      guard legacy.authored==nil else{throw FormError.invalid("This construction already has authored source.")}
      if let expected=args["expected_revision"] {
        guard let expected=expected as? String,expected == (try sourceRevision(legacy)) else{throw FormError.invalid("The legacy construction source changed before conversion.")}
      }
      let convertedID="construction-"+UUID().uuidString,definition=try ConstructionExamples.legacyDefinition(legacy)
      try engine.edit("Converted construction to authored source",source:source){p in
        p.recipes.append(recipe(definition,id:convertedID))
        for i in p.objects.indices where p.objects[i].designID==object.designID {
          guard !p.objects[i].locked else{throw FormError.invalid("Unlock linked constructions before converting shared source.")}
          var source=try PaperConstruction.definition(for:p.objects[i])
          guard source.authored==nil,source.kind==legacy.kind else{throw FormError.invalid("Linked construction sources must be compatible before conversion.")}
          let previous=source,authored=try ConstructionExamples.legacyDefinition(source)
          source.kind = .authored;source.authored=authored
          try verifyConversion(previous,source)
          p.objects[i].recipeID=convertedID;p.objects[i].paperConstruction=source
          p.objects[i].parameters=PaperConstructionEngine.parameters(source)
        }
      }
      var report=try inspection(engine.project!.objects.first{$0.id==id}!)
      report["converted_from"]=legacy.kind.rawValue;report["previous_source_revision"]=try sourceRevision(legacy)
      return report
    }
    guard let definition=try PaperConstruction.definition(for:object).authored else {
      throw FormError.missing("Choose an agent-authored construction.")
    }
    if command=="inspect" {return try inspection(object)}
    if command=="validate_cases" {
      return try jsonObject(validationRequest(project:project,arguments:args).validateGeometryCases())
    }
    guard !object.locked else{throw FormError.invalid("Unlock the construction before editing it.")}
    if let expected=args["expected_revision"] {
      guard let expected=expected as? String,expected == (try revision(definition)) else{throw FormError.invalid("The construction source changed; inspect it before applying this edit.")}
    }
    var next=definition
    var poseValues:[String:Double]=[:]
    if command=="configure" {next=try decodeDefinition()}
    else {
      let values=try numeric(args["values"])
      for key in ["fold","opening"] {if let value=values[key] {
        guard (0...100).contains(value) else{throw FormError.invalid("Construction pose controls must be 0–100%.")}
        poseValues[key]=value
      }}
      try next.setParameters(values)
    }
    let nextPaper=try paper(next),nextRecipe=recipe(next,id:object.recipeID)
    try engine.edit("Updated construction",source:source){p in
      if let i=p.recipes.firstIndex(where:{$0.id==object.recipeID}){p.recipes[i]=nextRecipe}
      for i in p.objects.indices where p.objects[i].designID==object.designID {
        guard !p.objects[i].locked else{throw FormError.invalid("Unlock linked constructions before editing shared source.")}
        let previous=p.objects[i]
        var settings=previous.paperConstruction ?? nextPaper
        settings.kind = .authored;settings.authored=next
        settings.dimensions=nextPaper.dimensions;settings.stock.thicknessMM=nextPaper.stock.thicknessMM
        settings.foldPercent=poseValues["fold"] ?? previous.paperConstruction?.foldPercent ?? 100
        settings.openingPercent=poseValues["opening"] ?? previous.paperConstruction?.openingPercent ?? 0
        settings.insideArtworkSourceID=previous.paperConstruction?.insideArtworkSourceID;settings.insideArtwork=previous.paperConstruction?.insideArtwork
        settings.annotations=previous.paperConstruction?.annotations ?? []
        p.objects[i].paperConstruction=settings
        p.objects[i].parameters=PaperConstructionEngine.parameters(settings)
        p.objects[i]=try PaperConstructionEngine.synchronized(p.objects[i],previous:previous)
      }
    }
    return try inspection(engine.project!.objects.first{$0.id==id}!)
  }
  private static func numeric(_ value:Any?,allowEmpty:Bool=false)throws->[String:Double] {
    guard let map=value as? [String:Any],allowEmpty || !map.isEmpty else{throw FormError.invalid("Provide a numeric parameter map; edits require at least one parameter.")}
    var result:[String:Double]=[:]
    for (key,raw) in map {guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{throw FormError.invalid("Parameter '\(key)' must be a finite number.")};result[key]=n.doubleValue}
    return result
  }
  private static func object(_ raw:Any,allowed:Set<String>,label:String)throws->[String:Any] {
    guard let value=raw as? [String:Any] else{throw FormError.invalid("\(label) must be an object.")}
    let unknown=Set(value.keys).subtracting(allowed)
    guard unknown.isEmpty else{throw FormError.invalid("Unknown \(label) fields: \(unknown.sorted().joined(separator:", ")).")}
    return value
  }
  private static func objects(_ raw:Any,label:String)throws->[[String:Any]] {
    guard let values=raw as? [[String:Any]] else{throw FormError.invalid("\(label) must be an array of objects.")}
    return values
  }
  private static func point(_ raw:Any,label:String)throws {
    _ = try object(raw,allowed:["x","y"],label:label)
  }
  private static func validateDefinitionJSON(_ raw:[String:Any])throws {
    let definition=try object(raw,allowed:["version","name","parameters","derived","size","stockThickness","panels","hinges","joins","rootPanelID","requirements","connections","solidChecks"],label:"construction definition")
    if let raw=definition["size"]{try point(raw,label:"construction size")}
    if let raw=definition["parameters"] {for value in try objects(raw,label:"construction parameters") {
      _ = try object(value,allowed:["name","value","minimum","maximum","unit"],label:"construction parameter")
    }}
    if let raw=definition["panels"] {for value in try objects(raw,label:"construction panels") {
      let panel=try object(value,allowed:["id","name","role","polygon","artworkRotationDegrees"],label:"construction panel")
      if let raw=panel["polygon"] {for value in try objects(raw,label:"panel polygon") {try point(value,label:"panel polygon point")}}
    }}
    if let raw=definition["hinges"] {for value in try objects(raw,label:"construction hinges") {
      let hinge=try object(value,allowed:["id","parentPanelID","childPanelID","start","end","angleDegrees","layerOffsetMM","opensWithTop"],label:"construction hinge")
      if let raw=hinge["start"]{try point(raw,label:"hinge start")};if let raw=hinge["end"]{try point(raw,label:"hinge end")}
    }}
    if let raw=definition["joins"] {for value in try objects(raw,label:"construction joins") {
      _ = try object(value,allowed:["id","name","firstPanelID","secondPanelID","kind","overlapMM","notes"],label:"construction join")
    }}
    if let raw=definition["requirements"],!(raw is NSNull) {for value in try objects(raw,label:"construction requirements") {
      _ = try object(value,allowed:["id","lhs","relation","rhs","message","tolerance"],label:"construction requirement")
    }}
    if let raw=definition["solidChecks"],!(raw is NSNull) {for value in try objects(raw,label:"construction solid checks") {
      _ = try object(value,allowed:["id","firstPanelID","secondPanelID","metric","relation","value","message","tolerance"],label:"construction solid check")
    }}
    if let raw=definition["connections"],!(raw is NSNull) {for value in try objects(raw,label:"construction connections") {
      let connection=try object(value,allowed:["id","firstPanelID","secondPanelID","firstPoint","secondPoint","maximumGapMM"],label:"construction connection")
      if let raw=connection["firstPoint"]{try point(raw,label:"first connection point")}
      if let raw=connection["secondPoint"]{try point(raw,label:"second connection point")}
    }}
  }
  public static func validationRequest(project:Project,arguments args:[String:Any]) throws -> PlanarConstructionValidationRequest {
    guard args["command"] as? String == "validate_cases",Set(args.keys).isSubset(of:["command","object_id","cases","extrema"]),
      let raw=args["object_id"] as? String,let id=UUID(uuidString:raw),
      let object=project.objects.first(where:{$0.id==id}) else {
      throw FormError.invalid("Construction case validation needs an existing object_id and only cases/extrema arguments.")
    }
    let source=try PaperConstruction.definition(for:object)
    guard let definition=source.authored else{throw FormError.missing("Choose an agent-authored construction.")}
    var cases=[PlanarParameterCase(name:"default",values:definition.values)]
    if let raw=args["cases"] {
      guard let requested=raw as? [[String:Any]],requested.count<=64 else{throw FormError.invalid("Provide at most 64 parameter cases.")}
      cases=[]
      for item in requested {
        guard Set(item.keys).isSubset(of:["name","values"]),let name=item["name"] as? String,
          !name.isEmpty,name.utf8.count<=128 else{throw FormError.invalid("Each parameter case needs a bounded name and values.")}
        cases.append(.init(name:name,values:try numeric(item["values"],allowEmpty:true)))
      }
    }
    if let raw=args["extrema"] {
      guard let flag=raw as? NSNumber,CFGetTypeID(flag)==CFBooleanGetTypeID() else{throw FormError.invalid("extrema must be a boolean.")}
      if flag.boolValue {for parameter in definition.parameters {
        cases.append(.init(name:parameter.name+".minimum",values:[parameter.name:parameter.minimum]))
        cases.append(.init(name:parameter.name+".maximum",values:[parameter.name:parameter.maximum]))
      }}
    }
    guard !cases.isEmpty,cases.count<=64,Set(cases.map(\.name)).count==cases.count else {
      throw FormError.invalid("Use 1–64 uniquely named cases including requested extrema.")
    }
    return .init(projectID:project.id,objectID:id,sourceRevision:try revision(definition),
      definition:definition,fold:source.foldPercent,opening:source.openingPercent,cases:cases)
  }
  public static func validationSourceIsCurrent(_ request:PlanarConstructionValidationRequest,in project:Project?) -> Bool {
    guard let project,project.id==request.projectID,let object=project.objects.first(where:{$0.id==request.objectID}),
      let source=try? PaperConstruction.definition(for:object) else{return false}
    return source.authored==request.definition && source.foldPercent==request.fold && source.openingPercent==request.opening
  }
  private static func recipe(_ d:PlanarConstructionDefinition,id:String)->Recipe {
    let parameters=d.parameters.map{Parameter($0.name,$0.name,$0.value,$0.minimum...$0.maximum,unit:$0.unit,step:0.1)}
      + [Parameter("fold","Fold",100,0...100,unit:"%",step:1),Parameter("opening","Opening",0,0...100,unit:"%",step:1)]
    let names=Set(d.parameters.map(\.name))
    // Source validation checks every requirement with its derived values. Recipe
    // consumers can independently validate those using only editable controls.
    let simpleRequirements=d.requirements?.filter {
      guard let lhs=try? CADExpression.referencedNames(in:$0.lhs.expression),let rhs=try? CADExpression.referencedNames(in:$0.rhs.expression) else{return false}
      return lhs.union(rhs).isSubset(of:names)
    }
    return Recipe(id,d.name,"square.3.layers.3d","Agent-authored physical construction",parameters,requirements:simpleRequirements)
  }
  private static func paper(_ d:PlanarConstructionDefinition)throws->PaperConstruction {
    let net=try d.net()
    var source=PaperConstruction(kind:.authored,dimensions:.init(width:d.values["width"] ?? net.size.x,
      height:d.values["height"] ?? net.size.y,depth:d.values["depth"] ?? 1),stock:.init(thicknessMM:try d.number(d.stockThickness)))
    source.authored=d;return source
  }
  private static func revision(_ d:PlanarConstructionDefinition)throws->String {
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    return SHA256.hash(data:try encoder.encode(d)).map{String(format:"%02x",$0)}.joined()
  }
  private static func sourceRevision(_ source:PaperConstruction)throws->String {
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    return SHA256.hash(data:try encoder.encode(source)).map{String(format:"%02x",$0)}.joined()
  }
  private static func verifyConversion(_ previous:PaperConstruction,_ next:PaperConstruction)throws {
    let before=try previous.net(),after=try next.net()
    guard before.panels.map(\.id)==after.panels.map(\.id),before.cutEdges.map(\.id)==after.cutEdges.map(\.id),
      before.folds.map(\.id)==after.folds.map(\.id),before.joins==after.joins else {
      throw FormError.invalid("Compatibility conversion changed stable source identities; the original construction was retained.")
    }
    let oldPoints=before.panels.flatMap(\.polygon),newPoints=after.panels.flatMap(\.polygon)
    guard oldPoints.count==newPoints.count,zip(oldPoints,newPoints).allSatisfy({hypot($0.x-$1.x,$0.y-$1.y)<=1e-7}) else{
      throw FormError.invalid("Compatibility conversion changed flat geometry; the original construction was retained.")
    }
    let oldPoses=try previous.resolvedPanels(),newPoses=try next.resolvedPanels()
    guard oldPoses.map(\.panelID)==newPoses.map(\.panelID),zip(oldPoses,newPoses).allSatisfy({a,b in
      zip(a.flatToWorld,b.flatToWorld).allSatisfy{abs($0-$1)<=1e-7}
    }) else{throw FormError.invalid("Compatibility conversion changed the requested folded pose; the original construction was retained.")}
  }
  private static func inspection(_ object:ProductObject)throws->[String:Any] {
    let source=try PaperConstruction.definition(for:object),d=source.authored!
    let poses=try source.resolvedPanels(),connections=try d.connectionMeasurements(poses:poses)
    return ["object_id":object.id.uuidString,"revision":try revision(d),"definition":try jsonObject(d),
      "net":try jsonObject(source.net()),"poses":try jsonObject(poses),"parameters":object.parameters,
      "connection_checks":try jsonObject(connections),"connections_passed":connections.allSatisfy(\.passed),
      "solid_checks_status":d.solidChecks?.isEmpty == false ? "not_evaluated":"not_declared"]
  }
  public static func solidCheckExample()->PlanarConstructionDefinition {
    .init(name:"Declared stock contact",parameters:[.init("width",40,10...100),.init("height",50,10...100),
      .init("stock",0.4,0.1...1),.init("layer",0.4,0...2),.init("angle",180,0...180)],
      size:.init("2*width","height"),stockThickness:"stock",panels:[
        .init(id:"first",name:"First",polygon:[.init(0,0),.init("width",0),.init("width","height"),.init(0,"height")]),
        .init(id:"second",name:"Second",polygon:[.init("width",0),.init("2*width",0),.init("2*width","height"),.init("width","height")])],
      hinges:[.init(id:"crease",parentPanelID:"first",childPanelID:"second",start:.init("width",0),end:.init("width","height"),
        angleDegrees:"angle",layerOffsetMM:"layer")],rootPanelID:"first",solidChecks:[
          .init(id:"material-separation",firstPanelID:"first",secondPanelID:"second",metric:.interference,relation:.lessThanOrEqual,
            value:0,message:"These panels may touch but must not occupy the same stock volume"),
          .init(id:"mating-gap",firstPanelID:"first",secondPanelID:"second",metric:.clearance,relation:.equal,
            value:"max(layer-stock,0)",message:"Preserve the declared stock gap",tolerance:1e-6)])
  }
  public static func foldAndGlueExample()->PlanarConstructionDefinition {
    let parameters:[CADModelParameter]=[.init("width",80,40...160),.init("depth",30,10...60),
      .init("height",100,40...200),.init("glueTab",12,6...20),.init("stock",0.4,0.1...1),.init("seamAngle",-90,-110 ... -70)]
    func rectangle(_ id:String,_ name:String,_ left:CADScalar,_ right:CADScalar,role:PaperPanel.Role = .body)->PlanarPanelDefinition {
      .init(id:id,name:name,role:role,polygon:[.init(left,0),.init(right,0),.init(right,"height"),.init(left,"height")])
    }
    let panels=[rectangle("front","Front",0,"width"),rectangle("right","Right","width","width+depth",role:.side),
      rectangle("back","Back","width+depth","2*width+depth"),rectangle("left","Left","2*width+depth","seamX",role:.side),
      rectangle("glue","Glue tab","seamX","seamX+glueTab",role:.glue)]
    let edges:[(String,String,CADScalar)]=[("front","right","width"),("right","back","width+depth"),("back","left","2*width+depth"),("left","glue","seamX")]
    let hinges=edges.map {parent,child,x in
      PlanarHingeDefinition(id:"fold.\(parent).\(child)",parentPanelID:parent,childPanelID:child,
        start:.init(x,0),end:.init(x,"height"),angleDegrees:child=="glue" ? "seamAngle":-90,
        layerOffsetMM:child=="glue" ? "stock":0)
    }
    return .init(name:"Fold and glue sleeve",parameters:parameters,size:.init("seamX+glueTab","height"),stockThickness:"stock",
      panels:panels,hinges:hinges,joins:[.init(id:"side-seam",name:"Glue seam",firstPanelID:"glue",secondPanelID:"front",overlapMM:"glueTab")],rootPanelID:"front",
      derived:["seamX":"2*(width+depth)"],connections:[.init(id:"side-contact",firstPanelID:"glue",secondPanelID:"front",
        firstPoint:.init("seamX+glueTab/2","height/2"),secondPoint:.init("glueTab/2","height/2"),maximumGapMM:"stock*2")])
  }
  public static func example()->PlanarConstructionDefinition {
    let p:[CADModelParameter]=[.init("width",100,40...240),.init("depth",30,10...60),.init("height",80,40...200)]
    let panels=[
      PlanarPanelDefinition(id:"base",name:"Base",polygon:[.init("depth","depth"),.init("depth+width","depth"),.init("depth+width","depth+height"),.init("depth","depth+height")]),
      .init(id:"left",name:"Left",polygon:[.init(0,"depth"),.init("depth","depth"),.init("depth","depth+height"),.init(0,"depth+height")],artworkRotationDegrees:90),
      .init(id:"right",name:"Right",polygon:[.init("depth+width","depth"),.init("width+2*depth","depth"),.init("width+2*depth","depth+height"),.init("depth+width","depth+height")],artworkRotationDegrees:270),
      .init(id:"top",name:"Top",polygon:[.init("depth",0),.init("depth+width",0),.init("depth+width","depth"),.init("depth","depth")],artworkRotationDegrees:180)]
    let hinges:[PlanarHingeDefinition]=[
      .init(id:"base-left",parentPanelID:"base",childPanelID:"left",start:.init("depth","depth"),end:.init("depth","depth+height"),angleDegrees:90),
      .init(id:"base-right",parentPanelID:"base",childPanelID:"right",start:.init("depth+width","depth"),end:.init("depth+width","depth+height"),angleDegrees:-90),
      .init(id:"base-top",parentPanelID:"base",childPanelID:"top",start:.init("depth","depth"),end:.init("depth+width","depth"),angleDegrees:-90,opensWithTop:true)]
    return .init(name:"Folded display",parameters:p,size:.init("width+2*depth","height+depth"),panels:panels,hinges:hinges,rootPanelID:"base")
  }
}

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
        "definition_fields":["version","name","parameters","derived","size","stockThickness","panels","hinges","joins","rootPanelID","requirements","connections","solidChecks","components","interiors"],
        "definition_required_fields":["version","name","parameters","size","stockThickness","panels","hinges","joins","rootPanelID"],
        "definition_optional_fields":["requirements","derived","connections","solidChecks","components","interiors"],
        "source_versions":[1,2,3],
        "components":"Explicit independent hinge-tree roots share parameters and canonical flat sheet coordinates; authored assembled anchor/XYZ Euler poses use millimeters and may reference fold/opening percentages.",
        "cutouts":"Stable panel cutouts remove finite material; window, slot and perforation kinds preserve technical identity. All rings share the 2048-vertex bound.",
        "interiors":"Named declared component-local volumes and optional rectangular opening cross-sections; actual referenced contents are checked through form_paper preflight, not inferred from flat net bounds.",
        "artwork_parameter_source":"Existing independent canonical artwork plus Recipe controls. Set artwork_parameter_bindings through form_update_object; no additional sewing document or generator. inspect/parameter/validate_cases accept that source object_id.",
        "artwork_binding_fields":["id","elementID","property","value"],
        "artwork_case_evidence_budget":ArtworkConstructionValidationRequest.maximumEvidenceUnits,
        "artwork_binding_properties":ArtworkParameterBinding.Property.allCases.map(\.rawValue),
        "case_outcomes":["passed","failed","cancelled","budget_exceeded","not_run"],
        "solid_check_metrics":["clearance","interference"],
        "solid_check_relations":CADModelRequirement.Relation.allCases.map(\.rawValue),
        "solid_check_tolerance":"Existing comparison semantics: tolerance applies to == and !=; inequalities use the authored threshold exactly.",
        "solid_check_fields":["id","firstPanelID","secondPanelID","metric","relation","value","message","tolerance"],
        "solid_checks":"Version 2 or 3 explicit panel-pair clearance (mm) or interference (mm3) comparisons. Exact sharp centered stock slabs derive from existing outer/inner polygons and resolved poses. Only declared pairs/conditions are covered; declare hinge/glue allowances explicitly. Run through the installed app; no source, artwork or Undo mutation.",
        "parameter_fields":["name","value","minimum","maximum","unit"],
        "panel_fields":["id","name","role","polygon","artworkRotationDegrees","cutouts"],
        "panel_required_fields":["id","name","role","polygon"],
        "panel_optional_fields":["artworkRotationDegrees","cutouts"],
        "panel_roles":["body","side","glue","tuck","dust","bottomClosure"],
        "component_fields":["id","name","rootPanelID","anchor","position","rotationDegrees"],
        "component_required_fields":["id","name","rootPanelID","anchor","position","rotationDegrees"],
        "component_optional_fields":[String](),
        "cutout_fields":["id","polygon","kind"],
        "cutout_required_fields":["id","polygon","kind"],
        "cutout_optional_fields":[String](),
        "cutout_kinds":["cutout","window","slot","perforation"],
        "cutout_coordinates":"Version 3 finite removed polygons in the same full flat-net {x,y} coordinates as the panel, strictly inside remaining panel material. Holes cannot touch or overlap. Perforations retain explicit material bridges; tearing is not simulated.",
        "interior_fields":["id","name","componentID","origin","size","rotationDegrees","opening"],
        "interior_required_fields":["id","name","componentID","origin","size"],
        "interior_optional_fields":["rotationDegrees","opening"],
        "opening_fields":["axis","width","height","origin"],
        "opening_required_fields":["axis","width","height"],
        "opening_optional_fields":["origin"],
        "opening_axes":["x","y","z"],
        "opening_transverse_axes":["x":["y","z"],"y":["x","z"],"z":["x","y"]],
        "opening_coordinates":"Origin is optional {x,y}, default zero in the two transverse interior coordinates. Width/height and origin must fit the declared interior cross-section. This is a bounds review, not an insertion solver.",
        "point2_fields":["x","y"],"point3_fields":["x","y","z"],
        "component_coordinates":"Version 3 anchor is a full-net {x,y} point. Position/rotationDegrees are {x,y,z}; assembly axes are X right, Y up, Z toward the nominal front. Fold 0 retains the flat layout; Fold 100 applies the declared upright root pose, rotations X then Y then Z (Rz*Ry*Rx). A common closed-bounds X/Z centering and Y grounding follows. Only root-pose expressions additionally receive fold/opening percentages.",
        "interior_coordinates":"Version 3 origin/size/optional rotationDegrees are {x,y,z} in the named component's anchor frame; omitted rotation is zero. The review volume follows that component's current pose. An author-declared volume does not infer physical enclosing walls.",
        "hinge_fields":["id","parentPanelID","childPanelID","start","end","angleDegrees","layerOffsetMM","opensWithTop"],
        "connection_fields":["id","firstPanelID","secondPanelID","firstPoint","secondPoint","maximumGapMM"],
        "expressions":"Numbers or arithmetic/math expressions referencing named parameters. Polygon/anchor/size points use {x,y}; component position/rotation and interior origin/size use {x,y,z}. Size is the full flat source extent; translations are mm and rotationDegrees are degrees.",
        "artwork":"All projections share registered full-net millimeter coordinates; artworkRotationDegrees defines readable panel orientation.",
        "connection_checks":"Neutral-plane panel anchors are measured after the requested fold/opening. Measurements report actual gap and maximumGapMM; they do not solve the assembly.",
        "limits":["panels":64,"components":32,"interiors":64,"cutouts_per_panel":64,"vertices_per_contour":128,"parameters":64,"derived":256,"polygon_vertices":2048,"cases":64,"solid_checks":128,"exact_pair_queries":1024,"exact_seconds":10,"polygon_precision_mm":0.001,"stock_min_mm":0.01,"stock_max_mm":20,"net_extent_max_mm":10000,"definition_bytes":1048576],
        "example":try jsonObject(example()),"fold_and_glue_example":try jsonObject(foldAndGlueExample()),
        "solid_check_example":try jsonObject(solidCheckExample()),
        "multi_component_example":try jsonObject(multiComponentExample()),
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
      object.artwork?.backgroundOpacity=0
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
    if object.artworkParameterBindings?.isEmpty == false {
      if command=="inspect" {return ["object_id":id.uuidString,"source_kind":"canonical_artwork_parameters",
        "source_revision":try ArtworkConstructionValidationRequest.revision(in:project,objectID:id),
        "parameters":object.parameters,"bindings":try jsonObject(object.artworkParameterBindings!),
        "recipe":try jsonObject(project.recipe(object.recipeID)!)] as [String:Any]}
      if command=="validate_cases" {
        _ = try artworkValidationRequest(project:project,arguments:args)
        throw FormError.invalid("Canonical artwork case validation uses LAB's asynchronous source lifecycle. Run form_construction validate_cases through the app.")
      }
      if command=="parameter" {
        if let expected=args["expected_revision"] {
          guard let expected=expected as? String,expected == (try ArtworkConstructionValidationRequest.revision(in:project,objectID:id)) else {throw FormError.invalid("The artwork source changed; inspect it before applying this edit.")}
        }
        return try engine.call("form_update_object",arguments:["object_id":id.uuidString,"parameters":try numeric(args["values"])],source:source)
      }
      throw FormError.invalid("This object already uses canonical artwork parameter bindings. Edit those declarations through form_update_object.")
    }
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
      do {return try jsonObject(validationRequest(project:project,arguments:args).validateGeometryCases())}
      catch let interrupted as PlanarConstructionValidationInterrupted {return try jsonObject(interrupted.report)}
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
  /// Executable general source data, independent of any product category.
  public static func multiComponentExample()->PlanarConstructionDefinition {
    .init(name:"Windowed two-sheet review",parameters:[.init("width",60,40...100),
      .init("height",40,20...80),.init("depth",10,2...30),.init("stock",0.5,0.1...1)],
      size:.init("2*width+20","height"),stockThickness:"stock",panels:[
        .init(id:"first",name:"First sheet",polygon:[.init(0,0),.init("width",0),.init("width","height"),.init(0,"height")],
          cutouts:[.init(id:"window",polygon:[.init("width/3","height/3"),.init("2*width/3","height/3"),
            .init("2*width/3","2*height/3"),.init("width/3","2*height/3")],kind:.window)]),
        .init(id:"second",name:"Second sheet",polygon:[.init("width+20",0),.init("2*width+20",0),
          .init("2*width+20","height"),.init("width+20","height")])],rootPanelID:"first",components:[
        .init(id:"first",name:"First independent root",rootPanelID:"first",anchor:.init(0,"height"),position:.init("-width/2",0,"-depth/2")),
        .init(id:"second",name:"Second independent root",rootPanelID:"second",anchor:.init("width+20","height"),
          position:.init("-width/2",0,"depth/2+opening/100*20"))],interiors:[
        .init(id:"review-volume",name:"Declared open review volume",componentID:"first",origin:.init(0,0,"stock/2"),
          size:.init("width","height","depth-stock"),opening:.init(axis:.z,width:"width",height:"height"))])
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
    let definition=try object(raw,allowed:["version","name","parameters","derived","size","stockThickness","panels","hinges","joins","rootPanelID","requirements","connections","solidChecks","components","interiors"],label:"construction definition")
    if let raw=definition["size"]{try point(raw,label:"construction size")}
    if let raw=definition["parameters"] {for value in try objects(raw,label:"construction parameters") {
      _ = try object(value,allowed:["name","value","minimum","maximum","unit"],label:"construction parameter")
    }}
    if let raw=definition["panels"] {for value in try objects(raw,label:"construction panels") {
      let panel=try object(value,allowed:["id","name","role","polygon","artworkRotationDegrees","cutouts"],label:"construction panel")
      if let raw=panel["polygon"] {for value in try objects(raw,label:"panel polygon") {try point(value,label:"panel polygon point")}}
      if let raw=panel["cutouts"],!(raw is NSNull) {for value in try objects(raw,label:"panel cutouts") {
        let cutout=try object(value,allowed:["id","polygon","kind"],label:"panel cutout")
        if let raw=cutout["polygon"] {for p in try objects(raw,label:"cutout polygon") {try point(p,label:"cutout point")}}
      }}
    }}
    func point3(_ value:Any,_ label:String)throws {_ = try object(value,allowed:["x","y","z"],label:label)}
    if let raw=definition["components"],!(raw is NSNull) {for value in try objects(raw,label:"construction components") {
      let component=try object(value,allowed:["id","name","rootPanelID","anchor","position","rotationDegrees"],label:"construction component")
      if let p=component["anchor"] {try point(p,label:"component anchor")}
      if let p=component["position"] {try point3(p,"component position")}
      if let p=component["rotationDegrees"] {try point3(p,"component rotation")}
    }}
    if let raw=definition["interiors"],!(raw is NSNull) {for value in try objects(raw,label:"construction interiors") {
      let interior=try object(value,allowed:["id","name","componentID","origin","size","rotationDegrees","opening"],label:"construction interior")
      for key in ["origin","size","rotationDegrees"] {if let p=interior[key],!(p is NSNull) {try point3(p,"interior \(key)")}}
      if let raw=interior["opening"],!(raw is NSNull) {
        let opening=try object(raw,allowed:["axis","width","height","origin"],label:"interior opening")
        if let p=opening["origin"],!(p is NSNull) {try point(p,label:"opening origin")}
      }
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
    let cases=try parameterCases(arguments:args,defaults:definition.values,
      parameters:definition.parameters.map{($0.name,$0.minimum,$0.maximum)})
    return .init(projectID:project.id,objectID:id,sourceRevision:try revision(definition),
      definition:definition,fold:source.foldPercent,opening:source.openingPercent,cases:cases)
  }
  static func parameterCases(arguments args:[String:Any],defaults:[String:Double],parameters:[(String,Double,Double)])throws->[PlanarParameterCase] {
    var cases=[PlanarParameterCase(name:"default",values:defaults)]
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
      if flag.boolValue {for parameter in parameters {
        cases.append(.init(name:parameter.0+".minimum",values:[parameter.0:parameter.1]))
        cases.append(.init(name:parameter.0+".maximum",values:[parameter.0:parameter.2]))
      }}
    }
    guard !cases.isEmpty,cases.count<=64,Set(cases.map(\.name)).count==cases.count else {
      throw FormError.invalid("Use 1–64 uniquely named cases including requested extrema.")
    }
    return cases
  }
  public static func artworkValidationRequest(project:Project,arguments args:[String:Any])throws->ArtworkConstructionValidationRequest {
    guard args["command"] as? String == "validate_cases",Set(args.keys).isSubset(of:["command","object_id","cases","extrema"]),
      let raw=args["object_id"] as? String,let id=UUID(uuidString:raw),let object=project.objects.first(where:{$0.id==id}),
      let recipe=project.recipe(object.recipeID) else{throw FormError.invalid("Choose an existing canonical artwork source and only cases/extrema validation arguments.")}
    let defaults=try project.artworkBindingParameters(for:object)
    let cases=try parameterCases(arguments:args,defaults:defaults,parameters:recipe.parameters.map{($0.id,$0.minimum,$0.maximum)})
    return try .init(project:project,objectID:id,cases:cases)
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
      "components":try jsonObject(PaperConstructionEngine.resolvedComponents(source)),
      "interiors":try jsonObject(PaperConstructionEngine.resolvedInteriors(source)),
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

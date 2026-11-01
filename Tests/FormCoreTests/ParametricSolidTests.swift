import XCTest
@testable import FormCore

final class ParametricSolidTests:XCTestCase {
  private func fixture()->Recipe {
    .init("variableAssembly","Variable assembly","cube","Generic repeated solid",[.init("count","Count",6,2...12,unit:"",step:1),.init("reach","Reach",12,8...20)],solid:.init(nodes:[
      .init(kind:"group",count:"count",index:"i",bindings:[.init("angle","i*2*pi/count")],children:[
        .init(kind:"segment",values:["x":"0","y":"0","z":"0","endX":"reach*cos(angle)","endY":"4","endZ":"reach*sin(angle)","radius":"2","endRadius":"1"])
      ])
    ]))
  }
  func testBoundedMathFunctionsAndInvalidInputs()throws {
    for (s,n) in [("sin(pi/2)",1.0),("cos(0)",1),("pow(2,3)",8),("mix(2,10,0.25)",4),("clamp(-5,0,1)",0),("fract(-0.2)",0.8),("pick(2,5,6,7)",7),("sqrt(abs(-9))",3)] {XCTAssertEqual(try Expression.evaluate(s,variables:[:]),n,accuracy:1e-10)}
    for s in ["sqrt(-1)","pow(0,-1)","pick(1.5,2,3)","pick(8,1,2)","clamp(1,2,0)","sin(1,2)","unknown(0)","sin("] {XCTAssertThrowsError(try Expression.evaluate(s,variables:[:]),s)}
  }
  func testRepeatBindingsAreLocalDeterministicAndParameterDriven()throws {
    let recipe=fixture(),solid=try XCTUnwrap(recipe.solid),a=try solid.evaluate(recipe.defaults)
    XCTAssertEqual(a.primitives.count,6);XCTAssertEqual(a.primitives[0].values["endX"],12)
    XCTAssertEqual(try solid.evaluate(recipe.defaults).primitives.map(\.values),a.primitives.map(\.values))
    XCTAssertEqual(try solid.evaluate(["count":3,"reach":20]).primitives.count,3)
    XCTAssertThrowsError(try solid.evaluate(["count":3.5,"reach":12]))
    var invalid=solid;invalid.nodes[0].index="count";XCTAssertThrowsError(try invalid.evaluate(recipe.defaults))
    invalid=solid;invalid.nodes[0].children![0].values!["radius"]="0";XCTAssertThrowsError(try invalid.evaluate(recipe.defaults))
    invalid=solid;invalid.nodes[0].children![0].values!["invented"]="1";XCTAssertThrowsError(try invalid.evaluate(recipe.defaults))
  }
  func testRecipeReplacementUndoPersistenceAndBuiltInProtection()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let e=OperationEngine(repository:try ProjectRepository(root:root));_ = try e.call("form_create_project",arguments:["name":"Generic geometry"])
    let recipe=fixture();_ = try e.call("form_create_recipe",arguments:["recipe":try jsonObject(recipe)])
    _ = try e.call("form_add_object",arguments:["recipe_id":recipe.id,"parameters":["count":4]])
    let before=e.project!;var changed=recipe;changed.summary="Changed source";changed.solid!.nodes[0].children![0].values!["endY"]="8"
    XCTAssertThrowsError(try e.call("form_create_recipe",arguments:["recipe":try jsonObject(changed)]))
    _ = try e.call("form_create_recipe",arguments:["recipe":try jsonObject(changed),"replace":true])
    XCTAssertEqual(e.project!.objects[0]["count"],4);XCTAssertEqual(e.project!.recipes[0],changed)
    e.undo();XCTAssertEqual(e.project,before);e.redo();try e.flush()
    let restored=try e.repository.load(e.project!.id);XCTAssertEqual(restored.recipes,e.project!.recipes);XCTAssertEqual(restored.schemaVersion,62)
    var builtIn=recipe;builtIn.id="box";XCTAssertThrowsError(try e.call("form_create_recipe",arguments:["recipe":try jsonObject(builtIn),"replace":true]))
  }
  func testExpansionDepthAndSourceBudgets()throws {
    let primitive=SolidNode(kind:"ellipsoid",values:["x":"0","y":"0","z":"0","radiusX":"4","radiusY":"4","radiusZ":"4"])
    var nested=primitive
    for i in 0..<14{nested = .init(kind:"group",count:"1",index:"n\(i)",children:[nested])}
    XCTAssertThrowsError(try ParametricSolid(nodes:[nested]).evaluate([:]))
    let many=SolidNode(kind:"group",count:"1000",index:"a",children:[.init(kind:"group",count:"20",index:"b",children:[primitive])])
    XCTAssertThrowsError(try ParametricSolid(nodes:[many]).evaluate([:]))
  }
}

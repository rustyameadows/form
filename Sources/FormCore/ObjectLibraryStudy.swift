import Foundation

extension Samples {
  public static func giftShopCollection() throws -> Project {
    var p=Project(name:"Gift shop / Working assortment",subtitle:"Real proposed products, approximate previews and room to design.")
    let positions: [(String,Vector3)] = [
      ("heavy-tee",.init(-1100,0,-650)), ("jersey-tee",.init(150,0,-650)),
      ("pullover-hoodie",.init(1500,0,-650)), ("dad-cap",.init(-1100,0,450)),
      ("cuffed-beanie",.init(-500,0,450)), ("bandana",.init(300,0,500)), ("canvas-tote",.init(1300,0,550)),
    ]
    for (id,position) in positions { _=try p.addLibraryObject(id,position:position) }
    p.notes = [
      .init("These are proposed blanks. Inspect each product reference and selection reason, change compatible blanks freely, and keep artwork in independent physical decoration regions."),
      .init("All garment geometry is approximate. Sizes, color variants, production templates, decoration routes, availability and prices remain to be checked before ordering.",kind:"question"),
    ]
    p.camera.distance=65; p.camera.elevation=1.2; p.camera.azimuth=0; p.camera.target = .init(3,0,-2.5)
    p.schemaVersion=p.minimumSchemaVersion
    try p.validateArtworkLinks(); return p
  }
}

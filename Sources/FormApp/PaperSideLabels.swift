import FormCore

/// Presentation labels only; saved physical side identities stay outside/inside.
enum PaperSideLabels {
  static func isFlatSheet(_ net:PaperNet)->Bool {net.panels.count==1 && net.folds.isEmpty}
  static func title(inside:Bool,net:PaperNet)->String {
    isFlatSheet(net) ? (inside ? "Bottom":"Top"):(inside ? "Inside":"Outside")
  }
  static func title(inside:Bool,object:ProductObject)->String {
    guard let net=try? PaperConstruction.definition(for:object).net() else{return inside ? "Inside":"Outside"}
    return title(inside:inside,net:net)
  }
}

import Foundation

/// Bounded, acyclic named arithmetic reused by authored construction sources.
/// Expressions retain CADScalar's existing parser, limits and math functions.
public enum CADDerivedExpressions {
  public static func resolve(_ expressions:[String:CADScalar],variables:[String:Double])throws->[String:Double] {
    guard expressions.count<=256,variables.count<=256,
      variables.allSatisfy({CADExpression.validName($0.key) && $0.value.isFinite && abs($0.value)<=1e7}),
      expressions.keys.allSatisfy({CADExpression.validName($0) && variables[$0]==nil}) else {
      throw CADModelError("Use up to 256 uniquely named derived expressions, distinct from finite source parameters.")
    }
    let known=Set(variables.keys).union(expressions.keys)
    var dependencies:[String:Set<String>]=[:]
    for name in expressions.keys.sorted() {
      let names=try CADExpression.referencedNames(in:expressions[name]!.expression)
      let unknown=names.subtracting(known)
      guard unknown.isEmpty else{throw CADModelError("Derived expression '\(name)' references unknown values: \(unknown.sorted().joined(separator:", ")).")}
      dependencies[name]=names
    }
    var resolved=variables,pending=Set(expressions.keys)
    while !pending.isEmpty {
      var advanced=false
      for name in pending.sorted() where dependencies[name]!.isSubset(of:Set(resolved.keys)) {
        do{resolved[name]=try CADExpression.evaluate(expressions[name]!.expression,variables:resolved)}
        catch{throw CADModelError("Derived expression '\(name)' failed: \(error.localizedDescription)")}
        pending.remove(name);advanced=true
      }
      guard advanced else{throw CADModelError("Derived expressions contain a cycle: \(pending.sorted().joined(separator:", ")).")}
    }
    return resolved
  }
}

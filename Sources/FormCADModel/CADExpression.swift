import Foundation

/// Bounded numeric arithmetic and conventional math. No scripts or file access.
public enum CADExpression {
  public static func validName(_ name:String)->Bool {
    guard !name.isEmpty,name.utf8.count<=64,name != "pi",name != "tau",let first=name.utf8.first,(65...90).contains(first)||(97...122).contains(first)||first==95 else{return false}
    return name.utf8.allSatisfy{(65...90).contains($0)||(97...122).contains($0)||(48...57).contains($0)||$0==95}
  }
  public static func evaluate(_ expression:String,variables:[String:Double])throws->Double {
    guard expression.utf8.count>0,expression.utf8.count<=256 else{throw CADModelError("Keep each CAD expression within 256 bytes.")}
    var p=Parser(bytes:Array(expression.utf8),variables:variables);let value=try p.add(0);p.space();guard p.i==p.bytes.count,value.isFinite,abs(value)<=1e7 else{throw CADModelError("CAD expression is invalid, non-finite or outside ±10,000,000.")};return value
  }
  /// Uses the same bounded parser as evaluation, without evaluating math domains.
  public static func referencedNames(in expression:String)throws->Set<String> {
    guard !expression.isEmpty,expression.utf8.count<=256 else{throw CADModelError("Keep each CAD expression within 256 bytes.")}
    var parser=Parser(bytes:Array(expression.utf8),variables:[:],referencesOnly:true)
    _ = try parser.add(0);parser.space()
    guard parser.i==parser.bytes.count else{throw CADModelError("Invalid CAD expression syntax.")}
    return parser.references
  }
  private struct Parser {
    let bytes:[UInt8],variables:[String:Double];var referencesOnly=false,references=Set<String>();var i=0,tokens=0
    mutating func space(){while i<bytes.count,[UInt8(9),10,13,32].contains(bytes[i]){i+=1}}
    mutating func take(_ c:UInt8)->Bool{space();if i<bytes.count,bytes[i]==c{i+=1;return true};return false}
    mutating func add(_ depth:Int)throws->Double{var v=try multiply(depth+1);while true{if take(43){v+=try multiply(depth+1)}else if take(45){v-=try multiply(depth+1)}else{return v}}}
    mutating func multiply(_ depth:Int)throws->Double{var v=try atom(depth+1);while true{if take(42){v*=try atom(depth+1)}else if take(47){let d=try atom(depth+1);guard d != 0 || referencesOnly else{throw CADModelError("CAD expression divides by zero.")};v=d==0 ? 1:v/d}else{return v}}}
    mutating func atom(_ depth:Int)throws->Double{
      tokens+=1;guard depth<=64,tokens<=256 else{throw CADModelError("CAD expression is too deeply nested or complex.")}
      space();if take(43){return try atom(depth+1)};if take(45){return -(try atom(depth+1))};if take(40){let v=try add(depth+1);guard take(41) else{throw CADModelError("Close the CAD expression's parentheses.")};return v}
      let start=i
      if i<bytes.count,((65...90).contains(bytes[i])||(97...122).contains(bytes[i])||bytes[i]==95){
        i+=1;while i<bytes.count,((65...90).contains(bytes[i])||(97...122).contains(bytes[i])||(48...57).contains(bytes[i])||bytes[i]==95){i+=1}
        let name=String(decoding:bytes[start..<i],as:UTF8.self)
        if take(40){
          var arguments:[Double]=[]
          if !take(41){
            repeat {guard arguments.count<3 else{throw CADModelError("CAD math functions accept at most three arguments.")};arguments.append(try add(depth+1))} while take(44)
            guard take(41) else{throw CADModelError("Close the CAD function's parentheses.")}
          }
          return try function(name,arguments)
        }
        if name=="pi"{return .pi};if name=="tau"{return 2 * .pi}
        references.insert(name);if referencesOnly{return 1}
        guard let value=variables[name],value.isFinite else{throw CADModelError("Unknown CAD parameter '\(name)'.")};return value
      }
      while i<bytes.count,((48...57).contains(bytes[i])||bytes[i]==46){i+=1}
      if i<bytes.count,(bytes[i]==101||bytes[i]==69){i+=1;if i<bytes.count,(bytes[i]==43||bytes[i]==45){i+=1};while i<bytes.count,(48...57).contains(bytes[i]){i+=1}}
      guard i>start,let value=Double(String(decoding:bytes[start..<i],as:UTF8.self)),value.isFinite else{throw CADModelError("Use numbers, parameter names, arithmetic and supported CAD math functions.")};return value
    }
    private func function(_ name:String,_ a:[Double])throws->Double {
      let one:Set<String>=["abs","sqrt","sin","cos","tan","asin","acos","atan","floor","ceil","round","radians","degrees"]
      let two:Set<String>=["min","max","pow","atan2","hypot"]
      let expected=one.contains(name) ? 1:two.contains(name) ? 2:name=="clamp" ? 3:0
      guard expected>0,a.count==expected else{throw CADModelError("Unknown CAD math function or wrong argument count: '\(name)'.")}
      if referencesOnly{return 1}
      let value:Double
      switch name {
      case "abs":value=abs(a[0])
      case "sqrt":value=sqrt(a[0])
      case "sin":value=sin(a[0])
      case "cos":value=cos(a[0])
      case "tan":value=tan(a[0])
      case "asin":value=asin(a[0])
      case "acos":value=acos(a[0])
      case "atan":value=atan(a[0])
      case "floor":value=floor(a[0])
      case "ceil":value=ceil(a[0])
      case "round":value=a[0].rounded()
      case "radians":value=a[0] * .pi / 180
      case "degrees":value=a[0] * 180 / .pi
      case "min":value=min(a[0],a[1])
      case "max":value=max(a[0],a[1])
      case "pow":value=pow(a[0],a[1])
      case "atan2":value=atan2(a[0],a[1])
      case "hypot":value=hypot(a[0],a[1])
      case "clamp":guard a[1]<=a[2] else{throw CADModelError("CAD clamp minimum exceeds maximum.")};value=min(a[2],max(a[1],a[0]))
      default:throw CADModelError("Unsupported CAD math function.")
      }
      guard value.isFinite,abs(value)<=1e7 else{throw CADModelError("CAD math function '\(name)' is outside its finite domain or coordinate bounds.")};return value
    }
  }
}

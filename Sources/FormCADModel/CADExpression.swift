import Foundation

/// Bounded arithmetic only. No functions, evaluation APIs, scripts or file access.
public enum CADExpression {
  public static func validName(_ name:String)->Bool {
    guard !name.isEmpty,name.utf8.count<=64,name != "pi",name != "tau",let first=name.utf8.first,(65...90).contains(first)||(97...122).contains(first)||first==95 else{return false}
    return name.utf8.allSatisfy{(65...90).contains($0)||(97...122).contains($0)||(48...57).contains($0)||$0==95}
  }
  public static func evaluate(_ expression:String,variables:[String:Double])throws->Double {
    guard expression.utf8.count>0,expression.utf8.count<=256 else{throw CADModelError("Keep each CAD expression within 256 bytes.")}
    var p=Parser(bytes:Array(expression.utf8),variables:variables);let value=try p.add(0);p.space();guard p.i==p.bytes.count,value.isFinite,abs(value)<=1e7 else{throw CADModelError("CAD expression is invalid, non-finite or outside ±10,000,000.")};return value
  }
  private struct Parser {
    let bytes:[UInt8],variables:[String:Double];var i=0,tokens=0
    mutating func space(){while i<bytes.count,[UInt8(9),10,13,32].contains(bytes[i]){i+=1}}
    mutating func take(_ c:UInt8)->Bool{space();if i<bytes.count,bytes[i]==c{i+=1;return true};return false}
    mutating func add(_ depth:Int)throws->Double{var v=try multiply(depth+1);while true{if take(43){v+=try multiply(depth+1)}else if take(45){v-=try multiply(depth+1)}else{return v}}}
    mutating func multiply(_ depth:Int)throws->Double{var v=try atom(depth+1);while true{if take(42){v*=try atom(depth+1)}else if take(47){let d=try atom(depth+1);guard d != 0 else{throw CADModelError("CAD expression divides by zero.")};v/=d}else{return v}}}
    mutating func atom(_ depth:Int)throws->Double{
      tokens+=1;guard depth<=64,tokens<=256 else{throw CADModelError("CAD expression is too deeply nested or complex.")}
      space();if take(43){return try atom(depth+1)};if take(45){return -(try atom(depth+1))};if take(40){let v=try add(depth+1);guard take(41) else{throw CADModelError("Close the CAD expression's parentheses.")};return v}
      let start=i
      if i<bytes.count,((65...90).contains(bytes[i])||(97...122).contains(bytes[i])||bytes[i]==95){i+=1;while i<bytes.count,((65...90).contains(bytes[i])||(97...122).contains(bytes[i])||(48...57).contains(bytes[i])||bytes[i]==95){i+=1};let name=String(decoding:bytes[start..<i],as:UTF8.self);if name=="pi"{return .pi};if name=="tau"{return 2 * .pi};guard let value=variables[name],value.isFinite else{throw CADModelError("Unknown CAD parameter '\(name)'.")};return value}
      while i<bytes.count,((48...57).contains(bytes[i])||bytes[i]==46){i+=1}
      if i<bytes.count,(bytes[i]==101||bytes[i]==69){i+=1;if i<bytes.count,(bytes[i]==43||bytes[i]==45){i+=1};while i<bytes.count,(48...57).contains(bytes[i]){i+=1}}
      guard i>start,let value=Double(String(decoding:bytes[start..<i],as:UTF8.self)),value.isFinite else{throw CADModelError("Use numbers, parameter names, parentheses and + − × ÷ in CAD expressions.")};return value
    }
  }
}

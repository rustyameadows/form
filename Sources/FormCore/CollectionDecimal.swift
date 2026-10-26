import Foundation

/// Exact bounded decimal arithmetic. Human inputs never use Foundation's
/// permissive partial parser and arithmetic errors never round silently.
public enum CollectionDecimal {
  public static let inputMaximum = Decimal(string:"1000000000000")!
  public static let aggregateMaximum = Decimal(string:"1000000000000000000")!
  private static let locale = Locale(identifier:"en_US_POSIX")
  private static let inputPattern=try! NSRegularExpression(pattern:"^(0|[1-9][0-9]{0,12})(\\.[0-9]{1,12})?$")
  private static let resolvedPattern=try! NSRegularExpression(pattern:"^(0|[1-9][0-9]*)(\\.[0-9]+)?$")
  private static let currencyPattern=try! NSRegularExpression(pattern:"^[A-Z]{3}$")
  private static func matches(_ pattern:NSRegularExpression,_ value:String)->Bool {let range=NSRange(location:0,length:value.utf16.count);return pattern.firstMatch(in:value,range:range)?.range==range}
  public static func string(_ value:Decimal)->String {var value=value;return NSDecimalString(&value,locale)}
  private static func normalized(_ text:String)->String {
    var parts=text.split(separator:".",omittingEmptySubsequences:false).map(String.init)
    if parts.count==2 {while parts[1].last=="0" {parts[1].removeLast()};if parts[1].isEmpty {parts.removeLast()}}
    return parts.joined(separator:".")
  }
  public static func parse(_ text:String)throws->Decimal {
    guard text.utf8.count<=26,matches(inputPattern,text),
      let value=Decimal(string:text,locale:locale),!value.isNaN,value>=0,value<=inputMaximum,
      normalized(string(value))==normalized(text) else{throw FormError.invalid("Use a complete nonnegative decimal, at most 12 fractional digits and a value no greater than 1,000,000,000,000. Exponents, partial values and precision loss are not accepted.")}
    return value
  }
  private static func expanded(_ text:String)->String {
    let p=text.lowercased().split(separator:"e").map(String.init)
    guard p.count==2,let exponent=Int(p[1]) else{return normalized(text)}
    let m=p[0].split(separator:".",omittingEmptySubsequences:false),digits=m.joined(),position=m[0].count+exponent
    if position<=0 {return normalized("0."+String(repeating:"0",count:-position)+digits)}
    if position>=digits.count {return normalized(digits+String(repeating:"0",count:position-digits.count))}
    var result=digits;result.insert(".",at:result.index(result.startIndex,offsetBy:position));return normalized(result)
  }
  public static func computed(_ value:Double)throws->String {
    if value==0 {return "0"}
    guard value.isFinite,value>=0,let result=Decimal(string:String(value),locale:locale),!result.isNaN,result<=aggregateMaximum,normalized(string(result))==expanded(String(value)) else{throw FormError.invalid("Computed collection quantity is nonfinite or exceeds its bound.")}
    // The shortest round-trip source decimal is itself recorded in the packet.
    return string(result)
  }
  public static func resolved(_ text:String)throws->Decimal {
    guard text.utf8.count<=64,matches(resolvedPattern,text),
      let value=Decimal(string:text,locale:locale),!value.isNaN,value>=0,value<=aggregateMaximum,
      normalized(string(value))==normalized(text) else{throw FormError.invalid("A recorded computed decimal is out of bounds or loses precision.")};return value
  }
  private static func checked(_ status:Decimal.CalculationError,_ value:Decimal)throws->Decimal {
    guard status == .noError,!value.isNaN,value>=0,value<=aggregateMaximum else{throw FormError.invalid("Collection decimal arithmetic exceeds its exact precision or aggregate bound; no rounded value was used.")};return value
  }
  private static func digits(_ value:Decimal)->(digits:[Int],scale:Int) {
    let p=string(value).split(separator:".",omittingEmptySubsequences:false)
    return ((p.joined()).compactMap{$0.wholeNumberValue},p.count==2 ? p[1].count:0)
  }
  private static func formatted(_ digits:[Int],scale:Int)->String {
    var text=digits.map(String.init).joined()
    while text.count<=scale {text="0"+text}
    if scale>0 {text.insert(".",at:text.index(text.endIndex,offsetBy:-scale))}
    while text.first=="0",text.count>1,text[text.index(after:text.startIndex)] != "." {text.removeFirst()}
    return normalized(text)
  }
  private static func exactProduct(_ a:Decimal,_ b:Decimal)->String {
    let x=digits(a),y=digits(b),u=Array(x.digits.reversed()),v=Array(y.digits.reversed());var out=[Int](repeating:0,count:u.count+v.count+1)
    for i in u.indices {for j in v.indices {out[i+j]+=u[i]*v[j]}}
    for i in 0..<(out.count-1) {out[i+1]+=out[i]/10;out[i]%=10}
    while out.count>1,out.last==0 {out.removeLast()}
    return formatted(out.reversed(),scale:x.scale+y.scale)
  }
  private static func exactSum(_ a:Decimal,_ b:Decimal)->String {
    let x=digits(a),y=digits(b),scale=max(x.scale,y.scale)
    let u=Array((x.digits+[Int](repeating:0,count:scale-x.scale)).reversed()),v=Array((y.digits+[Int](repeating:0,count:scale-y.scale)).reversed())
    var out:[Int]=[],carry=0
    for i in 0..<max(u.count,v.count) {let n=(i<u.count ? u[i]:0)+(i<v.count ? v[i]:0)+carry;out.append(n%10);carry=n/10}
    if carry>0 {out.append(carry)}
    return formatted(out.reversed(),scale:scale)
  }
  public static func add(_ a:Decimal,_ b:Decimal)throws->Decimal {
    var a=a,b=b,out=Decimal();let status=NSDecimalAdd(&out,&a,&b,.plain);let value=try checked(status,out)
    guard normalized(string(value))==exactSum(a,b) else{throw FormError.invalid("Decimal addition would lose precision.")};return value
  }
  public static func multiply(_ a:Decimal,_ b:Decimal)throws->Decimal {
    var a=a,b=b,out=Decimal();let status=NSDecimalMultiply(&out,&a,&b,.plain);let value=try checked(status,out)
    guard normalized(string(value))==exactProduct(a,b) else{throw FormError.invalid("Decimal multiplication would lose precision.")};return value
  }
  public static func divide(_ a:Decimal,_ b:Decimal)throws->Decimal {
    guard b>0 else{throw FormError.invalid("A declared divisor must be positive.")}
    var a=a,b=b,out=Decimal();let status=NSDecimalDivide(&out,&a,&b,.plain);let value=try checked(status,out)
    // Foundation can return noError for a rounded recurring quotient. An exact
    // decimal-digit inverse is required as well as its calculation status.
    guard exactProduct(value,b)==normalized(string(a)) else{throw FormError.invalid("The exact quotient does not terminate within supported decimal precision; declare an explicit rate instead.")};return value
  }
  public static func product(_ a:String,_ b:String)throws->String {try string(multiply(resolved(a),resolved(b)))}
  public static func sum(_ values:[String])throws->String {try string(values.reduce(Decimal(0)){try add($0,resolved($1))})}
  public static func currency(_ value:String?)throws {if let value {guard matches(currencyPattern,value) else{throw FormError.invalid("A price requires its declared three-letter currency.")}}}
  public static func csv(_ text:String)->String {
    let leading=text.unicodeScalars.drop(while:{CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) || $0.value==0xFEFF || $0.value==0x200B})
    let unsafe=leading.first.map{"=+-@".unicodeScalars.contains($0)} == true || text.first.map{$0=="\t" || $0=="\r" || $0=="\n"} == true
    let safe=(unsafe ? "'":"")+text
    return "\""+safe.replacingOccurrences(of:"\"",with:"\"\"")+"\""
  }
}

public struct CollectionCalculation:Codable,Equatable,Sendable {
  public var numerator:String,denominator:String,result:String
  public var policyVersion=1
  public var scale=12
  public var roundingMode="half_even"
  public var rounded:Bool
  public var originalInputs:[String:String]
}
extension CollectionDecimal {
  /// Version1 estimate policy: exact integer long division followed by12-place
  /// half-even rounding. This does not depend on Foundation's rounded quotient.
  public static func estimateDivision(_ a:Decimal,_ b:Decimal,inputs:[String:String])throws->CollectionCalculation {
    guard a>=0,b>0,a<=aggregateMaximum,b<=aggregateMaximum else{throw FormError.invalid("Invalid bounded estimate division.")}
    func trim(_ s:String)->String {let t=s.drop(while:{$0=="0"});return t.isEmpty ? "0":String(t)}
    func compare(_ a:String,_ b:String)->Int {a.count==b.count ? (a==b ? 0:(a.lexicographicallyPrecedes(b) ? -1:1)):(a.count<b.count ? -1:1)}
    func subtract(_ a:String,_ b:String)->String {
      var x=Array(a.reversed()).map{$0.wholeNumberValue!};let y=Array(b.reversed()).map{$0.wholeNumberValue!};var borrow=0
      for i in x.indices {let n=x[i]-(i<y.count ? y[i]:0)-borrow;x[i]=(n+10)%10;borrow=n<0 ? 1:0};return trim(x.reversed().map(String.init).joined())
    }
    let x=digits(a),y=digits(b)
    let numerator=trim(x.digits.map(String.init).joined()+String(repeating:"0",count:y.scale+12)),denominator=trim(y.digits.map(String.init).joined()+String(repeating:"0",count:x.scale))
    guard numerator.count<=128,denominator.count<=128,denominator != "0" else{throw FormError.invalid("Estimate rational exceeds its bounded integer precision.")}
    var remainder="0",quotient=""
    for digit in numerator {remainder=trim(remainder+String(digit));var q=0;while compare(remainder,denominator)>=0 {remainder=subtract(remainder,denominator);q+=1};quotient+=String(q)}
    quotient=trim(quotient)
    // Remainders can exceed Decimal's coefficient precision. Double them as
    // decimal digits rather than parsing or rounding a large intermediate.
    var doubled:[Int]=[],carry=0
    for c in remainder.reversed() {let n=c.wholeNumberValue!*2+carry;doubled.append(n%10);carry=n/10};if carry>0 {doubled.append(carry)}
    let comparison=compare(trim(doubled.reversed().map(String.init).joined()),denominator)
    if comparison>0 || (comparison==0 && quotient.last!.wholeNumberValue!%2==1) {
      var q=Array(quotient.reversed()).map{$0.wholeNumberValue!},carry=1
      for i in q.indices {let n=q[i]+carry;q[i]=n%10;carry=n/10};if carry>0 {q.append(carry)};quotient=q.reversed().map(String.init).joined()
    }
    let result=formatted(quotient.compactMap{$0.wholeNumberValue},scale:12),value=try resolved(result)
    guard value<=aggregateMaximum else{throw FormError.invalid("Estimated amount exceeds its aggregate bound.")}
    return .init(numerator:string(a),denominator:string(b),result:result,rounded:remainder != "0",originalInputs:inputs)
  }
}

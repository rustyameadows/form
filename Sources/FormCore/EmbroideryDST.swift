import Foundation

/// Tajima DST: 512-byte legacy header; three-byte balanced-ternary movements at
/// 0.1 mm resolution. Bit layout independently implemented from the documented
/// format and checked against EmbroidePy/pyembroidery's public reader/writer.
public enum EmbroideryDST {
  public static let maximumDelta=121
  public static func record(dx:Int,dy:Int,jump:Bool = false)throws -> [UInt8] {
    guard (-121...121).contains(dx),(-121...121).contains(dy) else {throw FormError.invalid("DST movements must fit ±12.1 mm per axis.")}
    var bytes:[UInt8]=[0,0,jump ? 0x83:0x03]
    let weights=[81,27,9,3,1]
    let xBits=[(2,2,3),(1,2,3),(0,2,3),(1,0,1),(0,0,1)]
    let yBits=[(2,5,4),(1,5,4),(0,5,4),(1,7,6),(0,7,6)]
    for (input,bits) in [(dx,xBits),(-dy,yBits)] {
      var value=input
      for (index,weight) in weights.enumerated() {
        let threshold=(weight-1)/2,choice=bits[index]
        if value>threshold {bytes[choice.0] |= 1 << choice.1;value-=weight}
        else if value < -threshold {bytes[choice.0] |= 1 << choice.2;value+=weight}
      }
      guard value==0 else {throw FormError.invalid("DST coordinate encoding failed.")}
    }
    return bytes
  }
  public static func movement(_ bytes:[UInt8])throws -> (x:Int,y:Int,jump:Bool) {
    guard bytes.count==3,bytes[2]&0x03==0x03,bytes[2]&0x40==0 else {throw FormError.invalid("Expected a DST stitch/jump record.")}
    let xWeights=[(2,2,3,81),(1,2,3,27),(0,2,3,9),(1,0,1,3),(0,0,1,1)]
    let yWeights=[(2,5,4,81),(1,5,4,27),(0,5,4,9),(1,7,6,3),(0,7,6,1)]
    func decode(_ values:[(Int,Int,Int,Int)])->Int {
      values.reduce(0) {sum,item in sum+((bytes[item.0] & (1 << item.1) != 0 ? 1:0)-(bytes[item.0] & (1 << item.2) != 0 ? 1:0))*item.3}
    }
    return (decode(xWeights),-decode(yWeights),bytes[2]&0x80 != 0)
  }
  public static func data(_ program:EmbroideryProgram)throws -> Data {
    try program.validate()
    var body:[UInt8]=[],x=0,y=0,maxX=0,minX=0,maxY=0,minY=0
    func append(_ dx:Int,_ dy:Int,jump:Bool)throws {
      body += try record(dx:dx,dy:dy,jump:jump)
      x+=dx;y+=dy;maxX=max(maxX,x);minX=min(minX,x);maxY=max(maxY,y);minY=min(minY,y)
    }
    for command in program.commands {
      switch command.action {
      case .stitch,.jump:
        let dx=command.x-x,dy=command.y-y
        let steps=max(1,Int(ceil(Double(max(abs(dx),abs(dy)))/121)))
        let startX=x,startY=y
        for index in 1...steps {
          let targetX=startX+Int((Double(dx)*Double(index)/Double(steps)).rounded(.toNearestOrEven))
          let targetY=startY+Int((Double(dy)*Double(index)/Double(steps)).rounded(.toNearestOrEven))
          try append(targetX-x,targetY-y,jump:command.action == .jump)
        }
      case .trim:
        // Common three-jump trim convention. Net displacement is zero; DST has
        // no dedicated trim opcode and machine recognition varies.
        for delta in [(2,2),(-4,-4),(2,2)] {try append(delta.0,delta.1,jump:true)}
      case .colorChange:body += [0,0,0xC3]
      case .end:body += [0,0,0xF3]
      }
    }
    let label=String(program.name.unicodeScalars.map {$0.value>=32 && $0.value<=126 ? Character(String($0)):"_"}.prefix(16))
    func number(_ value:Int,_ width:Int)->String {String(repeating:" ",count:max(0,width-String(value).count))+String(value)}
    let changes=program.commands.filter {$0.action == .colorChange}.count
    var header="LA:"+label+String(repeating:" ",count:max(0,16-label.count))+"\r"
    header += "ST:"+number(body.count/3,7)+"\rCO:"+number(changes,3)+"\r"
    header += "+X:"+number(maxX,5)+"\r-X:"+number(abs(minX),5)+"\r"
    header += "+Y:"+number(abs(minY),5)+"\r-Y:"+number(maxY,5)+"\r"
    header += "AX:"+(x>=0 ? "+":"-")+number(abs(x),5)+"\rAY:"+(y<=0 ? "+":"-")+number(abs(y),5)+"\r"
    header += "MX:+    0\rMY:+    0\rPD:******\r"
    var data=Data(header.utf8);data.append(0x1A)
    guard data.count<=512 else {throw FormError.invalid("DST header exceeded its fixed size.")}
    data.append(Data(repeating:0x20,count:512-data.count));data.append(contentsOf:body)
    return data
  }
}

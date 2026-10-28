import Foundation
import CoreGraphics
import ImageIO
import FormMeshAssets

/// Original synthetic assets authored for interchange tests; no supplier/product geometry is implied.
enum MeshAssetFixtures {
  struct Builder {
    var binary=Data(),views:[[String:Any]]=[],accessors:[[String:Any]]=[],meshes:[[String:Any]]=[]
    mutating func accessor(_ values:[Float],type:String,dimensions:Int)->Int {
      while binary.count%4 != 0 {binary.append(0)};let offset=binary.count
      for value in values {var bits=value.bitPattern.littleEndian;withUnsafeBytes(of:&bits){binary.append(contentsOf:$0)}}
      let view=views.count;views.append(["buffer":0,"byteOffset":offset,"byteLength":binary.count-offset]);let index=accessors.count
      accessors.append(["bufferView":view,"componentType":5126,"count":values.count/dimensions,"type":type]);return index
    }
    mutating func indices(_ values:[UInt32])->Int {
      while binary.count%4 != 0 {binary.append(0)};let offset=binary.count
      for value in values {var bits=value.littleEndian;withUnsafeBytes(of:&bits){binary.append(contentsOf:$0)}}
      let view=views.count;views.append(["buffer":0,"byteOffset":offset,"byteLength":binary.count-offset]);let index=accessors.count
      accessors.append(["bufferView":view,"componentType":5125,"count":values.count,"type":"SCALAR"]);return index
    }
    mutating func primitive(points:[Float],normals:[Float]?=nil,uv:[Float]?=nil,indices:[UInt32],material:Int?=nil)->[String:Any] {
      var attrs:[String:Any]=["POSITION":accessor(points,type:"VEC3",dimensions:3)]
      if let normals {attrs["NORMAL"]=accessor(normals,type:"VEC3",dimensions:3)}
      if let uv {attrs["TEXCOORD_0"]=accessor(uv,type:"VEC2",dimensions:2)}
      var result:[String:Any]=["attributes":attrs,"indices":self.indices(indices),"mode":4]
      if let material {result["material"]=material};return result
    }
    mutating func root(nodes:[[String:Any]],materials:[[String:Any]]=[],images:[[String:Any]]=[],textures:[[String:Any]]=[])->[String:Any] {
      ["asset":["version":"2.0","generator":"LAB original interchange fixtures"],"buffers":[["byteLength":binary.count]],"bufferViews":views,"accessors":accessors,"meshes":meshes,"nodes":nodes,"scenes":[["nodes":[0]]],"scene":0,"materials":materials,"images":images,"textures":textures]
    }
  }
  static func glb(_ json:[String:Any],binary:Data)->Data {
    var js=try! JSONSerialization.data(withJSONObject:json,options:[.sortedKeys]);while js.count%4 != 0 {js.append(0x20)}
    var bin=binary;while bin.count%4 != 0 {bin.append(0)}
    var result=Data()
    func word(_ value:UInt32) {var value=value.littleEndian;withUnsafeBytes(of:&value){result.append(contentsOf:$0)}}
    word(0x46546c67);word(2);word(UInt32(12+8+js.count+8+bin.count));word(UInt32(js.count));word(0x4e4f534a);result.append(js);word(UInt32(bin.count));word(0x004e4942);result.append(bin);return result
  }
  static func triangle()->(json:[String:Any],binary:Data) {
    var b=Builder();let p=b.primitive(points:[0,0,0, 0.04,0,0, 0,0.03,0],normals:[0,0,1,0,0,1,0,0,1],uv:[0,0,1,0,0,1],indices:[0,1,2],material:0);b.meshes=[["name":"Triangle","primitives":[p]]]
    return(b.root(nodes:[["name":"Scene root","children":[1]],["name":"Triangle part","mesh":0]],materials:[["name":"Ivory","pbrMetallicRoughness":["baseColorFactor":[0.9,0.8,0.6,1],"metallicFactor":0,"roughnessFactor":0.7]]]),b.binary)
  }
  static func cube()->(json:[String:Any],binary:Data) {
    var b=Builder();let p=b.primitive(points:[0,0,0, 0.04,0,0, 0.04,0.03,0, 0,0.03,0, 0,0,0.02, 0.04,0,0.02, 0.04,0.03,0.02, 0,0.03,0.02],indices:[0,2,1,0,3,2, 4,5,6,4,6,7, 0,1,5,0,5,4, 3,7,6,3,6,2, 0,4,7,0,7,3, 1,2,6,1,6,5]);b.meshes=[["name":"Device","primitives":[p]]]
    return(b.root(nodes:[["name":"Device assembly","children":[1,2]],["name":"Device front","mesh":0,"translation":[0.1,0.2,0.3]],["name":"Device instance","mesh":0,"translation":[-0.1,0,0],"scale":[2,1,1]]]),b.binary)
  }
  static func texture(normal:Bool=false)->Data {
    let width=16,height=16;var pixels=[UInt8](repeating:255,count:width*height*4)
    for y in 0..<height {for x in 0..<width {let i=(y*width+x)*4;if normal {pixels[i]=UInt8(128+(x%4==0 ? 12:0));pixels[i+1]=UInt8(128+(y%4==0 ? 12:0));pixels[i+2]=253}else{let v=UInt8((x%4==0 || y%4==0) ? 104:76);pixels[i]=v;pixels[i+1]=v+8;pixels[i+2]=v+22}}}
    let bytes=Data(pixels),provider=CGDataProvider(data:bytes as CFData)!,space=CGColorSpace(name:CGColorSpace.sRGB)!
    let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
    let data=NSMutableData(),destination=CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil)!;CGImageDestinationAddImage(destination,image,nil);precondition(CGImageDestinationFinalize(destination));return data as Data
  }
  static func jacket(radial:Int=128,rows:Int=64)->(json:[String:Any],binary:Data) {
    var b=Builder(),nodes:[[String:Any]]=[["name":"LAB synthetic flight jacket","children":Array(1...9)]]
    func tube(center:(Double)->SIMD3<Double>,radii:(Double)->SIMD2<Double>,axis:Int=1,wrinkle:Double=0.002)->(p:[Float],uv:[Float],i:[UInt32]) {
      var p:[Float]=[],uv:[Float]=[],indices:[UInt32]=[]
      for row in 0...rows {let t=Double(row)/Double(rows),c=center(t),r=radii(t)
        for col in 0...radial {let u=Double(col)/Double(radial),angle=u*Double.pi*2,wave=wrinkle*sin(t*Double.pi*22+sin(angle*4))*sin(t*Double.pi),rx=r.x+wave,rz=r.y+wave;let point:SIMD3<Double>
          if axis==0 {point=c+SIMD3<Double>(0,rx*cos(angle),rz*sin(angle))}else{point=c+SIMD3<Double>(rx*cos(angle),0,rz*sin(angle))}
          p += [Float(point.x),Float(point.y),Float(point.z)];uv += [Float(u*4),Float(t*4)]
          if row<rows,col<radial {let a=UInt32(row*(radial+1)+col),d=UInt32((row+1)*(radial+1)+col);indices += [a,d,a+1,a+1,d,d+1]}
        }
      };return(p,uv,indices)
    }
    func add(_ name:String,_ data:(p:[Float],uv:[Float],i:[UInt32]),_ material:Int) {
      let points=stride(from:0,to:data.p.count,by:3).map{MeshPoint3(Double(data.p[$0]),Double(data.p[$0+1]),Double(data.p[$0+2]))};let normals=MeshAssetGeometry.vertexNormals(points:points,indices:data.i).flatMap{[$0.x,$0.y,$0.z]};let p=b.primitive(points:data.p,normals:normals,uv:data.uv,indices:data.i,material:material);let i=b.meshes.count;b.meshes.append(["name":name,"primitives":[p]]);nodes.append(["name":name,"mesh":i])
    }
    add("Shell / curved torso",tube(center:{.init(0,$0*0.58,0)},radii:{t in .init(0.22+0.055*sin(t*Double.pi*0.8),0.105+0.02*sin(t*Double.pi))}),0)
    add("Left sleeve",tube(center:{t in .init(-0.25-0.34*t,0.49-0.24*t,0)},radii:{t in .init(0.075-0.025*t,0.075-0.025*t)},axis:0),0)
    add("Right sleeve",tube(center:{t in .init(0.25+0.34*t,0.49-0.24*t,0)},radii:{t in .init(0.075-0.025*t,0.075-0.025*t)},axis:0),0)
    add("Waist rib band",tube(center:{.init(0,-0.025+$0*0.06,0)},radii:{t in .init(0.223+0.001*sin(t*Double.pi*40),0.108)},wrinkle:0),1)
    add("Collar rib band",tube(center:{.init(0,0.56+$0*0.045,0)},radii:{t in .init(0.16+0.001*sin(t*Double.pi*35),0.1)},wrinkle:0),1)
    add("Left cuff",tube(center:{.init(-0.59-$0*0.055,0.25,0)},radii:{t in .init(0.05+0.001*cos(t*Double.pi*40),0.052)},axis:0,wrinkle:0),1)
    add("Right cuff",tube(center:{.init(0.59+$0*0.055,0.25,0)},radii:{t in .init(0.05+0.001*cos(t*Double.pi*40),0.052)},axis:0,wrinkle:0),1)
    add("Front zipper",(p:[-0.005,0.04,0.13, 0.005,0.04,0.13, 0.005,0.56,0.13, -0.005,0.56,0.13],uv:[0,0,1,0,1,1,0,1],i:[0,1,2,0,2,3]),2)
    add("Separate chest patch",(p:[0.07,0.35,0.13, 0.15,0.35,0.13, 0.15,0.42,0.13, 0.07,0.42,0.13],uv:[0,0,1,0,1,1,0,1],i:[0,1,2,0,2,3]),3)
    let materials:[[String:Any]]=[
      ["name":"Woven midnight shell","doubleSided":true,"pbrMetallicRoughness":["baseColorTexture":["index":0],"metallicFactor":0,"roughnessFactor":0.48],"normalTexture":["index":1]],
      ["name":"Graphite rib","doubleSided":true,"pbrMetallicRoughness":["baseColorFactor":[0.06,0.07,0.08,1],"metallicFactor":0,"roughnessFactor":0.9]],
      ["name":"Zipper metal","doubleSided":true,"pbrMetallicRoughness":["baseColorFactor":[0.64,0.66,0.7,1],"metallicFactor":0.9,"roughnessFactor":0.25]],
      ["name":"Separate orange patch","doubleSided":true,"pbrMetallicRoughness":["baseColorFactor":[0.8,0.19,0.04,1],"metallicFactor":0,"roughnessFactor":0.8]]]
    let images:[[String:Any]]=[["name":"Original woven pixels","uri":"data:image/png;base64,"+texture().base64EncodedString()],["name":"Original weave normal","uri":"data:image/png;base64,"+texture(normal:true).base64EncodedString()]]
    return(b.root(nodes:nodes,materials:materials,images:images,textures:[["source":0],["source":1]]),b.binary)
  }
}

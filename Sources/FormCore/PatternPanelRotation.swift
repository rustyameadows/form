import Foundation
import simd

extension PatternPanelPose {
  /// Degrees about world X/Y/Z, composed Rz*Ry*Rx on the material's +X/-Y
  /// basis. This editor representation never introduces scale or skew.
  public var eulerDegrees:Vector3 {
    let u=ClothMath.vector(uAxis),up = -ClothMath.vector(vAxis),n=simd_cross(u,up),y=asin(max(-1,min(1,-u.z)))
    let x:Double,z:Double
    if abs(cos(y))>1e-8 {x=atan2(up.z,n.z);z=atan2(u.y,u.x)}
    else {x=atan2(-n.y,up.y);z=0}
    return .init(x*180/Double.pi,y*180/Double.pi,z*180/Double.pi)
  }
  public mutating func setEulerDegrees(_ value:Vector3) {
    let x=value.x*Double.pi/180,y=value.y*Double.pi/180,z=value.z*Double.pi/180
    let cx=cos(x),sx=sin(x),cy=cos(y),sy=sin(y),cz=cos(z),sz=sin(z)
    uAxis = .init(cy*cz,cy*sz,-sy)
    vAxis = .init(-(cz*sy*sx-sz*cx),-(sz*sy*sx+cz*cx),-cy*sx)
  }
}

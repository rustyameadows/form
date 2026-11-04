import Darwin
import Foundation
import XCTest
@testable import FormCore

final class LocalBridgeReadingTests:XCTestCase {
  private let limit=8*1024*1024
  /// Write fragments concurrently so the actual AF_UNIX stream's finite send
  /// buffer, partial reads and EOF participate in every framing assertion.
  private func receive(_ frame:Data,fragments:[Int]=[16_384],file:StaticString=#filePath,line:UInt=#line)throws->Data {
    var descriptors=[Int32](repeating:-1,count:2)
    guard socketpair(AF_UNIX,SOCK_STREAM,0,&descriptors)==0 else{throw FormError.invalid("Could not create test socket pair.")}
    let reader=descriptors[0],writer=descriptors[1]
    var noSignal:Int32=1
    var timeout=timeval(tv_sec:5,tv_usec:0)
    for fd in descriptors {
      setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
      setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
      setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
    }
    let finished=DispatchSemaphore(value:0)
    DispatchQueue.global(qos:.userInitiated).async {
      defer{shutdown(writer,SHUT_WR);finished.signal()}
      frame.withUnsafeBytes{buffer in
        var offset=0,index=0
        while offset<frame.count {
          let size=min(fragments[index%fragments.count],frame.count-offset)
          var sent=0
          while sent<size {
            let count=Darwin.write(writer,buffer.baseAddress!.advanced(by:offset+sent),size-sent)
            if count<0 {if errno==EINTR{continue};return}
            if count==0{return}
            sent+=count
          }
          offset+=size;index+=1
        }
      }
    }
    defer {
      shutdown(reader,SHUT_RDWR);shutdown(writer,SHUT_RDWR)
      XCTAssertEqual(finished.wait(timeout:.now()+10),.success,"Socket writer must finish even when the reader rejects a frame.",file:file,line:line)
      close(reader);close(writer)
    }
    return try readMessage(reader)
  }
  func testActualUnixServerAndClientRoundTripPreservesMultiMegabyteProjectResponse()throws {
    let path="/tmp/lab-large-read-"+UUID().uuidString+".sock",server=LocalBridgeServer(path:path)
    let payload=String(repeating:"x",count:4_433_280)+" / café 🌿"
    try server.start{name,arguments,completion in
      completion(.success(["tool":name,"nonce":arguments["nonce"] ?? 0,"project_snapshot":payload]))
    }
    defer{server.stop()}
    let started=Date()
    let value=try XCTUnwrap(LocalBridgeClient.call("form_get_project",arguments:["nonce":37],socketPath:path) as? [String:Any])
    XCTAssertEqual(value["tool"] as? String,"form_get_project");XCTAssertEqual(value["nonce"] as? Int,37)
    XCTAssertEqual(value["project_snapshot"] as? String,payload)
    print("LocalBridgeReadingTests actual AF_UNIX multi-megabyte JSON response: payloadUTF8=\(payload.utf8.count), elapsed=\(Date().timeIntervalSince(started))s; no timing threshold")
  }
  func testFragmentedUnicodeAndFirstLineFramingRetainExactBytesAndIgnoreTrailingLines()throws {
    let payload=Data((String(repeating:"registered source / ",count:2000)+"café 🌿").utf8)
    var frame=payload;frame.append(10);frame.append(contentsOf:Data("discarded second line\n".utf8))
    XCTAssertEqual(try receive(frame,fragments:[1,2,7,16_383,3,16_384]),payload)
    XCTAssertEqual(try receive(Data("first\nsecond\n".utf8),fragments:[1]),Data("first".utf8))
    XCTAssertEqual(try receive(Data([10]),fragments:[1]),Data(),"An empty terminated frame remains distinct from empty EOF.")
  }
  func testNonemptyEOFIsAcceptedEmptyEOFAndReadFailuresRemainErrors()throws {
    let payload=Data("A complete frame without a line terminator 🌿".utf8)
    XCTAssertEqual(try receive(payload,fragments:[1,3,8]),payload)
    XCTAssertThrowsError(try receive(Data())){error in XCTAssertTrue(error.localizedDescription.contains("Empty or oversized"))}
    XCTAssertThrowsError(try readMessage(-1)){error in XCTAssertTrue(error.localizedDescription.contains("read failed"))}
  }
  func testExactEightMiBPayloadAcceptedAndOneExtraByteRejectedWithEitherEOFOrNewline()throws {
    let payload=Data(repeating:97,count:limit)
    for newline in [false,true] {
      var exact=payload;if newline{exact.append(10)}
      XCTAssertEqual(try receive(exact,fragments:[16_384,13,8192,3]),payload)
      var oversized=payload;oversized.append(98);if newline{oversized.append(10)}
      XCTAssertThrowsError(try receive(oversized,fragments:[16_384])){error in
        XCTAssertTrue(error.localizedDescription.contains("oversized"))
      }
    }
  }
  func testOversizedTerminatorInSameReadCannotBypassLimitAndSmallFirstLineIgnoresLargeTail()throws {
    // A regular file gives deterministic16KiB read boundaries: the final read
    // contains the first oversized byte and LF together. The old early-LF path
    // returned it before checking the bound. Actual stream behavior is covered
    // by the socket-pair and complete client/server tests above.
    let file=FileManager.default.temporaryDirectory.appendingPathComponent("lab-line-bound-"+UUID().uuidString)
    var frame=Data(repeating:97,count:limit+1);frame.append(10)
    try frame.write(to:file);defer{try? FileManager.default.removeItem(at:file)}
    let fd=Darwin.open(file.path,O_RDONLY);XCTAssertGreaterThanOrEqual(fd,0);defer{if fd>=0{close(fd)}}
    XCTAssertThrowsError(try readMessage(fd)){error in XCTAssertTrue(error.localizedDescription.contains("oversized"))}
    var first=Data("ok\n".utf8);first.append(Data(repeating:97,count:limit+1))
    XCTAssertEqual(try receive(first),Data("ok".utf8),"The cap applies to the first framed payload, not bytes after its terminator.")
  }
}

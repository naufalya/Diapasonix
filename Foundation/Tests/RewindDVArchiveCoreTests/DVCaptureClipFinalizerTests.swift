// Synthetic transport and policy regressions; not hardware qualification.
import CryptoKit
import Foundation
import Testing
@testable import RewindDVArchiveCore

private func clipFrame(_ tc: UInt8, filler: Bool, wide: Bool = false) -> Data {
  var f = ingestFrame(pal: false)
  for at in stride(from: 0, to: f.count, by: 80) {
    if f[at] >> 5 == 4 { f[at + 3] &= 0x0f } // Fixture starts with zero video status.
    if f[at] >> 5 == 1 {
      for slot in [6,14,22,30,38,46] {
        f.replaceSubrange((at + slot)..<(at + slot + 5), with: [0x13,tc,0,0,0])
      }
    }
    if f[at] >> 5 == 2 {
      let packs: [[UInt8]] = filler
        ? [[0x60,0xff,0xff,0x40,0xff],[0x61,0x03,wide ? 0x82 : 0x81,0xfc,0xff],[0x62,0xff,0xff,0xff,0xff],[0x63,0xff,0xff,0xff,0xff]]
        : [[0x60,0xff,0xff,0x00,0xff],[0x61,0x3f,0x81,0xfc,0xff],[0x62,0xff,0x01,0x01,0x24],[0x63,0xff,0,0,0]]
      for (index, pack) in packs.enumerated() {
        let start = at + 3 + index * 5; f.replaceSubrange(start..<(start + 5), with: pack)
      }
    }
  }
  return f
}
private var syntheticClipProfile: DVCaptureClipFinalizer.Profile {
  var hash = SHA256(); let frame = clipFrame(1, filler: true)
  for at in stride(from: 0, to: frame.count, by: 80) where frame[at] >> 5 == 4 {
    hash.update(data: frame.subdata(in: (at + 3)..<(at + 80)))
  }
  return .init(name: "synthetic-only", videoSHA256: hash.finalize().map { String(format: "%02x",$0) }.joined())
}
private func clipFixture(_ frames: [Data], validStop: Bool = true, wrongRoute: Bool = false,
                         latePlay: Bool = false, missingTimebase: Bool = false) throws -> IngestFixture {
  let fixture = try IngestFixture(packets: frames.flatMap { ingestPackets($0) })
  let journalURL = fixture.url.appendingPathComponent("flight.ndjson")
  var events = try Data(contentsOf: journalURL).split(separator: 10).map {
    try JSONSerialization.jsonObject(with: Data($0)) as! [String:Any]
  }
  for index in events.indices { events[index]["omittedTransportDiagnostics"] = 0 }
  if !missingTimebase { events[0]["message"] = "raw_host_ticks_timebase_numerator=1; raw_host_ticks_timebase_denominator=1" }
  let route = Data(base64Encoded: events[0]["wireBase64"] as! String)!
  let play: UInt64 = latePlay ? 1 : 30_000, stop = UInt64(frames.count - 2) * 25_000 - 1000
  func event(_ kind: String, _ time: UInt64, _ message: String, _ wire: Data = Data()) -> [String:Any] {
    var e = events[0]; e["event"] = kind; e["hostUptimeNanoseconds"] = time
    e["message"] = message; e["wireBase64"] = wire.base64EncodedString(); return e
  }
  func response(_ request: UInt64, _ play: Bool) -> Data {
    var w = Data(repeating: 0, count: 1284)
    for (at,value) in [(0,UInt32(1)),(4,1284),(112,1),(116,5),(136,4),(120,0x7f),(124,3),(140,1),(152,1),(212,1),(220,3),(224,4)] {
      ingestPut(value,into:&w,at:at)
    }
    ingestPut(request,into:&w,at:8); ingestPut(UInt64(1),into:&w,at:64)
    for at in [16,24,80,104,196] { ingestPut(UInt64(1),into:&w,at:at) }
    ingestPut(UInt16(7),into:&w,at:148)
    w.replaceSubrange(188..<192,with:[0x01,0x20,0xd0,0x7f])
    ingestPut(UInt64(1),into:&w,at:204); ingestPut(UInt16(7),into:&w,at:216)
    w.replaceSubrange(32..<64,with:route[8..<40])
    if wrongRoute { w[32] ^= 1 }
    w.replaceSubrange(228..<232,with:play ? [0x0c,0x20,0xc3,0x75] : [validStop ? 0x0c : 0x0b,0x20,0xc4,0x60])
    return w
  }
  var inserted = [event("transport_command_submission",play,"command=Play tape; operation_id=1; attempt_id=1"),
    event("transport_command_result",play + 100,"command=Play tape; operation_id=1; attempt_id=1; protocol_accepted=true"),
    event("transport_status_observed",play + 200,"",response(1,true)),
    event("transport_status_observed",play + 300,"",response(2,true)),
    event("transport_command_submission",stop,"command=Stop tape; operation_id=2; attempt_id=2"),
    event("transport_command_result",stop + 100,"command=Stop tape; operation_id=2; attempt_id=2; protocol_accepted=true"),
    event("transport_status_observed",stop + 200,"",response(3,false)),
    event("transport_status_observed",stop + 300,"",response(4,false)),
    event("receive_stop_intent",UInt64(frames.count) * 25_000 + 1000,"")]
  events[events.count - 1]["hostUptimeNanoseconds"] = UInt64(frames.count) * 25_000 + 2000
  inserted.insert(events.removeFirst(),at:0); inserted.append(contentsOf:events)
  var journal = Data()
  for e in inserted { journal.append(try JSONSerialization.data(withJSONObject:e)); journal.append(10) }
  try journal.write(to:journalURL); return fixture
}
private func withClip(_ frames: [Data], validStop: Bool = true, wrongRoute: Bool = false,
                      latePlay: Bool = false, missingTimebase: Bool = false,
                      _ body: (IngestFixture,DVIngestVerification) throws -> Void) throws {
  let f = try clipFixture(frames, validStop: validStop, wrongRoute: wrongRoute,
    latePlay: latePlay, missingTimebase: missingTimebase)
  defer { f.cleanup() }
  try body(f,DVIngestExporter.exportClosedFlight(at:f.url))
}
private let clipEdges = [clipFrame(1,filler:true,wide:true),clipFrame(1,filler:true,wide:true),
                         clipFrame(0x10,filler:false),clipFrame(0x11,filler:false),
                         clipFrame(0x12,filler:false),clipFrame(0x13,filler:false),
                         clipFrame(0x20,filler:true),clipFrame(0x20,filler:true)]

@Test(arguments: [true,false]) func captureClipKeepsConflictingRecordedBoundaryBytes(_ leading: Bool) throws {
  var frames = clipEdges
  let n = leading ? 2 : 5
  frames[n].replaceSubrange(86..<91,with:[0x13,leading ? 0x09 : 0x14,0,0,0])
  let facts = try DVCaptureClipFinalizer.Facts(frames[n],profile:syntheticClipProfile)
  #expect(facts.timecode == nil && facts.ordinal == nil)
  #expect(facts.cameraMetadata && !facts.camera)
  try withClip(frames) { fixture,v in
    let originals = try Data(contentsOf:fixture.url.appendingPathComponent("capture.dv"))
    let r = try DVCaptureClipFinalizer.finalize(at:fixture.url,verification:v,deckName:"Sony HVR-M15U",deckGUID:8,
      destination:fixture.url.appendingPathComponent("Clip"),profile:syntheticClipProfile)
    let receipt = try #require(r.receipt), url = try #require(r.clipURL)
    #expect(receipt.firstSourceFrameOrdinal == 2 && receipt.endSourceFrameOrdinalExclusive == 6)
    #expect(try Data(contentsOf:url) == originals.subdata(in:240_000..<720_000))
    #expect(try Data(contentsOf:fixture.url.appendingPathComponent("capture.dv")) == originals)
    let preserved = try Data(contentsOf:url).subdata(in:(leading ? 0 : 360_000)..<(leading ? 120_000 : 480_000))
    #expect(preserved == frames[n])
    #expect(try DVCaptureClipFinalizer.Facts(preserved,profile:syntheticClipProfile).timecode == nil)
  }
}

@Test(arguments: [true,false], [0,1,2,3,4,5,6,7,8]) func captureClipRefusesUnboundedConflictingCameraBoundary(_ leading: Bool, _ failure: Int) throws {
  var frames = clipEdges
  let boundary = leading ? 2 : 5, adjacent = leading ? 3 : 4
  frames[boundary].replaceSubrange(86..<91,with:[0x13,leading ? 0x09 : 0x14,0,0,0])
  if failure == 0 { frames[boundary].replaceSubrange(86..<91,with:[0x13,leading ? 0x07 : 0x16,0,0,0]) }
  if failure == 1 { frames[boundary].replaceSubrange(86..<91,with:[0x13,leading ? 0x49 : 0x54,0,0,0]) }
  if failure == 2 { frames[boundary].replaceSubrange(86..<91,with:[0x13,0x0a,0,0,0]) }
  if failure == 3 { frames[boundary].replaceSubrange(94..<99,with:[0x13,leading ? 0x08 : 0x15,0,0,0]) }
  if failure == 4 { frames[adjacent] = clipFrame(leading ? 0x15 : 0x09,filler:false) }
  if failure == 5 { frames[adjacent].replaceSubrange(86..<91,with:[0x13,leading ? 0x10 : 0x11,0,0,0]) }
  if failure == 6 || failure == 7 {
    for at in stride(from:0,to:frames[boundary].count,by:80) where frames[boundary][at] >> 5 == 2 {
      let offset = failure == 6 ? 8 : 13
      frames[boundary].replaceSubrange((at+offset)..<(at+offset+5),with:failure == 6
        ? [0x61,0xff,0xff,0xff,0xff] : [0x62,0xff,0xff,0xff,0xff])
    }
  }
  if failure == 8 {
    for at in stride(from:0,to:frames[boundary].count,by:80) where frames[boundary][at] >> 5 == 1 {
      for slot in [6,14,22,30,38,46] {
        frames[boundary].replaceSubrange((at+slot)..<(at+slot+5),with:[0xff,0xff,0xff,0xff,0xff])
      }
    }
  }
  try withClip(frames) { fixture,v in
    let r = try DVCaptureClipFinalizer.finalize(at:fixture.url,verification:v,deckName:"Sony HVR-M15U",deckGUID:8,
      destination:fixture.url.appendingPathComponent("Clip"),profile:syntheticClipProfile)
    #expect(r.receipt == nil)
    #expect(r.clipURL == fixture.url.appendingPathComponent("capture.dv"))
  }
}

@Test func captureClipExcludesOnlyBoundedFillerAndPreservesOriginalsAndTimecode() throws {
  try withClip(clipEdges) { fixture,v in
    let paths = ["capture.dv","receive.records.raw","flight.ndjson","frames.ndjson","verification.json"]
    let originals = try paths.map { try Data(contentsOf:fixture.url.appendingPathComponent($0)) }
    let result = try DVCaptureClipFinalizer.finalize(at:fixture.url,verification:v,
      deckName:"Sony HVR-M15U",deckGUID:8,destination:fixture.url.appendingPathComponent("Clip"),profile:syntheticClipProfile)
    let receipt = try #require(result.receipt), url = try #require(result.clipURL)
    #expect(receipt.firstSourceFrameOrdinal == 2 && receipt.endSourceFrameOrdinalExclusive == 6)
    #expect(receipt.exportedFrameCount == 4)
    #expect(receipt.outputFile == "capture.dv")
    #expect(receipt.captureCleanup?.kept.firstByte == 240_000)
    #expect(receipt.captureCleanup?.excludedLeading?.endFrameExclusive == 2)
    #expect(receipt.captureCleanup?.excludedTrailing?.firstFrame == 6)
    #expect(!receipt.timecodeRewritten && !receipt.bytesReencoded && !receipt.audioResampled)
    let saved = try Data(contentsOf:url), expected = clipEdges[2..<6].reduce(into:Data()) { $0.append($1) }
    #expect(saved == expected)
    for (index,path) in paths.enumerated() {
      #expect(try Data(contentsOf:fixture.url.appendingPathComponent(path)) == originals[index])
    }
    #expect(throws:(any Error).self) {
      try DVCaptureClipFinalizer.finalize(at:fixture.url,verification:v,deckName:"Sony HVR-M15U",deckGUID:8,
        destination:fixture.url.appendingPathComponent("Clip"),profile:syntheticClipProfile)
    }
  }
}

@Test func captureClipRetainsInteriorFillerAndLegitimateRecordedGray() throws {
  var frames = clipEdges
  frames.insert(clipFrame(0x21,filler:true),at:4)
  frames.insert(clipFrame(0x21,filler:true),at:5)
  try withClip(frames) { fixture,v in
    let r = try DVCaptureClipFinalizer.finalize(at:fixture.url,verification:v,deckName:"Sony HVR-M15U",deckGUID:8,
      destination:fixture.url.appendingPathComponent("Clip"),profile:syntheticClipProfile)
    let receipt = try #require(r.receipt), url = try #require(r.clipURL)
    #expect(receipt.firstSourceFrameOrdinal == 2 && receipt.endSourceFrameOrdinalExclusive == 8)
    #expect(try Data(contentsOf:url) == frames[2..<8].reduce(into:Data()) { $0.append($1) })
  }
  let recordedGray = (0..<8).map { clipFrame(UInt8($0),filler:false) }
  try withClip(recordedGray) { fixture,v in
    let r = try DVCaptureClipFinalizer.finalize(at:fixture.url,verification:v,deckName:"Sony HVR-M15U",deckGUID:8,
      destination:fixture.url.appendingPathComponent("Clip"),profile:syntheticClipProfile)
    #expect(r.receipt == nil)
    #expect(r.clipURL == fixture.url.appendingPathComponent("capture.dv"))
  }
}

@Test(arguments:[0,1,2]) func captureClipRequiresFreshSameRouteStableStopAndKnownTimebase(_ failure:Int) throws {
  try withClip(clipEdges,validStop:failure != 0,wrongRoute:failure == 1,missingTimebase:failure == 2) { fixture,v in
    let r = try DVCaptureClipFinalizer.finalize(at:fixture.url,verification:v,deckName:"Sony HVR-M15U",deckGUID:8,
      destination:fixture.url.appendingPathComponent("Clip"),profile:syntheticClipProfile)
    #expect(r.receipt == nil)
    #expect(!FileManager.default.fileExists(atPath:fixture.url.appendingPathComponent("Clip").path))
  }
}

@Test func captureClipNeverUsesHeldTCMissingDatesLineSourceOrColorAlone() throws {
  var altered = clipEdges
  for n in [0,1,6,7] { altered[n][7 * 80 + 4] ^= 1 } // Different compressed video signature.
  try withClip(altered) { fixture,v in
    let r = try DVCaptureClipFinalizer.finalize(at:fixture.url,verification:v,deckName:"Sony HVR-M15U",deckGUID:8,
      destination:fixture.url.appendingPathComponent("Clip"),profile:syntheticClipProfile)
    #expect(r.receipt == nil)
  }
  try withClip(clipEdges) { fixture,v in
    let r = try DVCaptureClipFinalizer.finalize(at:fixture.url,verification:v,
      deckName:"Other deck",deckGUID:8,destination:fixture.url.appendingPathComponent("Clip"))
    #expect(r.receipt == nil)
  }
  try withClip(Array(repeating:clipFrame(1,filler:true),count:8)) { fixture,v in
    let r = try DVCaptureClipFinalizer.finalize(at:fixture.url,verification:v,deckName:"Sony HVR-M15U",deckGUID:8,
      destination:fixture.url.appendingPathComponent("Clip"),profile:syntheticClipProfile)
    #expect(r.receipt == nil)
  }
}

@Test func captureClipRefusesAlteredEvidenceAndWrongDeckIdentity() throws {
  try withClip(clipEdges) { fixture,v in
    #expect(throws:(any Error).self) {
      try DVCaptureClipFinalizer.finalize(at:fixture.url,verification:v,deckName:"Sony HVR-M15U",deckGUID:9,
        destination:fixture.url.appendingPathComponent("Clip"),profile:syntheticClipProfile)
    }
    let path = fixture.url.appendingPathComponent("frames.ndjson")
    var data = try Data(contentsOf:path); data[12] ^= 1; try data.write(to:path)
    #expect(throws:(any Error).self) {
      try DVCaptureClipFinalizer.finalize(at:fixture.url,verification:v,deckName:"Sony HVR-M15U",deckGUID:8,
        destination:fixture.url.appendingPathComponent("Clip"),profile:syntheticClipProfile)
    }
    #expect(!FileManager.default.fileExists(atPath:fixture.url.appendingPathComponent("Clip").path))
  }
}

@Test func captureClipPublicationHookFailureKeepsDerivativeIncomplete() throws {
  try withClip(clipEdges) { fixture,_ in
    let source = fixture.url.appendingPathComponent("capture.dv")
    let snapshot = try DVReviewedRangeExporter.inspect(source:source)
    let destination = fixture.url.appendingPathComponent("Interrupted")
    #expect(throws:(any Error).self) {
      try DVReviewedRangeExporter.export(source:source,snapshot:snapshot,first:2,endExclusive:6,
        destination:destination,beforePublication:{ throw CocoaError(.fileWriteUnknown) })
    }
    #expect(!FileManager.default.fileExists(atPath:destination.appendingPathComponent("provenance.json").path))
    #expect(!FileManager.default.fileExists(atPath:destination.appendingPathComponent("reviewed-range.dv").path))
    #expect(FileManager.default.fileExists(atPath:source.path))
  }
}

@Test(arguments: [0,1,2,3,4,5,6]) func captureClipRejectsLateReusedOrUncorrelatedTransportProof(_ failure:Int) throws {
  let fixture = try clipFixture(clipEdges); defer { fixture.cleanup() }
  let url = fixture.url.appendingPathComponent("flight.ndjson")
  var events = try Data(contentsOf:url).split(separator:10).map {
    try JSONSerialization.jsonObject(with:Data($0)) as! [String:Any]
  }
  for index in events.indices where events[index]["event"] as? String == "transport_status_observed" {
    var wire = Data(base64Encoded:events[index]["wireBase64"] as! String)!
    let play = wire[230] == 0xc3
    if failure == 0 && play { events[index]["hostUptimeNanoseconds"] = UInt64(180_000) }
    if failure == 1 && !play { events[index]["hostUptimeNanoseconds"] = UInt64(202_000) }
    if failure == 2 && !play { ingestPut(UInt64(1),into:&wire,at:8) }
    if failure == 3 { ingestPut(UInt32(3),into:&wire,at:116) }
    if failure == 4 { events[index]["omittedTransportDiagnostics"] = 1 }
    if failure == 6 { events[index].removeValue(forKey:"omittedTransportDiagnostics") }
    events[index]["wireBase64"] = wire.base64EncodedString()
  }
  if failure == 5 {
    var missingTime = events[1]
    missingTime.removeValue(forKey:"hostUptimeNanoseconds")
    missingTime["message"] = "command=Play tape; operation_id=3; attempt_id=3"
    events.insert(missingTime,at:2)
  }
  var bytes = Data()
  for e in events { bytes.append(try JSONSerialization.data(withJSONObject:e)); bytes.append(10) }
  try bytes.write(to:url)
  let v = try DVIngestExporter.exportClosedFlight(at:fixture.url)
  let r = try DVCaptureClipFinalizer.finalize(at:fixture.url,verification:v,deckName:"Sony HVR-M15U",deckGUID:8,
    destination:fixture.url.appendingPathComponent("Clip"),profile:syntheticClipProfile)
  #expect(r.receipt == nil)
}

@Test func captureClipRejectsCorruptDIFBeforeMetadataIndexing() throws {
  var frame = clipFrame(1,filler:true); frame[81] = 0xf7
  #expect(throws:(any Error).self) { try DVCaptureClipFinalizer.Facts(frame,profile:syntheticClipProfile) }
}

@Test func captureClipRetainsUnboundedEdgesAndUnknownRecordedCore() throws {
  try withClip(clipEdges,latePlay:true) { fixture,v in
    let r = try DVCaptureClipFinalizer.finalize(at:fixture.url,verification:v,deckName:"Sony HVR-M15U",deckGUID:8,
      destination:fixture.url.appendingPathComponent("Clip"),profile:syntheticClipProfile)
    #expect(r.receipt == nil)
  }
  var frames = clipEdges
  for n in [2,3,4,5] {
    for at in stride(from:0,to:frames[n].count,by:80) where frames[n][at] >> 5 == 2 {
      frames[n].replaceSubrange((at+8)..<(at+13),with:[0x61,0xff,0xff,0xff,0xff])
    }
  }
  try withClip(frames) { fixture,v in
    let r = try DVCaptureClipFinalizer.finalize(at:fixture.url,verification:v,deckName:"Sony HVR-M15U",deckGUID:8,
      destination:fixture.url.appendingPathComponent("Clip"),profile:syntheticClipProfile)
    #expect(r.receipt == nil)
  }
}

private func clipVideoStatus(_ frame: Data, _ status: UInt8, blocks: Int = 1350) -> Data {
  var result = frame, count = 0
  for at in stride(from: 0, to: result.count, by: 80) where result[at] >> 5 == 4 {
    result[at + 3] = (count < blocks ? status << 4 : 0) | (result[at + 3] & 15)
    count += 1
  }
  return result
}

@Test func captureClipExcludesExplicitVideoStatusBoundaryWithoutRepairingSource() throws {
  var frames = clipEdges.map { clipVideoStatus($0, 0) }
  frames[2] = clipVideoStatus(frames[2], 0x0a, blocks: 682)
  try withClip(frames) { fixture, v in
    let paths = ["capture.dv", "receive.records.raw", "flight.ndjson", "frames.ndjson", "verification.json"]
    let before = try paths.map { try Data(contentsOf: fixture.url.appendingPathComponent($0)) }
    let r = try DVCaptureClipFinalizer.finalize(at: fixture.url, verification: v,
      deckName: "Sony HVR-M15U", deckGUID: 8, destination: fixture.url.appendingPathComponent("Clip"), profile: syntheticClipProfile)
    let receipt = try #require(r.receipt), exclusion = try #require(receipt.captureCleanup?.excludedLeadingVideoStatus)
    #expect(receipt.firstSourceFrameOrdinal == 3 && receipt.exportedFrameCount == 3)
    #expect(exclusion.extent.firstFrame == 2 && exclusion.extent.endFrameExclusive == 3)
    #expect(exclusion.statusCode == 0x0a && exclusion.affectedVideoBlocks == 682)
    #expect(try Data(contentsOf: #require(r.clipURL)) == frames[3..<6].reduce(into: Data()) { $0.append($1) })
    #expect(r.message.contains("2 startup") && r.message.contains("1 source-flagged boundary"))
    for (index, path) in paths.enumerated() {
      #expect(try Data(contentsOf: fixture.url.appendingPathComponent(path)) == before[index])
    }
    let encoded = try JSONEncoder().encode(#require(receipt.captureCleanup))
    #expect(try JSONDecoder().decode(DVCaptureCleanupEvidence.self, from: encoded) == receipt.captureCleanup)
    // Receipts written before this additive field remain readable.
    var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    old.removeValue(forKey: "excludedLeadingVideoStatus")
    #expect(try JSONDecoder().decode(DVCaptureCleanupEvidence.self,
      from: JSONSerialization.data(withJSONObject: old)).excludedLeadingVideoStatus == nil)
  }
}

@Test(arguments: 0..<7) func captureClipDoesNotBroadenVideoStatusExclusion(_ scenario: Int) throws {
  var frames = clipEdges.map { clipVideoStatus($0, 0) }
  frames[2] = clipVideoStatus(frames[2], 0x0a, blocks: 682)
  if scenario == 0 { frames[2] = clipVideoStatus(frames[2], 0x0b) } // Unknown status.
  if scenario == 1 { frames[3] = clipVideoStatus(frames[3], 0x0a) } // More than one flagged edge frame.
  if scenario == 2 { frames[4] = clipVideoStatus(frames[4], 0x0a) } // Not two clean successors.
  if scenario == 3 { frames[2] = clipVideoStatus(frames[2], 0); frames[4] = clipVideoStatus(frames[4], 0x0a) } // Interior.
  if scenario == 4 { frames[2] = clipVideoStatus(frames[2], 0); frames[5] = clipVideoStatus(frames[5], 0x0a) } // Trailing boundary.
  if scenario == 5 { frames[2].replaceSubrange(86..<91, with: [0x13, 0x09, 0, 0, 0]) } // Conflicting source TC.
  if scenario == 6 { frames[2] = clipVideoStatus(clipFrame(0x09, filler: false), 0x0a) } // Nonconsecutive TC.
  try withClip(frames) { fixture, v in
    let r = try DVCaptureClipFinalizer.finalize(at: fixture.url, verification: v,
      deckName: "Sony HVR-M15U", deckGUID: 8, destination: fixture.url.appendingPathComponent("Clip"), profile: syntheticClipProfile)
    #expect(r.receipt?.captureCleanup?.excludedLeadingVideoStatus == nil)
    #expect(r.receipt?.firstSourceFrameOrdinal != 3)
    if let receipt = r.receipt {
      #expect(receipt.firstSourceFrameOrdinal == 2)
      #expect(try Data(contentsOf: #require(r.clipURL)) == frames[2..<6].reduce(into: Data()) { $0.append($1) })
    }
  }
}

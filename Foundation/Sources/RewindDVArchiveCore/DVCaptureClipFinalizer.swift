// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

/// A presentation decision about preserved bytes, never an acquisition-loss
/// claim. The received native DV, raw packets and frame ledger remain intact.
public struct DVCaptureCleanupEvidence: Codable, Equatable, Sendable {
  public struct Extent: Codable, Equatable, Sendable {
    public let firstFrame: UInt64
    public let endFrameExclusive: UInt64
    public let firstByte: UInt64
    public let endByteExclusive: UInt64
    public let conservativeRawStart: UInt64
    public let conservativeRawEndExclusive: UInt64
  }
  /// A viewing-only exclusion of one received camera frame carrying the
  /// observed Sony STA=0xA status. This is not idle filler or repaired media.
  public struct VideoStatusExclusion: Codable, Equatable, Sendable {
    public let extent: Extent
    public let statusCode: UInt8
    public let affectedVideoBlocks: Int
  }
  /// Subset of excludedLeading, not an additional disjoint omitted range.
  public let excludedLeadingVideoStatus: VideoStatusExclusion?
  public let profile: String
  public let evidenceClass: String
  public let deckName: String
  public let deckGUID: UInt64
  public let routeBase64: String
  public let rawRecordSHA256: String
  public let journalSHA256: String
  public let frameManifestSHA256: String
  public let kept: Extent
  public let excludedLeading: Extent?
  public let excludedTrailing: Extent?
  public let playSubmissionNanoseconds: UInt64
  public let stopSubmissionNanoseconds: UInt64
  public let policy: String
}

/// Offline finalization of the default viewing clip. Recognition is deliberately
/// limited to an empirically observed NTSC Sony HVR-M15U idle-output signature,
/// same-route transport evidence, and an advancing recorded camera core. Pixel
/// color, absent dates, LINE source and repeated numbering are insufficient alone.
public enum DVCaptureClipFinalizer {
  public struct Result: Sendable {
    public let clipURL: URL?
    public let receipt: DVReviewedRangeExporter.Receipt?
    public let message: String
  }
  struct Profile: Sendable {
    let name: String
    let videoSHA256: String
    static let sonyNTSC = Profile(name: "sony-hvr-m15u-ntsc-idle-v1",
      videoSHA256: "66370862b4423a53a7ad485c2d549945ea3100106e2a8972479b8f826b843540")
  }
  /// Requires the authoritative result of DVIngestExporter for this closed
  /// flight. Caller-supplied flags are not independent capture qualification.
  public static func finalize(at directory: URL, verification: DVIngestVerification,
                              deckName: String, deckGUID: UInt64,
                              destination: URL? = nil) throws -> Result {
    let name = deckName.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard name == "SONY HVR-M15U" else {
      return unchanged(directory, verification, "No tested filler profile for this deck; all received frames retained.")
    }
    return try finalize(at: directory, verification: verification, deckName: deckName,
      deckGUID: deckGUID, destination: destination ?? directory.appendingPathComponent("Finalized Clip"), profile: .sonyNTSC)
  }

  static func finalize(at directory: URL, verification v: DVIngestVerification,
                       deckName: String, deckGUID: UInt64, destination: URL,
                       profile: Profile) throws -> Result {
    guard v.captureFile == "capture.dv", let sourceSHA = v.nativeDVSHA256,
      v.integritySHA256Verified, v.nativeDVRereadVerified, v.finalAcknowledgementConfirmed,
      !v.legacyStoppedSnapshotUsed, !v.busResetTerminated, v.knownDroppedPackets == 0,
      v.rejectedPackets == 0, v.rawTransportGapEvents == 0 else {
      return unchanged(directory, v, "Capture evidence is uncertain; automatic filler exclusion was not applied.")
    }
    guard let status = Data(base64Encoded: v.finalStatusWireBase64), status.count == 128 else {
      throw invalid("missing final receive route")
    }
    let route = status.subdata(in: 24..<72)
    guard integer(route, 8, UInt64.self) == deckGUID else { throw invalid("cleanup deck differs from received route") }
    let epoch = integer(status, 16, UInt64.self)
    let source = directory.appendingPathComponent("capture.dv")
    let snapshot = try DVReviewedRangeExporter.inspect(source: source)
    guard snapshot.sourceSHA256 == sourceSHA, snapshot.sourceByteCount == v.dvBytes,
      snapshot.frameCount == v.completeDVFrames else { throw invalid("native source differs from verification") }
    guard snapshot.videoSystem == .ntsc525_60, snapshot.frameByteCount == 120_000 else {
      return unchanged(directory, v, "The tested filler profile requires uniform NTSC DV25; original retained.")
    }

    let native = try DVReviewedRangeExporter.RegularSource(source)
    defer { native.close() }
    let rawURL = directory.appendingPathComponent("receive.records.raw")
    let raw = try DVReviewedRangeExporter.RegularSource(rawURL)
    defer { raw.close() }
    let journalURL = directory.appendingPathComponent("flight.ndjson")
    let journal = try DVReviewedRangeExporter.RegularSource(journalURL)
    defer { journal.close() }
    let ledgerURL = directory.appendingPathComponent(v.frameManifestFile)
    let ledger = try DVReviewedRangeExporter.RegularSource(ledgerURL)
    defer { ledger.close() }
    guard try raw.readExactly(8) == Data("RDRXLOG1".utf8) else { throw invalid("raw header") }
    let rawHash = try raw.hashToEOF()
    guard rawHash.bytes == v.rawRecordBytes, rawHash.sha256 == v.rawRecordSHA256 else { throw invalid("raw hash") }
    var context = TransportContext(route: route)
    let journalHash = try lines(journal) { context.consume(try JSONDecoder().decode(Event.self, from: $0)) }
    guard journalHash == v.journalSHA256 else { throw invalid("journal hash") }
    guard let transport = context.bound else {
      return unchanged(directory, v, "No unambiguous same-route PLAY/STOP evidence; original retained.")
    }

    var leading: UInt64 = 0, trailing: UInt64 = 0, count: UInt64 = 0
    var leadingTC: Data?, trailingTC: Data?
    var leadingConsistent = true, trailingConsistent = true
    var firstCore: [Facts] = [], lastCore: [Facts] = []
    var lastCoreOrdinal: UInt64?
    var digest = SHA256()
    while count < snapshot.frameCount {
      let frame = try native.readExactly(120_000); digest.update(data: frame)
      let facts = try Facts(frame, profile: profile)
      if facts.filler {
        if count == leading {
          if let leadingTC, leadingTC != facts.timecode { leadingConsistent = false }
          leadingTC = facts.timecode; leading += 1
        }
        if trailing == 0 { trailingTC = facts.timecode; trailingConsistent = true }
        else if trailingTC != facts.timecode { trailingConsistent = false }
        trailing += 1
      } else {
        if lastCoreOrdinal != count - (count > 0 ? 1 : 0) { lastCore.removeAll(keepingCapacity: true) }
        lastCore.append(facts); if lastCore.count > 3 { lastCore.removeFirst() }
        lastCoreOrdinal = count; trailing = 0; trailingTC = nil
      }
      if count >= leading, firstCore.count < 3 { firstCore.append(facts) }
      count += 1
    }
    guard hex(digest.finalize()) == sourceSHA, try native.isAtEOF() else { throw invalid("source changed during classification") }
    // No all-gray/unknown-core inference. Original media remains available for
    // review; never claim an empty tape or hide an uncertain source recording.
    guard leading < count, cameraBoundary(firstCore, leading: true), cameraBoundary(lastCore, leading: false) else {
      return unchanged(directory, v, "No confidently identified advancing recorded core; original retained for review.")
    }
    // Keep the policy narrow: one flagged camera frame directly after the
    // already identified idle prefix, followed by two clean, advancing camera
    // frames. Never scan inward for a prettier image or remove interior errors.
    let boundary = firstCore.first
    let omitFlaggedBoundary = leading >= 2 && firstCore.count == 3 &&
      boundary?.observedSonyVideoStatus == true &&
      firstCore.dropFirst().allSatisfy { $0.nonzeroVideoStatusBlocks == 0 } &&
      cameraAdvances(Array(firstCore.prefix(2))) && cameraAdvances(Array(firstCore.suffix(2)))
    let viewingFirst = leading + (omitFlaggedBoundary ? 1 : 0)
    var entries: [UInt64: Entry] = [:]
    let wanted: Set<UInt64> = [0, count - 1, leading, viewingFirst, leading > 0 ? leading - 1 : 0,
                              count - trailing, count - trailing > 0 ? count - trailing - 1 : 0]
    var ledgerCount: UInt64 = 0
    let ledgerHash = try lines(ledger) { line in
      let entry = try JSONDecoder().decode(Entry.self, from: line)
      guard entry.frameOrdinal == ledgerCount, entry.fileByteOffset == ledgerCount * 120_000,
        entry.byteCount == 120_000, entry.receiveEpoch == epoch,
        entry.routeWireBase64 == route.base64EncodedString(),
        entry.rawIntervalStartByteOffset >= 8,
        entry.rawIntervalEndByteOffsetExclusive <= raw.byteCount,
        entry.rawIntervalStartByteOffset < entry.rawIntervalEndByteOffsetExclusive else { throw invalid("frame ledger coordinates") }
      if wanted.contains(ledgerCount) { entries[ledgerCount] = entry }
      ledgerCount += 1
    }
    guard ledgerCount == count, ledgerHash == v.frameManifestSHA256 else { throw invalid("frame ledger identity") }
    func hostTime(_ entry: Entry) throws -> UInt64 {
      let header = try pread(raw.fd, at: entry.rawIntervalStartByteOffset, count: 64)
      guard integer(header, 8, UInt64.self) == epoch,
        integer(header, 0, UInt64.self) == entry.firstRecordSequence else { throw invalid("raw frame anchor") }
      let ticks = integer(header, 16, UInt64.self)
      let product = ticks.multipliedReportingOverflow(by: transport.numerator)
      guard !product.overflow, transport.denominator > 0 else { throw invalid("host time conversion") }
      return product.partialValue / transport.denominator
    }
    var first: UInt64 = 0, end = count
    if leading >= 2, leadingConsistent, let anchor = entries[0],
      try hostTime(anchor) < transport.play { first = leading }
    if trailing >= 2, trailingConsistent, let anchor = entries[count - trailing],
      try hostTime(anchor) >= transport.stop { end = count - trailing }
    guard (leading == 0 || first == leading), (trailing == 0 || end == count - trailing) else {
      return unchanged(directory, v, "Idle-like edge frames lack a complete consistent transport bound; original retained for review.")
    }
    // The transport/idle guards above must pass before extending the viewing
    // prefix. Nonzero source status alone never establishes a transport edge.
    if omitFlaggedBoundary { first = viewingFirst }
    guard first < end, first > 0 || end < count else {
      return unchanged(directory, v, "No confidently bounded transport filler; all received frames retained.")
    }
    func extent(_ a: UInt64, _ b: UInt64) throws -> DVCaptureCleanupEvidence.Extent {
      guard let start = entries[a], let finish = entries[b - 1] else { throw invalid("missing cleanup extent") }
      return .init(firstFrame: a, endFrameExclusive: b, firstByte: a * 120_000,
        endByteExclusive: b * 120_000, conservativeRawStart: start.rawIntervalStartByteOffset,
        conservativeRawEndExclusive: finish.rawIntervalEndByteOffsetExclusive)
    }
    let videoStatusExclusion: DVCaptureCleanupEvidence.VideoStatusExclusion? = omitFlaggedBoundary
      ? .init(extent: try extent(leading, viewingFirst), statusCode: 0x0a,
              affectedVideoBlocks: boundary!.nonzeroVideoStatusBlocks) : nil
    let evidence = DVCaptureCleanupEvidence(excludedLeadingVideoStatus: videoStatusExclusion, profile: profile.name, evidenceClass: "EMPIRICAL_EVIDENCE; tested Sony NTSC idle output, not a universal blank-frame rule",
      deckName: deckName, deckGUID: deckGUID, routeBase64: route.base64EncodedString(),
      rawRecordSHA256: v.rawRecordSHA256, journalSHA256: v.journalSHA256,
      frameManifestSHA256: v.frameManifestSHA256, kept: try extent(first, end),
      excludedLeading: first == 0 ? nil : try extent(0, first),
      excludedTrailing: end == count ? nil : try extent(end, count),
      playSubmissionNanoseconds: transport.play, stopSubmissionNanoseconds: transport.stop,
      policy: "Only outer contiguous matching idle-signature frames with held validated source timecode, unset recording clocks, same-route accepted PLAY/STOP and fresh stable status pairs, and a recorded advancing camera core are excluded from this viewing derivative. One retained boundary frame may have exactly two valid adjacent same-mode timecode labels with matching flags and known camera metadata, bounded immediately by two consensus advancing camera frames beyond both labels. That frame is copied unchanged and its conflicting timecode remains unknown; neither candidate is selected. One immediately following camera frame with observed STA=0xA may also be excluded from the viewing prefix when its timecode advances into two consecutive zero-STA camera frames. Its separate extent and status count are recorded; the cause of its source status remains unknown. Zero STA is not proof of pristine content. No interior removal, re-encoding, timecode repair or original deletion. Frame n maps to original kept.firstFrame+n; raw intervals are conservative, with exact per-frame mapping in the original hash-bound ledger. Raw host times describe driver drain, not exact wire/tape presentation. Source quality and physical continuity remain unknown.")
    func revalidate() throws {
      try native.requireStableAndCurrentPath(source)
      for (reader, url, expected) in [(journal, journalURL, v.journalSHA256), (ledger, ledgerURL, v.frameManifestSHA256)] {
        try reader.rewind(); guard try reader.hashToEOF().sha256 == expected else { throw invalid("cleanup evidence changed") }
        try reader.requireStableAndCurrentPath(url)
      }
      try raw.rewind(); _ = try raw.readExactly(8)
      guard try raw.hashToEOF().sha256 == v.rawRecordSHA256 else { throw invalid("raw evidence changed") }
      try raw.requireStableAndCurrentPath(rawURL)
    }
    try revalidate()
    let receipt = try DVReviewedRangeExporter.export(source: source, snapshot: snapshot,
      first: first, endExclusive: end, destination: destination,
      captureCleanup: evidence, beforePublication: revalidate)
    guard let file = receipt.outputFile else { throw invalid("unexpected split viewing output") }
    let statusMessage = omitFlaggedBoundary
      ? " Also excluded 1 source-flagged boundary frame from viewing (video status 0xA; cause unverified)." : ""
    return Result(clipURL: destination.appendingPathComponent(file), receipt: receipt,
      message: "Finalized clip: \(end - first) frames. Excluded \(leading) startup and \(count - end) shutdown filler frames.\(statusMessage) Complete original receive retained; source picture quality remains unverified.")
  }

  private static func unchanged(_ directory: URL, _ v: DVIngestVerification, _ message: String) -> Result {
    Result(clipURL: v.captureFile.map { directory.appendingPathComponent($0) }, receipt: nil, message: message)
  }
  struct Facts {
    let timecode: Data?
    let ordinal: Int?
    let day: Int?
    let cameraMetadata: Bool
    let transitionLabels: (first: Int, last: Int, day: Int)?
    let camera: Bool
    let filler: Bool
    let nonzeroVideoStatusBlocks: Int
    let observedSonyVideoStatus: Bool
    init(_ frame: Data, profile: Profile) throws {
      var packs: [UInt8: Set<Data>] = [:], invalid = Set<UInt8>()
      let supported = frame.count == 120_000 && frame[4] & 7 == 0
      if supported {
        try DVReviewedRangeExporter.validateCanonicalOrder(frame, sequenceCount: 10)
        for at in stride(from: 0, to: frame.count, by: 80) {
          let section = frame[at] >> 5, seq = Int(frame[at + 1] >> 4)
          guard section == 1 || section == 2 else { continue }
          let valid = frame[seq * 12_000 + (section == 1 ? 7 : 6)] & 128 == 0
          let slots = section == 1 ? [6,14,22,30,38,46] : Array(stride(from: 3, through: 73, by: 5))
          for slot in slots {
            let i = at + slot, type = frame[i]
            guard (section == 1 && type == 0x13) || (section == 2 && (0x60...0x63).contains(type)) else { continue }
            if valid { packs[type, default: []].insert(frame.subdata(in: i..<(i + 5))) }
            else { invalid.insert(type) }
          }
        }
      }
      func pack(_ type: UInt8) -> Data? {
        guard !invalid.contains(type), let values = packs[type], values.count == 1 else { return nil }
        return values.first
      }
      var flagged = 0, onlyObservedStatus = true
      for at in stride(from: 0, to: frame.count, by: 80) where frame[at] >> 5 == 4 {
        let status = frame[at + 3] >> 4
        if status != 0 { flagged += 1; if status != 0x0a { onlyObservedStatus = false } }
      }
      nonzeroVideoStatusBlocks = flagged
      observedSonyVideoStatus = supported && flagged > 0 && onlyObservedStatus
      let tc = pack(0x13), source = pack(0x60), control = pack(0x61), date = pack(0x62), clock = pack(0x63)
      let decoded = tc.flatMap(Self.decodeTC)
      timecode = decoded == nil ? nil : tc; ordinal = decoded?.0; day = decoded?.1
      let cameraControl = control.map { p in
        p[1] == 0x3f && [UInt8(0x01),0x02,0x81,0x82].contains(p[2]) && p[3] == 0xfc && p[4] == 0xff
      } == true
      cameraMetadata = cameraControl && source == Data([0x60,0xff,0xff,0x00,0xff]) &&
        date.map(Self.validDate) == true && clock.map(Self.validClock) == true
      camera = decoded != nil && cameraMetadata
      // A boundary frame may contain two different original labels. Keep it
      // unchanged and unknown; these candidates only bound an adjacent known
      // camera pair, never choose or rewrite its timecode.
      var transition: (Int, Int, Int)?
      if !invalid.contains(0x13), let labels = packs[0x13], labels.count == 2 {
        let values = Array(labels)
        let flags = { (p: Data) in Data([p[1] & 0xc0,p[2] & 0x80,p[3] & 0x80,p[4] & 0xc0]) }
        if flags(values[0]) == flags(values[1]), let a = Self.decodeTC(values[0]),
          let b = Self.decodeTC(values[1]), a.1 == b.1 {
          if b.0 == (a.0 + 1) % a.1 { transition = (a.0,b.0,a.1) }
          else if a.0 == (b.0 + 1) % a.1 { transition = (b.0,a.0,a.1) }
        }
      }
      transitionLabels = transition
      var matches = decoded != nil && source == Data([0x60,0xff,0xff,0x40,0xff]) &&
        (control == Data([0x61,0x03,0x81,0xfc,0xff]) || control == Data([0x61,0x03,0x82,0xfc,0xff])) &&
        date == Data([0x62,0xff,0xff,0xff,0xff]) && clock == Data([0x63,0xff,0xff,0xff,0xff])
      if matches {
        var hash = SHA256()
        for at in stride(from: 0, to: frame.count, by: 80) where frame[at] >> 5 == 4 {
          hash.update(data: frame.subdata(in: (at + 3)..<(at + 80)))
        }
        matches = hex(hash.finalize()) == profile.videoSHA256
      }
      filler = matches
    }
    static func bcd(_ x: UInt8, maximum: Int, minimum: Int = 0) -> Int? {
      let n = Int(x >> 4) * 10 + Int(x & 15)
      return x & 15 < 10 && x >> 4 < 10 && (minimum...maximum).contains(n) ? n : nil
    }
    static func decodeTC(_ p: Data) -> (Int, Int)? {
      guard let f = bcd(p[1] & 63, maximum: 29), let s = bcd(p[2] & 127, maximum: 59),
        let m = bcd(p[3] & 127, maximum: 59), let h = bcd(p[4] & 63, maximum: 23) else { return nil }
      let drop = p[1] & 64 != 0, minutes = h * 60 + m
      guard !drop || m % 10 == 0 || s != 0 || f >= 2 else { return nil }
      return ((h * 3600 + m * 60 + s) * 30 + f - (drop ? 2 * (minutes - minutes / 10) : 0), drop ? 2_589_408 : 2_592_000)
    }
    static func validDate(_ p: Data) -> Bool {
      guard let y = bcd(p[4], maximum: 99), let m = bcd(p[3] & 31, maximum: 12, minimum: 1),
        let d = bcd(p[2] & 63, maximum: 31, minimum: 1) else { return false }
      return d <= [31,y % 4 == 0 ? 29 : 28,31,30,31,30,31,31,30,31,30,31][m - 1]
    }
    static func validClock(_ p: Data) -> Bool {
      bcd(p[2] & 127, maximum: 59) != nil && bcd(p[3] & 127, maximum: 59) != nil && bcd(p[4] & 63, maximum: 23) != nil
    }
  }
  private static func cameraAdvances(_ pair: [Facts]) -> Bool {
    guard pair.count == 2, pair.allSatisfy(\.camera), let a = pair[0].ordinal, let b = pair[1].ordinal,
      let day = pair[0].day, day == pair[1].day else { return false }
    return b == (a + 1) % day
  }
  private static func cameraBoundary(_ frames: [Facts], leading: Bool) -> Bool {
    let pair = leading ? Array(frames.prefix(2)) : Array(frames.suffix(2))
    if cameraAdvances(pair) { return true }
    guard frames.count == 3 else { return false }
    let boundary = leading ? frames[0] : frames[2]
    let adjacent = leading ? Array(frames.suffix(2)) : Array(frames.prefix(2))
    guard boundary.cameraMetadata, let labels = boundary.transitionLabels,
      cameraAdvances(adjacent), adjacent[0].day == labels.day else { return false }
    if leading { return adjacent[0].ordinal == (labels.last + 1) % labels.day }
    guard let previous = adjacent[1].ordinal else { return false }
    return labels.first == (previous + 1) % labels.day
  }
  private struct Entry: Decodable {
    let frameOrdinal: UInt64, fileByteOffset: UInt64, byteCount: UInt64, receiveEpoch: UInt64
    let firstRecordSequence: UInt64, rawIntervalStartByteOffset: UInt64, rawIntervalEndByteOffsetExclusive: UInt64
    let routeWireBase64: String
  }
  private struct Event: Decodable {
    let event: String
    let wireBase64: String
    let message: String?
    let hostUptimeNanoseconds: UInt64?
    let omittedTransportDiagnostics: UInt64?
  }
  private struct TransportContext {
    let route: Data
    var play: (UInt64, String, String)?, stop: (UInt64, String, String)?
    var playAccepted: UInt64?, stopAccepted: UInt64?, ambiguous = false
    var numerator: UInt64?, denominator: UInt64?
    var stablePlay: [UInt64: UInt64] = [:], stableStop: [UInt64: UInt64] = [:]
    var receiveStop: UInt64?, receiveClosed: UInt64?
    var sawStart = false
    mutating func consume(_ e: Event) {
      guard e.omittedTransportDiagnostics == 0 else { ambiguous = true; return }
      let fields = Dictionary(e.message?.split(separator: "; ").compactMap { part -> (String,String)? in
        let split = part.split(separator: "=", maxSplits: 1); return split.count == 2 ? (String(split[0]),String(split[1])) : nil
      } ?? [], uniquingKeysWith: { _, _ in "ambiguous" })
      if e.event == "receive_start_intent" {
        if sawStart || Data(base64Encoded: e.wireBase64) != route { ambiguous = true }
        sawStart = true
        numerator = fields["raw_host_ticks_timebase_numerator"].flatMap(UInt64.init)
        denominator = fields["raw_host_ticks_timebase_denominator"].flatMap(UInt64.init)
      }
      guard let time = e.hostUptimeNanoseconds, time > 0 else {
        if e.event.hasPrefix("transport_") { ambiguous = true }
        return
      }
      if e.event == "receive_stop_intent" {
        if receiveStop != nil { ambiguous = true }; receiveStop = time
      }
      if e.event == "receive_closed" {
        if receiveClosed != nil { ambiguous = true }; receiveClosed = time
      }
      if e.event == "transport_command_submission", let command = fields["command"] {
        guard let op = fields["operation_id"], let attempt = fields["attempt_id"],
          UInt64(op) != nil, UInt64(attempt) != nil else { ambiguous = true; return }
        if command == "Play tape" { if play != nil { ambiguous = true }; play = (time,op,attempt) }
        else if command == "Stop tape" { if stop != nil { ambiguous = true }; stop = (time,op,attempt) }
        else { ambiguous = true }
      }
      if e.event == "transport_command_result", fields["protocol_accepted"] == "true" {
        if fields["command"] == "Play tape", let play, fields["operation_id"] == play.1,
          fields["attempt_id"] == play.2, time > play.0 { playAccepted = time }
        if fields["command"] == "Stop tape", let stop, fields["operation_id"] == stop.1,
          fields["attempt_id"] == stop.2, time > stop.0 { stopAccepted = time }
      }
      if e.event == "transport_status_observed", let wire = Data(base64Encoded: e.wireBase64),
        let response = Self.stableResponse(wire, route: route) {
        let request = integer(wire, 8, UInt64.self)
        if response == Data([0x0c,0x20,0xc3,0x75]) { stablePlay[request] = time }
        if response == Data([0x0c,0x20,0xc4,0x60]) { stableStop[request] = time }
      }
    }
    var bound: (play: UInt64, stop: UInt64, numerator: UInt64, denominator: UInt64)? {
      guard !ambiguous, let play, let stop, let playAccepted, let stopAccepted,
        let receiveStop, let receiveClosed, stopAccepted < receiveStop, receiveStop <= receiveClosed,
        play.0 < playAccepted, playAccepted < stop.0, stop.0 < stopAccepted,
        Set(stablePlay.keys).isDisjoint(with: Set(stableStop.keys)),
        stablePlay.values.allSatisfy({ $0 > playAccepted && $0 < stop.0 }),
        stableStop.values.allSatisfy({ $0 > stopAccepted && $0 < receiveStop }),
        stablePlay.values.filter({ $0 > playAccepted && $0 < stop.0 }).count >= 2,
        stableStop.values.filter({ $0 > stopAccepted && $0 < receiveStop }).count >= 2, let numerator, let denominator,
        numerator > 0, denominator > 0 else { return nil }
      return (play.0,stop.0,numerator,denominator)
    }
    static func stableResponse(_ w: Data, route: Data) -> Data? {
      guard w.count == 1284, integer(w,0,UInt32.self) == 1, integer(w,4,UInt32.self) == 1284,
        w.subdata(in: 32..<64) == route.subdata(in: 8..<40),
        integer(w,112,UInt32.self) == integer(route,40,UInt32.self),
        integer(w,116,UInt32.self) == 5, integer(w,132,UInt32.self) == 0,
        integer(w,136,UInt32.self) == 4, integer(w,156,UInt32.self) == 0,
        integer(w,148,UInt16.self) & 63 == UInt16(route[44] & 63), w[150] == 0, w[151] == 0,
        w.subdata(in: 188..<196) == Data([0x01,0x20,0xd0,0x7f,0,0,0,0]),
        integer(w,128,UInt32.self) == 0, integer(w,144,UInt32.self) == 0,
        integer(w,152,UInt32.self) == 1, integer(w,124,UInt32.self) == 3,
        integer(w,120,UInt32.self) & 0x7b == 0x7b, integer(w,120,UInt32.self) & ~UInt32(0xff) == 0,
        integer(w,8,UInt64.self) > 0, integer(w,16,UInt64.self) > 0, integer(w,24,UInt64.self) > 0,
        integer(w,80,UInt64.self) > 0, integer(w,104,UInt64.self) >= integer(w,80,UInt64.self) else { return nil }
      let count = integer(w,140,UInt32.self)
      guard count > 0, count <= 2 else { return nil }
      let at = 196 + (Int(count) - 1) * 544
      guard integer(w,at + 24,UInt32.self) == 3, integer(w,at + 28,UInt32.self) == 4,
        integer(w,at,UInt64.self) > 0, integer(w,at + 22,UInt16.self) == 0,
        integer(w,at + 8,UInt64.self) == integer(w,64,UInt64.self), integer(w,64,UInt64.self) > 0,
        integer(w,at + 16,UInt32.self) == integer(route,40,UInt32.self),
        integer(w,at + 20,UInt16.self) & 63 == UInt16(route[44] & 63),
        w[(at + 36)..<(at + 544)].allSatisfy({ $0 == 0 }),
        w[(196 + Int(count) * 544)..<w.count].allSatisfy({ $0 == 0 }) else { return nil }
      return w.subdata(in: (at + 32)..<(at + 36))
    }
  }
  private static func lines(_ input: DVReviewedRangeExporter.RegularSource,
                            consume: (Data) throws -> Void) throws -> String {
    var buffer = Data(), digest = SHA256(), remaining = input.byteCount
    while remaining > 0 {
      let chunk = try input.readExactly(Int(min(65_536,remaining))); remaining -= UInt64(chunk.count)
      digest.update(data: chunk); buffer.append(chunk)
      while let newline = buffer.firstIndex(of: 10) {
        let line = Data(buffer[..<newline]); buffer = Data(buffer[buffer.index(after: newline)...])
        guard line.count <= 1_048_576 else { throw invalid("oversized evidence line") }
        try consume(line)
      }
      guard buffer.count <= 1_048_576 else { throw invalid("oversized evidence line") }
    }
    guard buffer.isEmpty else { throw invalid("truncated evidence line") }
    return hex(digest.finalize())
  }
  private static func pread(_ fd: Int32, at: UInt64, count: Int) throws -> Data {
    guard at <= UInt64(Int64.max) else { throw invalid("raw offset overflow") }
    var data = Data(count: count)
    let n = data.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress!, count, off_t(at)) }
    guard n == count else { throw invalid("raw anchor read") }; return data
  }
  private static func integer<T: FixedWidthInteger>(_ data: Data, _ offset: Int, _ type: T.Type) -> T {
    data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
  }
  private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }
  private static func invalid(_ reason: String) -> DVIngestError { .invalidEvidence("capture clip: " + reason) }
}

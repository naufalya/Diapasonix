import Foundation
import Testing
@testable import RewindDVControlCore

private func recoveryDirectories() throws -> (URL, URL, URL) {
  let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
  let root = base.appendingPathComponent("application/PassiveTransportFlights")
  let destination = base.appendingPathComponent("operator-archive")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
  return (base, root, destination)
}

@Test func exhaustedSessionArchivePreservesOriginalBytesAndAllowsFreshAdmission() throws {
  let (base, root, destination) = try recoveryDirectories()
  defer { try? FileManager.default.removeItem(at: base) }
  var limits = PassiveInspectorStore.Limits(); limits.sessionBytes = 64 * 1024
  let store = try PassiveInspectorStore(root: root, limits: limits)
  let flight = try InspectorFlight(compact: store)
  try flight.append(event: "raw_result", query: .tapeTransportState, route: Data([1]), result: Data([12,32,196,96]))
  try flight.finish()
  #expect(throws: (any Error).self) { try InspectorFlight(compact: store) }
  let before = try PassiveEvidenceArchive.inventory(root)
  try store.closeForArchive()
  let archive = try PassiveEvidenceArchive.move(root: root, to: destination)
  #expect(archive.fileCount == 1 && archive.bytes > 0)
  #expect(!FileManager.default.fileExists(atPath: root.path))
  #expect(try PassiveEvidenceArchive.inventory(archive.directory.appendingPathComponent("PassiveTransportFlights")) == before)
  #expect(throws: (any Error).self) { try InspectorFlight(compact: store) }
  let fresh = try PassiveInspectorStore(root: root, limits: limits)
  let next = try InspectorFlight(compact: fresh)
  try next.append(event: "new_session", query: .tapeTransportState, route: nil); try next.finish()
  #expect(try Data(contentsOf: archive.directory.appendingPathComponent("archive-receipt.json")).count > 0)
}

@Test func retainedBudgetCanRecoverEvenWhenStoreConstructionWasRefused() throws {
  let (base, root, destination) = try recoveryDirectories()
  defer { try? FileManager.default.removeItem(at: base) }
  var limits = PassiveInspectorStore.Limits(); limits.sessionBytes = 64 * 1024; limits.retainedBytes = 128 * 1024
  let original = Data(repeating: 0x61, count: limits.retainedBytes)
  try original.write(to: root.appendingPathComponent("retained.ndjson"))
  #expect(throws: (any Error).self) { try PassiveInspectorStore(root: root, limits: limits) }
  let archive = try PassiveEvidenceArchive.move(root: root, to: destination)
  #expect(try Data(contentsOf: archive.directory.appendingPathComponent("PassiveTransportFlights/retained.ndjson")) == original)
  let fresh = try PassiveInspectorStore(root: root, limits: limits)
  let next = try InspectorFlight(compact: fresh)
  try next.append(event: "new_query_intent", query: .tapeTransportState, route: nil); try next.finish()
}

@Test func recoveryRefusesAnAdmittedUnfinishedObservation() throws {
  let (base, root, _) = try recoveryDirectories()
  defer { try? FileManager.default.removeItem(at: base) }
  let store = try PassiveInspectorStore(root: root)
  let flight = try InspectorFlight(compact: store)
  #expect(throws: (any Error).self) { try store.closeForArchive() }
  try flight.append(event: "query_completed", query: .tapeTransportState, route: nil); try flight.finish()
  try store.closeForArchive()
  #expect(throws: (any Error).self) { try InspectorFlight(compact: store) }
}

@Test func recoveryRejectsLinksAndDestinationsInsideOriginalLogs() throws {
  let (base, root, destination) = try recoveryDirectories()
  defer { try? FileManager.default.removeItem(at: base) }
  let original = Data("original\n".utf8)
  try original.write(to: root.appendingPathComponent("original.ndjson"))
  let nested = root.appendingPathComponent("nested")
  try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
  #expect(throws: (any Error).self) { try PassiveEvidenceArchive.move(root: root, to: nested) }
  let link = root.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
  #expect(throws: (any Error).self) { try PassiveEvidenceArchive.move(root: root, to: destination) }
  #expect(try Data(contentsOf: root.appendingPathComponent("original.ndjson")) == original)
  #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
}

@Test func changedLogsAbortBeforeRelocationAndRetainNewBytes() throws {
  let (base, root, destination) = try recoveryDirectories()
  defer { try? FileManager.default.removeItem(at: base) }
  let file = root.appendingPathComponent("original.ndjson")
  try Data("before\n".utf8).write(to: file)
  let changed = Data("changed\n".utf8)
  #expect(throws: (any Error).self) {
    try PassiveEvidenceArchive.move(root: root, to: destination, beforeMove: { try changed.write(to: file) })
  }
  #expect(try Data(contentsOf: file) == changed)
}

@Test func failedPrecommitBarrierNeverMovesOriginalEvidence() throws {
  let (base, root, destination) = try recoveryDirectories()
  defer { try? FileManager.default.removeItem(at: base) }
  try Data("retained\n".utf8).write(to: root.appendingPathComponent("original.ndjson"))
  let before = try PassiveEvidenceArchive.inventory(root)
  #expect(throws: (any Error).self) {
    try PassiveEvidenceArchive.move(root: root, to: destination, syncDirectory: { _ in throw CocoaError(.fileWriteUnknown) })
  }
  #expect(try PassiveEvidenceArchive.inventory(root) == before)
}

@Test func failedPostcommitBarrierRestoresAllOriginalInodesAndBytes() throws {
  let (base, root, destination) = try recoveryDirectories()
  defer { try? FileManager.default.removeItem(at: base) }
  try Data("retained\n".utf8).write(to: root.appendingPathComponent("original.ndjson"))
  let before = try PassiveEvidenceArchive.inventory(root)
  #expect(throws: (any Error).self) {
    try PassiveEvidenceArchive.move(root: root, to: destination, syncDirectory: { directory in
      if directory.lastPathComponent == "application",
        !FileManager.default.fileExists(atPath: root.path) { throw CocoaError(.fileWriteUnknown) }
    })
  }
  #expect(try PassiveEvidenceArchive.inventory(root) == before)
}

@Test func archiveManifestRetainsEverySessionAndPartialFileWithoutInventingClosure() throws {
  let (base, root, destination) = try recoveryDirectories()
  defer { try? FileManager.default.removeItem(at: base) }
  for session in ["old", "partial", "empty"] {
    let directory = root.appendingPathComponent(session)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    if session != "empty" {
      try Data((session == "old" ? "{\"complete\":true}\n" : "{\"unfinished\"").utf8)
        .write(to: directory.appendingPathComponent("observations-00000.ndjson"))
    }
  }
  let before = try PassiveEvidenceArchive.inventory(root)
  let archive = try PassiveEvidenceArchive.move(root: root, to: destination)
  let manifest = try JSONDecoder().decode(PassiveEvidenceArchive.Manifest.self,
    from: Data(contentsOf: archive.directory.appendingPathComponent("archive-manifest.json")))
  #expect(manifest.entries == before)
  #expect(try PassiveEvidenceArchive.inventory(archive.directory.appendingPathComponent("PassiveTransportFlights")) == before)
  #expect(archive.fileCount == 2)
}

@Test func finalReceiptBarrierFailureCannotLeaveACompletedArchiveReceipt() throws {
  let (base, root, destination) = try recoveryDirectories()
  defer { try? FileManager.default.removeItem(at: base) }
  try Data("retained\n".utf8).write(to: root.appendingPathComponent("original.ndjson"))
  let before = try PassiveEvidenceArchive.inventory(root)
  #expect(throws: (any Error).self) {
    try PassiveEvidenceArchive.move(root: root, to: destination, syncDirectory: { directory in
      if directory.lastPathComponent.hasPrefix("rewindDV-transport-logs-"),
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("archive-receipt.json").path) {
        throw CocoaError(.fileWriteUnknown)
      }
    })
  }
  #expect(try PassiveEvidenceArchive.inventory(root) == before)
  for archive in try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) {
    #expect(!FileManager.default.fileExists(atPath: archive.appendingPathComponent("archive-receipt.json").path))
  }
  try PassiveEvidenceArchive.requireNoPendingRecovery(root: root)
}

@Test func failedRollbackQuarantinesReplacementRootAndKeepsOriginalTree() throws {
  let (base, root, destination) = try recoveryDirectories()
  defer { try? FileManager.default.removeItem(at: base) }
  try Data("original retained bytes\n".utf8).write(to: root.appendingPathComponent("original.ndjson"))
  let before = try PassiveEvidenceArchive.inventory(root)
  #expect(throws: PassiveEvidenceArchive.RecoveryRequired.self) {
    try PassiveEvidenceArchive.move(root: root, to: destination, syncDirectory: { directory in
      if directory.lastPathComponent == "application", !FileManager.default.fileExists(atPath: root.path) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        throw CocoaError(.fileWriteUnknown)
      }
    })
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  let archive = try #require(FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).first)
  #expect(try PassiveEvidenceArchive.inventory(archive.appendingPathComponent("PassiveTransportFlights")) == before)
  #expect(throws: PassiveEvidenceArchive.RecoveryRequired.self) { try PassiveInspectorStore(root: root) }
  #expect(throws: PassiveEvidenceArchive.RecoveryRequired.self) { try PassiveEvidenceArchive.move(root: root, to: destination) }
  #expect(try PassiveEvidenceArchive.inventory(archive.appendingPathComponent("PassiveTransportFlights")) == before)
}

@Test func emptyReplacementCannotAuthenticateTheOriginalRoot() throws {
  let (base, root, destination) = try recoveryDirectories()
  defer { try? FileManager.default.removeItem(at: base) }
  let original = base.appendingPathComponent("original-root-retained")
  #expect(throws: (any Error).self) {
    try PassiveEvidenceArchive.move(root: root, to: destination, beforeMove: {
      try FileManager.default.moveItem(at: root, to: original)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    })
  }
  #expect(FileManager.default.fileExists(atPath: original.path))
  try PassiveEvidenceArchive.requireNoPendingRecovery(root: root)
}

private func recoveryRoute(_ generation: UInt64) throws -> FoundationRoute {
  var bytes = Data(count: 48)
  func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { bytes.replaceSubrange(offset..<(offset + $0.count), with: $0) }
  }
  put(UInt32(1),0); put(UInt32(48),4); put(UInt64(123),8)
  put(UInt64(10),16); put(UInt64(11),24); put(generation,32)
  put(UInt32(4),40); put(UInt16(1),44)
  return try FoundationRoute(data: bytes)
}

@Test func archivePauseSpansRouteChangesAndRequiresExplicitVerifiedResume() throws {
  let old = try recoveryRoute(1), fresh = try recoveryRoute(2)
  var gate = PassiveObservationRecoveryGate()
  gate.failed(on: old, storageBudget: true); gate.beginArchive()
  #expect(!gate.mayObserve(on: old) && !gate.mayObserve(on: fresh))
  let premature = gate.resume(on: fresh)
  #expect(!premature)
  gate.archiveCompleted()
  #expect(!gate.mayObserve(on: fresh))
  let resumed = gate.resume(on: fresh)
  #expect(resumed)
  #expect(gate.mayObserve(on: fresh))
  let reused = gate.resume(on: fresh)
  #expect(!reused, "A prior receipt cannot authorize another recovery")
}

@Test func archiveCannotClearNonstorageRouteErrorOrUnsupportedTimecodeFailure() throws {
  let old = try recoveryRoute(1), fresh = try recoveryRoute(2)
  var gate = PassiveObservationRecoveryGate()
  gate.failed(on: old, storageBudget: false); gate.beginArchive(); gate.archiveCompleted()
  let retriedOld = gate.resume(on: old)
  #expect(!retriedOld)
  #expect(!gate.mayObserve(on: old))
  let resumedFresh = gate.resume(on: fresh)
  #expect(resumedFresh, "Explicit resume can observe a fresh route without clearing the old failure")
  #expect(!gate.mayObserve(on: old) && gate.mayObserve(on: fresh))
  #expect(PassiveObservationRecoveryGate.mayRecoverTimecode(budgetFailure: true, failedRoute: old, currentRoute: old))
  #expect(!PassiveObservationRecoveryGate.mayRecoverTimecode(budgetFailure: false, failedRoute: old, currentRoute: old))
  #expect(!PassiveObservationRecoveryGate.mayRecoverTimecode(budgetFailure: true, failedRoute: old, currentRoute: fresh))
  #expect(!PassiveObservationRecoveryGate.isBudgetFailure("No valid deck reply"))
  #expect(!PassiveObservationRecoveryGate.isBudgetFailure("permanentSessionLockout"))
}

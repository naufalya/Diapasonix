import Foundation
import Testing
@testable import RewindDVMonitorCore

@Test func canonicalHostMetadataFailsClosedOnComponentMismatch() {
  let info: [String: Any] = ["CFBundleShortVersionString":"0.1.9", "CFBundleVersion":"199",
    "RewindDVProductVersion":"0.1.9", "RewindDVReleaseChannel":"beta", "RewindDVRequiredDriverBuild":"202"]
  #expect(ProductIdentity.matchesHost(info))
  for (key, bad) in [("CFBundleVersion","190"), ("RewindDVRequiredDriverBuild","194"),
    ("CFBundleShortVersionString","0.1.0"), ("RewindDVReleaseChannel","alpha")] {
    var changed = info; changed[key] = bad
    #expect(!ProductIdentity.matchesHost(changed))
    changed.removeValue(forKey: key)
    #expect(!ProductIdentity.matchesHost(changed))
  }
  #expect(ProductIdentity.display == "rewindDV 0.1.9 (Beta)")
  #expect(ProductIdentity.appBuild != ProductIdentity.driverBuild)
}

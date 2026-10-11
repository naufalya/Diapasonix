# Known limitations

PAL capture and a whole-tape NTSC workflow have succeeded on the Sony HVR-M15U; see [measured results and builds](COMPATIBILITY.md#successful-pal-and-whole-tape-captures). Broader PAL/deck coverage, a completed whole-tape PAL matrix, HDV acquisition/playback, active-capture disconnect, permanent-lockout stress, live extension unload and absolute tape-end proof remain open. Current Driver203 has software and distribution validation, with no fresh physical capture in this publication pass.

The current Beta includes accepted recovery, held-timecode, capture startup/tail classification and UI fixes. Original captured bytes and damage evidence remain preserved. Inspectors show every observed pack using a classifier/catalog covering 256 pack IDs and 274 layout variants; inventory coverage is not complete semantic decoding or IEC certification.

The previously installed M1 App189 Open DV chooser was not visible over Screen Sharing. Direct local comparison was unavailable; its cause remains unresolved. The combined app’s local chooser check passed, but M1 saved-file interaction and physical live-preview retesting remain open.

CLI/MCP external path grants are session-scoped. Physical recovery and driver activation remain interactive.

See [current development and latest public download](README.md) for independent
lifecycle identities. Current bounded development evidence is summarized in
[COMPATIBILITY](COMPATIBILITY.md). The earlier B183 evidence includes the successful PAL and whole-tape results
listed in compatibility; it does not qualify the current downloadable artifact.

Normal capture STOP has bounded positive receive-retirement evidence in earlier
B190 development. Live DriverKit extension disable/unload, hot replacement and
reboot-free removal remain unqualified. Follow the shutdown/restart maintenance
procedure; never use global extension disable as a capture-session STOP.

## Historical Alpha 0.0.77 observations

The following retained observations describe earlier bounded tests. Their open PAL and full-tape scope was subsequently extended by the successful records listed above; they do not qualify the current public artifact.

Startup/reset behavior, earlier device disappearance, full-tape endurance,
provider-loss during capture, sleep/wake and physical PAL/HDV capture remain open
areas. No continuing reset or active uncertainty occurred during the current
bounded captures. Retained gaps and unknown source quality remain authoritative.

- Saved raw DV25 NTSC/PAL playback and transitions are validated offline. Physical
  PAL capture, HDV playback and broader device/audio-format transitions remain
  unqualified. Invalid DV boundaries are rejected rather than guessed past.
- Inspector source fields share an identified sampled frame (twice per second
  while playing, immediately invalidated at a system change). Pause to inspect
  the selected frame. Missing or conflicting metadata remains unavailable.
- Post-capture DV/HDV processing bounds temporary lifetimes. This does not promise
  a fixed total app footprint or zero system swap. The cancelled receive-task
  Stop path can suppress intermediate processing progress; the final result
  still arrives.

The targeted Alpha 0.0.77 scenarios passed on the configuration in
[COMPATIBILITY](COMPATIBILITY.md). This is not complete driver qualification.

- Physical observer/query overlap with reserved capture ownership was
  unexercised. Physical cancellation while waiting was not run because no
  waiting state was encountered. One-second snapshots cannot exclude a shorter
  transient wait. Deterministic regressions and the isolated native UI check
  cover these paths offline.
- The exact owner responsible for the earlier Alpha 0.0.76 startup rejection
  remains unresolved. The independently reproduced admission race correction
  does not establish the historical incident's cause.
- Natural end-of-tape, hour-long endurance, other hardware/formats and
  active-capture disconnect/power loss remain unqualified. Blank video or absent
  timecode does not establish EOT.
- Current source includes reviewed driver ownership and cancellation-lifetime
  hardening. Live global unload and broader physical timing coverage remain
  unqualified; compilation and host tests do not establish them.
- The existing bounded diagnostic journal normally synchronizes every five
  seconds and uses one-second UI observations. Export requests a flush; recent
  records can still be lost in a crash or power failure. Support ZIPs have size
  limits and may omit or truncate records; consult their manifests.

Every clip in the targeted retest retained two DBC changes after empty packets
and one terminal partial frame. Reported host-ring drops and raw transport-gap
events were zero, but hardware continuity and exact missing-frame counts remain
unknown. These counters do not prove pristine content or universal lossless capture.

The first clip's frame 5 (about 0.167 seconds) contains 380 nonzero video STA
blocks and 961 active audio-error sentinel observations, plus conflicting
metadata/recorded-label transitions. Its cause remains unresolved. The operator
noticed no visible or audible problem around it. An earlier Alpha 0.0.76 long
clip's frame 3597 (about 120.020 seconds) is a separate unresolved marked-frame
observation. Neither is automatically evidence for or against the admission fix.

Saved-byte/per-frame hashes establish byte consistency, not flawless audiovisual
content. Preview, source metadata, raw transport evidence and human playback
observations remain distinct. Unknown metadata is not silently repaired or
selected by majority. Performance superiority has not been established.

Consult the canonical status and each immutable release’s provenance for its
actual signing and artifact identity. The current full pipeline is Developer
ID-signed and notarized, with normal macOS approval and no SIP change. Signing
and notarization establish distribution checks, not full hardware qualification.

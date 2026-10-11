# Unchanged driver packaging

GUI-only updates must retain the exact verified signed driver when the driver's
implementation, compiled inputs, signing requirements and compatibility contract
are unchanged. This supersedes the full-component candidate policy introduced
by the canonical version migration. App and product identities advance for a
changed delivered app; the reused driver keeps its own existing identity.

Before delivering an app-only candidate:

- Identify the retained driver by its original source revision, bundle versions,
  signature and full bundle manifest. Compare relevant driver inputs and the
  app/driver contract against that source; do not infer equivalence from a version
  number or an app-only filename.
- Copy the entire retained signed DEXT without modification or re-signing. Verify
  every retained file, symlink and mode against the original manifest and verify
  its signature independently before and after outer-app signing and packaging.
- Record the new app's source and identity separately from the retained driver's
  source and identity. Preserve required-driver compatibility and test the actual
  negotiation. An app product version must not relabel the retained driver.
- Do not request driver activation when the intended compatible driver is already
  running. Confirm actual active identity independently of registration. Existing
  pending macOS replacement requests remain a separate installation condition;
  never cancel them with forced removal or reset procedures.

The current identity generator and Developer ID archive workflow still enforce
full-component identities, and `Tools/package-app-only.py` remains retired. The
reuse workflow must be implemented and validated before the next app-only binary
delivery. Do not work around that limitation by advancing an unchanged driver,
disabling validation, reusing an app identity for changed bytes, or reviving the
historical packager unchanged. This policy update itself delivers no binary and
changes no reserved identities or installed components.

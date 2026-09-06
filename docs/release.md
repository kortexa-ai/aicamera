# Release process

The first public release is **0.2.0 early alpha**. Keep installer safety, signing, notarization,
public-content review, and clear cleanup instructions as release requirements. Record incomplete
platform coverage and nonblocking rough edges in the release notes and issue 56.

## Prepare

1. Review all reachable source history and current inputs for credentials, personal media,
   unintended configuration, and third-party notices. Run `scripts/audit-public-release.py`
   with a verified Gitleaks executable; never log secret matches. Review repository issue bodies
   and other surfaces that will become visible as well. Do not rewrite history without an exact plan.
2. Update the host marketing/build versions in `project.yml`, release notes, site version/download
   links, and `Resources/Installer/Distribution.xml`. Component versions remain independent.
   A changed distribution signing/provisioning identity can require a separate component build.
3. Run `scripts/validate.sh`, review the diff, and commit the intended source. Release packaging
   requires a clean commit. Do not tag an unverified build.

## Local Apple setup

Use Xcode's local account/profile management for the app identifiers and entitlements. Keep
`Config/Local.xcconfig` ignored. The app, frameworks, camera extension, and HAL plug-in use
**Developer ID Application**; the installer uses **Developer ID Installer**, from the same team.
Keep notarization credentials in a Keychain profile, not in the repository or command output.
The default profile is `notarytool`; override it with `AICAMERA_NOTARY_PROFILE`.
Select a specific installer certificate with `AICAMERA_INSTALLER_IDENTITY` if necessary.

## Build and notarize

```sh
scripts/package-release.sh
```

This runs validation, archives a universal Release, exports with Developer ID profiles, verifies
nested signatures/identities/versions/runtime/timestamps/notices, notarizes and staples the app,
then builds, signs, inspects, notarizes, and staples the final installer. It does not install or
activate anything. The inner app is stapled before packaging so both it and the installer have
an offline ticket. Apple's installer submission also scans its nested code.

Each run writes to a new ignored `build/release-<version>.*` directory. Keep its source commit,
notary results/logs, signature verification, and final checksum with the acceptance evidence.
Do not upload the archive, export options, or intermediate signing/build logs as release assets.
Distribute only the final `AICamera-<version>.pkg`, `SHA256SUMS`, release notes, and required notices.

The package carries the app in its private script payload and invokes the exact same protected
replacement transaction as `scripts/install-app.sh`. It installs only the host in `/Applications`.
It never activates/removes an extension, copies a driver into HAL, reloads Core Audio, launches
capture, or requests a reboot. macOS Installer provides the administrator authorization UI.

## Acceptance and publication

- Inspect the actual notarized package and verify its SHA-256. Test the normal Installer UI and
  host upgrade on a suitable Mac. Preserve a working camera extension when restart is unavailable.
- Check app launch, settings preservation, basic camera/microphone operation, privacy mute, and
  the documented removal/recovery path. Record untested clean-machine/Intel/reboot cases honestly.
- Tag the package's exact `source-commit.txt` commit as `v0.2.0` and push the tag. Create a draft
  release, attach the final package and checksum, and use `docs/releases/0.2.0.md` as its notes.
- Mark this release **prerelease / early alpha**. Publish after the public audit and basic acceptance
  pass. Repository visibility is a separate public-exposure operation and must wait for the audit.
- Configure GitHub Pages to deploy through Actions. `pages.yml` deploys `site/` when a release is
  published or when manually dispatched. Verify HTTPS, mobile layout, and the actual download link.
- Verify the public release/website, download the published installer, and compare its checksum.
  Record the commit/tag, artifact hash, notarization IDs, release URL, and Pages URL in issue 56.

GitHub source ZIP/tar downloads are source code, not the installer. Avoid moving an already
published tag or replacing an installer silently; publish a new version for changed release bytes.

## Recovery

Keep the prior known-good signed installer. Reinstall the same release to repair a failed host
replacement; use a deliberately versioned follow-up for an upgrade fix. Do not force-clean an active
system extension. User-facing fallback steps are in [installation.md](installation.md#manual-cleanup).

# Security and privacy

## Supported version

Version 0.2.0 is an early alpha. Security fixes are developed on the `main` branch. Report a vulnerability privately to the repository maintainers. Do not open a public issue that contains a credential, personal media, or an exploitable system-installation detail.

## Media handling

AI Camera processes camera and microphone data in memory. It does not record or persist raw media. The schema contains `persistMedia` for forward compatibility, but the current validator and documentation require it to remain disabled.

Real-time callbacks copy only bounded buffers needed for processing. Network stages hold at most one active request and one replaceable pending frame. Overlays keep normalized current state and expire it.

The camera extension has no network client. If the CMIO service can resolve the client, Security.framework also validates the live host against the exact identifier, Apple generic anchor, extension-derived team, and absence of `get-task-allow`. Every authorization requires two identical PID-version-bound `csops_audittoken` snapshots with the exact installed path, identifier, and team; an Apple Development, App Store, or Developer ID validation category; hardened runtime and library validation; and no ad-hoc, debugged, invalid-page, or `get-task-allow` state. PID version changes on `exec`. The accepted CoreMediaIO client identity and execution binding are checked again at stream start. A bounded watchdog checks the execution binding while the sink waits, and every forwarded sample gets an immediate check. Stop or identity change clears or revokes the binding. Results are never cached by numeric PID. The kernel selectors are XNU ABI that the SDK does not expose, so unavailable or changed operations reject the stream and every release needs native acceptance. The HAL driver has no network client and uses only a bounded in-memory ring.

## Network egress

The default configuration has remote AI processing disabled. Remote egress fails closed unless all of these conditions hold:

- the URL uses HTTPS;
- privacy mode is `allowListed`;
- the exact hostname is listed; and
- the endpoint has every required data-class grant.

Model HTTP sessions are ephemeral, do not store cookies or URL-cache data, and reject redirects. Network analysis uses a clean transformed camera frame before private overlays are drawn.

Review enabled data routes in Settings → Privacy. A host allowlist controls destination names, not the operator of that service.

## Credentials

Profiles store an environment-variable name or Keychain account name. They must not contain secret values. The application resolves Keychain items from service `ai.kortexa.aicamera` at request time.

Do not put credentials in `Config/Local.xcconfig`, example profiles, source, logs, screenshots, or issue reports. Use Keychain, a local process environment, or CI secret storage.

## Privileged operations

The app uses Apple’s system-extension API for the camera. The development installer verifies exact Apple-anchored, same-team host and camera-extension requirements before and after copying into a root-private staging directory, strips ACL and write access, serializes transactions, and uses no-follow same-filesystem moves. It protects the installed root and verifies that its inode is the verified staged inode before it commits the build marker. Catchable failures and signals restore the prior app and marker. The developer install uses an administrator-authorized transaction; the signed production package runs the same transaction through macOS Installer. The app uses a separate administrator-authorized command for the HAL driver. Install and removal paths are fixed and shell quoted. The removal command targets only `AICameraAudioDriver.driver`.

Verify the app’s signature and bundled driver before authorizing installation. Device lifecycle tests are manual and opt-in.

## Deployment

Distribution builds need appropriate Apple profiles, hardened runtime, Developer ID signing, and notarization. Never commit certificates, provisioning profiles, private keys, or notarization credentials.

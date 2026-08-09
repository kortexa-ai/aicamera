# Security and privacy

## Supported version

This repository currently supports the `main` branch. Report a vulnerability privately to the repository maintainers. Do not open a public issue that contains a credential, personal media, or an exploitable system-installation detail.

## Media handling

AI Camera processes camera and microphone data in memory. It does not record or persist raw media. The schema contains `persistMedia` for forward compatibility, but the current validator and documentation require it to remain disabled.

Real-time callbacks copy only bounded buffers needed for processing. Network stages hold at most one active request and one replaceable pending frame. Overlays keep normalized current state and expire it.

The camera extension has no network client. Its feeder sink rejects writers unless the CoreMediaIO client PID resolves to live code that satisfies an Apple-anchored requirement for the exact host bundle identifier and the extension's signing team. CoreMediaIO does not expose an audit token, so PID lookup is performed synchronously for every new client, never cached by PID, and the result is bound to that client's `clientID` only for the stream lifetime. Lookup, requirement, or team failures reject the stream. The HAL driver has no network client and uses only a bounded in-memory ring.

## Network egress

The profile defaults to loopback-only access. Remote egress fails closed unless all of these conditions hold:

- the URL uses HTTPS;
- privacy mode is `allowListed`;
- the exact hostname is listed; and
- the endpoint has every required data-class grant.

Model HTTP sessions are ephemeral, do not store cookies or URL-cache data, and reject redirects. Network analysis uses a clean transformed camera frame before private overlays are drawn.

Review a remote profile before applying it. A host allowlist controls destination names, not the operator of that service.

## Credentials

Profiles store an environment-variable name or Keychain account name. They must not contain secret values. The application resolves Keychain items from service `ai.kortexa.aicamera` at request time.

Do not put credentials in `Config/Local.xcconfig`, example profiles, source, logs, screenshots, or issue reports. Use Keychain, a local process environment, or CI secret storage.

## Privileged operations

The app uses Apple’s system-extension API for the camera. It uses one administrator-authorized AppleScript command for the HAL driver. Install and removal paths are fixed and shell quoted. The removal command targets only `AICameraAudioDriver.driver`.

Verify the app’s signature and bundled driver before authorizing installation. Device lifecycle tests are manual and opt-in.

## Deployment

Distribution builds need appropriate Apple profiles, hardened runtime, Developer ID signing, and notarization. Never commit certificates, provisioning profiles, private keys, or notarization credentials.

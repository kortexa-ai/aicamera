# Contributing to AI Camera

AI Camera is a macOS host app with a deliberately small CoreMediaIO extension and Core Audio
loopback driver. Contributions should preserve its demand-driven lifecycle, bounded media paths,
and fail-closed privacy model.

## Toolchain and setup

- macOS 14 or newer
- Xcode 15 or newer; Xcode 16 is recommended
- Swift 5.10
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

Generate the Xcode project and run the complete non-installing validation:

```sh
scripts/bootstrap.sh
scripts/validate.sh
```

`validate.sh` runs Swift tests, checks scripts and metadata, exercises the HAL driver harness,
and builds the app, framework, camera extension, and audio driver without code signing. It never
installs or activates system software.

## Repository layout

- `Sources/AICameraCore` — configuration, adapter protocols, privacy gates, and bounded state
- `Sources/AICameraApp` — macOS UI, capture, rendering, and pipeline coordination
- `Sources/AICameraCameraExtension` — virtual-camera publication and host-produced frame intake
- `Sources/AICameraAudioDriver` — virtual-microphone HAL loopback plug-in
- `Sources/AICameraShared` — small contracts shared with the camera extension
- `Tests` — Swift unit tests and the native HAL harness
- `Resources` — app, extension, driver, and overlay bundle resources
- `Examples` — validated profiles containing credential references only
- `docs` — architecture, configuration, security, installation, and testing details
- `scripts` — generation, build, validation, run, and protected installation workflows

## Engineering rules

Keep changes small and direct. Put model integrations behind protocols in `AICameraCore`; keep
capture and rendering in the host; keep the camera extension limited to publishing host-produced
frames. Do not introduce unbounded queues or waits on capture, CoreMediaIO, HAL, audio-renderer,
or other real-time callbacks. Replace, drop, expire, or cancel stale work.

New configuration must remain versioned, bounded, and validated. Hardware IDs, endpoints, signing
teams, credentials, and model choices must remain configurable. Keep comments accurate when the
code they describe changes.

## Privacy and security

Never commit credentials, private keys, provisioning profiles, signing material, model weights,
literal device identifiers, or captured camera/microphone media. Profiles and examples may contain
environment-variable or Keychain references, never secret values. Raw media remains memory-only
unless a user explicitly enables a future recording feature.

Remote egress must remain opt-in and fail closed through an approved endpoint, host allowlist, and
explicit data-class grants. Generated scripts and network responses are untrusted input: validate
their type and size and impose deadlines before they reach application state.

## System-component boundary

Ordinary builds and automated tests must not install, activate, reload, deactivate, or remove the
camera extension or HAL driver. They must not change system defaults or request privacy permission.
Installation and signed-device acceptance require an explicit operator action and may require
administrator approval or a reboot. Never weaken feeder identity, hardened-runtime, entitlement,
path, team, or PID-version checks to make development easier.

## Tests and documentation

Add focused tests for changed behavior, including bounds, cancellation, stale generations, invalid
input, and privacy denial where applicable. Run `scripts/validate.sh` before considering a change
complete. Update `PLAN.md` for non-trivial scope or status changes, `VALIDATION.md` for durable test
evidence, and the relevant user documentation for behavior or configuration changes.

Manual acceptance procedures belong in `docs/testing.md`. Do not record media merely to prove that
a path works.

## Issues and changes

Search existing issues before opening a duplicate. Describe the user-visible symptom, platform and
build, reproduction steps, expected behavior, and whether system components were installed. Do not
attach profiles until all machine identifiers and credential references have been reviewed.

Keep each change focused and explain any privacy, real-time, installation, configuration-migration,
or compatibility impact. Breaking changes require documentation and an explicit migration path.

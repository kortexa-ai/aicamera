# Signing, installation, and removal

## Why signing is required

macOS accepts a camera system extension only from a signed application in `/Applications`. The host provisioning profile needs `com.apple.developer.system-extension.install`. The host and extension also need matching application-group entitlements. Development profiles must be created for your own team and bundle IDs.

No team ID or profile is committed. Copy the ignored local template:

```sh
cp Config/Local.example.xcconfig Config/Local.xcconfig
```

Set `DEVELOPMENT_TEAM` and any local signing overrides. Make sure Xcode has an Apple account that can create or download suitable profiles. For a signed non-installing build, run:

```sh
SIGNING=1 scripts/build.sh
```

To build and install the signed Release configuration, run:

```sh
scripts/install-app.sh
```

A plain `scripts/build.sh` is unsigned and cannot activate the extension. A signed Debug host is not accepted as a feeder.

The development installer uses one administrator-authorized transaction. It checks exact Apple-anchored host and extension identifiers, matching signing teams, and absence of `get-task-allow` before and after copying into a root-private staging directory. It strips ACL and group/world write access, serializes installers with a stale-aware lock, moves the verified app on the same filesystem without following a destination symlink, protects the final app root, checks that its inode is the staged inode, terminates only old processes at the exact app or rollback path, and commits a protected build marker. Catchable failures and signals restore the prior app and marker.

## Camera extension

1. Install and open the signed host app from `/Applications`.
2. Open the AI Camera menu-bar panel.
3. Select **Install** for the virtual camera.
4. If a newer extension is bundled later, the row reports **Update available**. Select **Update**; do not remove the active extension first.
5. If status is **Approval required**, select **Open Extension Settings** and approve it.
6. If status is **Pending reboot**, restart macOS. An updated build can be active while older terminated generations wait for that reboot; confirm the active version with `systemextensionsctl list`.

Select **Remove** for the virtual camera before removing the app. Deactivation can also require approval or a reboot. The app submits `OSSystemExtensionRequest`; it never edits system-extension directories directly.

## Audio driver

Select **Install Audio Driver** in the app. macOS shows a standard administrator authorization prompt. The app copies its bundled driver to:

```text
/Library/Audio/Plug-Ins/HAL/AICameraAudioDriver.driver
```

It then asks `coreaudiod` to reload. Select **Remove Audio Driver** to delete only this exact bundle and reload Core Audio. The command uses fixed, shell-quoted paths. No wildcard delete is used.

Audio applications can cache device lists. Quit and reopen the client after driver installation or removal. If the device does not appear, log out or restart macOS.

## Permissions

The host requests camera and microphone access only when the proxy starts. If access is denied, open:

**System Settings → Privacy & Security → Camera / Microphone**

The camera extension itself does not make network requests. It receives processed IOSurface frames from the host.

## Removal order

1. Stop the proxy.
2. Select **Remove** for the virtual camera and complete any approval/reboot step.
3. Select **Remove Audio Driver**.
4. Quit AI Camera.
5. Remove `/Applications/AI Camera.app`.

Do not remove a system extension bundle from the app while it is active. Use the lifecycle request first.

## Distribution

A distributable build needs the relevant Apple capabilities, Developer ID signing, hardened runtime, and notarization. The repository does not contain organization credentials, certificates, or a notarization password. Keep those in Xcode, Keychain, or CI secrets.

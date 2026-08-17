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
2. Open the AI Camera menu-bar panel. Its **Virtual devices** rows remain visible after setup as a quick health check. Each row identifies the physical input resolved from **System Default** or the explicitly selected input. If the default is not an eligible direct-hardware input, the row warns and identifies the physical fallback.
3. Select **Install** for the virtual camera.
4. If a newer extension is bundled later, the row reports **Update available**. Select **Update**; do not remove the active extension first.
5. If status is **Approval required**, the app opens **System Settings → General → Login Items & Extensions** automatically. Enable **AI Camera** under **Media Extensions**. The row also keeps an enabled **Open Settings** fallback.
6. If status is **Pending reboot**, restart macOS. An updated build can be active while older terminated generations wait for that reboot; confirm the active version with `systemextensionsctl list`.
7. If the extension is active but the row reports **Active — device unavailable**, restart macOS before removing or reinstalling anything. This finishes retired-generation cleanup and lets CoreMediaIO republish the active device.

Select **Remove** for the virtual camera before removing the app. Deactivation can also require approval or a reboot. The app submits `OSSystemExtensionRequest`; it never edits system-extension directories directly.

## Audio driver

Select **Install** for **AI Camera Microphone** in the menu-bar panel. macOS shows a standard administrator authorization prompt. If the installed driver is older than the bundled build, the row shows **Update** and safely replaces the same exact bundle. The app copies its bundled driver to:

```text
/Library/Audio/Plug-Ins/HAL/AICameraAudioDriver.driver
```

It then asks `coreaudiod` to reload. Select **Remove** in Settings → Maintenance to delete only this exact bundle and reload Core Audio. The command uses fixed, shell-quoted paths. No wildcard delete is used. A **Repair** action is available when the bundle is installed but Core Audio has not loaded the device.

Audio applications can cache device lists. Quit and reopen the client after driver installation or removal. If the device does not appear, log out or restart macOS. If the device is visible after an in-place update but client use does not activate microphone capture, use the explicit **Repair** action or restart macOS so Core Audio loads the on-disk generation; do not manually delete the live driver.

## Permissions and login

Device installation and media authorization are explicit user actions. Selecting **Install** requests the matching camera or microphone permission before macOS begins the component installation flow, so permission and system-install dialogs are not intentionally stacked. A denied permission row opens the matching pane under **System Settings → Privacy & Security**; macOS does not show the original prompt again. A restricted permission cannot be changed from the app.

**Open AI Camera at login** is available under **Settings → General** and uses `SMAppService.mainApp`. It is optional and disabled until the user enables it. macOS can require approval in Login Items settings. This setting is important for automatic operation after login because a virtual-device client cannot relaunch an app that the user explicitly quit.

The camera extension itself does not make network requests. It receives host-produced IOSurface frames and reports only bounded timestamped aggregate source-stream demand through a read-only custom CoreMediaIO device property.

## Removal order

1. Close applications that use **AI Camera** or **AI Camera Microphone** and wait for the menu panel to report that the lanes are idle.
2. In Settings → Maintenance, select **Remove** for the virtual camera and complete any approval/reboot step.
3. Select **Remove** for the virtual microphone.
4. Disable **Open AI Camera at login** if it is enabled, then quit AI Camera.
5. Remove `/Applications/AI Camera.app`.

Do not remove a system extension bundle from the app while it is active. Use the lifecycle request first.

## Distribution

A distributable build needs the relevant Apple capabilities, Developer ID signing, hardened runtime, and notarization. The repository does not contain organization credentials, certificates, or a notarization password. Keep those in Xcode, Keychain, or CI secrets.

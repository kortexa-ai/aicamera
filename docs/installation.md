# Install, repair, and remove AI Camera

AI Camera 0.2.0 is an **early alpha**. The installer installs the host app; camera and microphone
system components are set up separately, with your permission, inside the app.

## Install or upgrade

1. Download `AICamera-0.2.0.pkg` from the [GitHub release](https://github.com/kortexa-ai/aicamera/releases/tag/v0.2.0).
2. Close calls and AI Camera Preview tests, then open the package and follow macOS Installer.
   The package requires administrator authorization and installs on your startup volume.
3. Open **AI Camera** in Applications. Its camera icon appears in the menu bar.
4. In the menu panel, choose **Install** for the camera and/or microphone you want to use.
   Allow the requested camera/microphone access. Enable the camera under **System Settings →
   General → Login Items & Extensions → Media Extensions** when macOS asks.
5. Select **AI Camera** and, optionally, **AI Camera Microphone** in your call app.

The installer preserves your settings, model downloads, dedicated login, and installed system
components. It upgrades an existing protected/root-owned AI Camera app in place; you do not need
to remove that app first. It does not activate/update/remove the camera extension, install/reload
an audio driver, change system defaults, or require a restart itself. Open the app manually after
installation. An already running host is stopped as part of the protected replacement transaction.

If the app offers a component **Update**, that is a separate operation. macOS may require approval
or a restart for camera-extension changes. If you cannot restart now, leave the working component
installed and postpone its update. App-only updates keep component versions independent.

## Repair

- **Installer failed:** keep the failure message. The protected transaction attempts to restore
  the previous app and generation marker. Run the same signed installer again; do not replace
  protected files using a loose recursive copy or delete system-extension directories.
- **No camera device:** check Media Extensions and **Settings → General → Virtual Devices**.
  Reopen the call app after setup. If AI Camera reports a pending restart, wait for a suitable
  restart window rather than repeatedly removing and reinstalling the extension.
- **No microphone device:** use the microphone **Repair** action when offered. It reloads Core Audio,
  interrupting other audio apps, so close calls first. Reopen the call app afterward.
- **Hardware permission denied:** use the in-app settings link, or **System Settings → Privacy &
  Security → Camera / Microphone**. Choose a direct physical input in AI Camera Settings.
- **App cannot open:** reinstall the same or a newer signed package to restore the host, then use
  its device removal controls if you want to uninstall. Do not disable Gatekeeper or SIP.

## Normal removal

There is no separate uninstaller application in this alpha. Remove system components from AI Camera
before removing the host:

1. Close apps using the virtual camera/microphone and stop Preview tests and the agent.
2. Turn off **Open AI Camera at login** in **Settings → General**.
3. In **Settings → General → Virtual Devices**, choose **Remove** for the camera and microphone.
   Follow macOS authorization prompts. If camera removal is pending a restart, leave the app in
   Applications until after that restart, then confirm removal.
4. Choose **Quit** in the menu-bar footer. Command-Q in a standalone window only closes that window.
5. The app's root is protected against unprivileged replacement. In Terminal, clear that protection:

   ```sh
   sudo chflags nouchg '/Applications/AI Camera.app'
   ```

   Then move **AI Camera.app** from Applications to Trash in Finder and authorize when requested.

Settings and models are kept unless you explicitly remove them as described below.

## Manual cleanup

Use these steps if normal removal fails. Close calls first. Each path below belongs specifically
to AI Camera; do not generalize the commands to other applications or system-extension directories.

### Camera extension

First try reinstalling the signed host, then use its **Remove** action. If that is unavailable,
disable **AI Camera** in **System Settings → General → Login Items & Extensions → Media Extensions**.
Disabling stops its use; macOS may still retain its registration until supported removal completes.

macOS owns registered camera-extension files and can defer removal until restart. If removal is
pending, leave the host installed until you can restart and finish removal. Do **not** delete files
under `/Library/SystemExtensions`, disable SIP, or repeatedly force extension installation.

### Microphone driver

If the microphone **Remove** action fails, verify the exact driver bundle in Terminal:

```sh
plutil -extract CFBundleIdentifier raw '/Library/Audio/Plug-Ins/HAL/AICameraAudioDriver.driver/Contents/Info.plist'
```

Continue only if the result is `ai.kortexa.aicamera.audio.driver`. Remove that exact driver:

```sh
sudo rm -rf '/Library/Audio/Plug-Ins/HAL/AICameraAudioDriver.driver'
sudo killall coreaudiod
```

The second command restarts macOS audio and interrupts audio applications. A later logout/restart
is an alternative if you cannot interrupt audio now. Reopen call apps so their device lists refresh.
A missing driver path means there is nothing to delete there.

### Host, login item, and installer receipt

After the camera removal is complete and the microphone driver is removed, quit AI Camera.
Disable any remaining AI Camera entry under **Login Items** in System Settings, clear the app's
protection with the `chflags` command above, and move the app to Trash in Finder.

The installation marker and receipt are optional remaining bookkeeping. Once the app is removed:

```sh
sudo chflags nouchg '/Library/Application Support/AI Camera/install-generation'
sudo rm -f '/Library/Application Support/AI Camera/install-generation'
sudo rmdir '/Library/Application Support/AI Camera'
sudo pkgutil --forget ai.kortexa.aicamera.installer
```

A missing marker/receipt is harmless. `rmdir` deliberately refuses to delete a nonempty directory;
inspect anything remaining rather than forcing a recursive delete.

### Optional settings, models, and credentials

To keep your configuration for a future reinstall, stop here. To remove it, use Finder's
**Go → Go to Folder** and move these AI Camera items to Trash:

- `~/Library/Application Support/AI Camera` — settings, optional model downloads, dedicated Codex home.
- `~/Library/Preferences/ai.kortexa.aicamera.plist` — quick-control/window preferences.
- `~/Library/Caches/ai.kortexa.aicamera` — if present.

Deleting files does not necessarily remove Keychain credentials. Before uninstalling, use **Sign Out**
for AI Camera's Codex login and remove its API key in Settings. If the app is broken, reinstall it
first to use these controls. Advanced users can remove the `ai.kortexa.aicamera` API-key items in
Keychain Access. Do not remove every `Codex Auth` item: that can sign other Codex applications out.
AI Camera's login is separate from your normal coding session.

## Building and signing

Development requires Xcode, XcodeGen, and your own Apple development team/provisioning profiles.
Copy `Config/Local.example.xcconfig` to ignored `Config/Local.xcconfig` and configure signing there.
The host needs the system-extension installation capability; host and extension share matching
application-group entitlements and signing team.

```sh
scripts/bootstrap.sh
scripts/validate.sh                 # No signing, installation, or activation
SIGNING=1 scripts/build.sh           # Signed development build, no installation
scripts/install-app.sh               # Protected signed host installation
```

The development and production installers use the same protected transaction. It validates nested
identity before and after private staging, safely replaces only the fixed app, protects the installed
root and generation marker, and rolls back catchable failures. See [the release process](release.md)
for Developer ID archive/export, notarization, and production packaging.

After installing a packaged release, macOS App Management can deny a terminal's attempt to modify
that app even when its command runs under sudo. A `chflags: ... Operation not permitted` failure
can come from this protection; check the TCC diagnostic and the transaction's restored app/marker
before retrying. Apple documents [App Management](https://support.apple.com/en-mide/guide/mac-help/mchl211c911f/mac)
as the permission for updating or deleting other apps.

Use the normal signed Installer package path for that update, keeping the existing postinstall and
protected transaction. Verify the package and exported app, preserve the Developer ID identity,
then install the verified package with Installer or `sudo /usr/sbin/installer -pkg <package> -target /`.
Do not substitute an ordinary recursive copy, disable privacy protections, or remove the camera
extension. A locally signed development package is not a notarized public release; public packages
still follow the complete release verification/notarization procedure.

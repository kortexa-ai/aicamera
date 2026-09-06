# AI Camera product plan

AI Camera is a demand-driven macOS virtual camera and microphone. The host acquires each physical input only while the matching virtual device has a client, or while the user runs an explicit local test or explicitly activates the agent microphone. Fresh profiles are pure passthrough. Optional bounded local and remote stages can render overlays, transcribe speech, run an agent, and mix speech output.

Detailed test evidence belongs in [`VALIDATION.md`](VALIDATION.md). Manual acceptance procedures belong in [`docs/testing.md`](docs/testing.md). This file is the canonical roadmap and backlog.

## Public early alpha 0.2.0

Prepare a public early-alpha release with a Developer ID-signed app, a signed/notarized installer,
manual cleanup instructions, and a single-page GitHub Pages site. Reuse the protected host
replacement transaction; package execution must not activate or remove system components.
Keep the camera extension installed during development-host upgrade acceptance. No restart is
available on the current Mac. The release checklist and actual acceptance/deployment evidence are
tracked in issue 56; broader production lifecycle coverage remains follow-up work.

## Current product direction

The next product step is a useful live-call companion: explicit control over when the agent
listens, requested local notes, concise grounded answers, and small readable or playful visuals
in the outgoing camera. The user must be able to keep talking to another person while the agent
works. Preserve the current continuous conversation mode and the published release while adding
an independent input gate and one-question mode. Follow the tool vocabulary and staged design in
[`docs/agent-roadmap.md`](docs/agent-roadmap.md); implementation work is tracked in #58, with live
translation/presentation controls in #57 and face-anchored graphics in #45.

The active target is a complete local desktop experience: OpenAI Realtime with an API key or a
dedicated Codex login, plus in-process transcription, translation, object detection, and gestures.
Custom service integrations and their normal Settings controls are out of scope for
this phase. Settings import/export also remains hidden; if exposed later, label it Settings
import/export without deployment-specific terminology. Older compatible-service milestones below
are historical roadmap context.

Implementation and acceptance priorities:

- [x] Separate agent input pause from call microphone mute and retain continuous conversation
  as the default. Add one-question mode and Control–Option–Space to ask again explicitly.
- [x] Add a bounded sequence of agent tools, requested local notes with their own window,
  readable native information cards, silent waiting, and agent sleep. Keep note storage separate
  from camera presentation and preserve the published 0.2.0 package while these develop on main.
- [x] Add typed state/translation tools and live language updates shared with Settings. Keep
  caption on/off aligned with the quick toolbar and reject prior-language completions without
  restarting the active conversation. Spoken translation remains #57.
- [x] Add generated-scene presentation with an aspect-preserving camera inset, immediate full-camera
  fallback on missing/expired graphics, and a direct Reset view. External image/deck loading and
  independent call-client acceptance remain follow-up parts of #57.
- [x] Add opt-in U.S. weather forecasts with approximate-location permission, bounded public HTTP,
  source/issuance/units, and lookup-to-card continuation. Worldwide weather and market data still
  need provider decisions; see [#59](https://github.com/kortexa-ai/aicamera/issues/59).
- [x] Add bounded local decimal calculation so the agent can check arithmetic before showing a
  comparison. Report rounding and retain units/assumptions; calculation does not verify live facts.
- [x] Add requested local face-effect anchors with crop/mirror alignment, a small three.js bridge,
  and native stale/lost-track suppression. Dense 3D tracking, occlusion, diverse real-person motion,
  and independent call-client acceptance remain parts of #45.
- [ ] Add further sourced information providers, spoken translation/external presentation assets, and
  richer face-tracked graphics in the staged companion roadmap. Validate new listening/tool interactions
  with live speech after synthetic transport and native UI acceptance.

- [x] Keep saved feature setup separate from runtime quick controls. The menu toolbar controls
  mute, original captions, translation, agent activation, and gestures. Global Control–Option–A/M
  toggle agent/mute; late results cannot cross quick-control generations. Preview and local tests
  live in a dedicated larger window; Preview/About/Settings share Dock lifecycle. The footer has
  Preview on the left and About/Quit on the right, with an accessible readiness/activity dot above.

- [x] Make explicit agent activation available through held victory or the menu while a call is
  active. Keep one server conversation across turns, close input during replies, and send replies
  to local speakers/headphones plus the virtual microphone when selected by a call. Fist engages
  privacy mute; manual Unmute remains separate. Keep inference/network work off media callbacks.
- [x] Publish a native animated agent status orb and gesture hold feedback into the outgoing
  camera image. Inset both top corners for floating client chrome. Aggregate usable hand-joint
  confidence and isolate bounded hand inference from image preparation; keep live gesture/provider
  acceptance separate from deterministic synthetic regressions.
- [ ] Complete API-key Realtime acceptance: silent connection/response probe, one utterance,
  transcript/translation, overlay tools, cancellation, error recovery, and a second turn.
  Installed-app connection, retry to Listening, no-speech capture release, and preservation of
  a separately started microphone test pass. Spoken response and tool checks remain.
- [x] Add a dedicated Codex sign-in/refresh/sign-out path based on the public Realtime flow used
  by `esp32-voice`, with isolated credentials. Sign-in, managed refresh, public session acceptance,
  and repeated user-heard responses with normal playback pass. Tools and captions remain in the speech matrix.
  Subscription coverage of Realtime usage remains unverified.
- [x] Implement embedded Whisper with explicit verified model downloads, progress, cancellation,
  removal, a local provider choice, and measured in-process transcription. Offer Base, Small, and
  Large v3 with distinct speed/accuracy descriptions; Large is limited to M4 Pro/Max/Ultra and M5 chips.
- [x] Correct local translation Unicode handling, model/client reuse, cancellation, output limits,
  and late download completion; verify synthetic native output, recovery, and latency.
- [x] Reuse local detector workers, keep model loading off the UI thread, preserve cancellation,
  bound tensor output and postprocessing, and verify native inference on public fixtures.
- [x] Verify local video inference, gesture overlays, and manual three.js composition during a
  camera test; stop the test and return to idle.
- [ ] Verify translated captions and model-invoked overlay tools during live Realtime playback.
  Native caption scheduling and HY-MT2 publication pass. Realtime preserves speaker source,
  so Show transcript and Show agent response apply independently; live listening remains separate.
- [x] Simplify Settings to the supported OpenAI and local routes, preserve drafts and truthful
  feature state, remove irrelevant controls, keep transfer/custom endpoints hidden, and verify
  with native UI/accessibility.
- [x] Complete full validation and signed Release host installation. Virtual-camera activation
  and QuickTime device acceptance passed after the user completed the Media Extension update.
  Future system-component changes still require explicit operator action.
- [x] Version the camera extension independently of host UI/AI changes. Preserve signed identity,
  protected replacement/rollback, and host-generation checks while validating each component version
  independently. An unchanged enabled extension must remain usable across a host-only update.

## Current status

- Build 38 aligns Whisper and vision around Size, description/download size, and Model controls,
  centers captions at the bottom, and uses only AI Camera in the top-left status label.
  Gesture label visibility has one control in Overlays; detector and box controls remain available.
- Live camera publication and near-real-time translated captions are user-confirmed on build 37.
  Follow-ups: [multiple caption languages](https://github.com/kortexa-ai/aicamera/issues/50), with
  original transcription as a language track, and [mute-aware caption privacy](https://github.com/kortexa-ai/aicamera/issues/51).
  AI Camera now owns a persistent privacy mute: held fist or the menu/settings control silences
  its microphone output, stops the agent, and clears visible/pending speech. Manual unmute starts
  fresh capture. Receiving apps must use AI Camera Microphone; detecting their own internal mute
  switches remains future integration.
- Native-model shutdown now closes admission, cancels pipeline work, waits for cached and still-live
  replaced Whisper/HY-MT2 clients to release native contexts, then permits AppKit termination.
  Public-fixture checks cover loaded models and cancellation during loading with retained owners.
- Realtime now has deliberate held-victory/menu activation and held-fist privacy mute. Enabling
  its configuration stays separate from activation. Input is closed during replies and reopens
  after both reply outputs drain; the same session retains conversation context. Call demand is
  independent of agent demand. A change of microphone routing stops the agent for an explicit restart.
- Next: live overlay tools, then multilingual captions. Synthetic event/media validation remains
  the default acceptance path; live gesture/provider/call acceptance is a separate check.

- Build 37 aligns Whisper and translation model controls, adds hardware-gated Whisper Large v3,
  and wraps camera extension recovery guidance. An enabled-but-unpublished camera no longer
  implies a required reboot; only an explicit pending-reboot activation result requests one.

- Build 36 cancels pending caption translations on Talk Stop/failure while the camera pipeline
  stays active, and preserves final translation after normal completion. Retired tool-result errors
  cannot close a newer conversation. Synthetic native checks cover the distinct completion paths.

- Build 35 disables unsupported transcription during settings migration without reading Keychain
  or switching providers. It preserves old metadata, privacy grants, and independent local/Realtime
  features. OpenAI or Local Whisper must be selected explicitly to enable transcription again.

- Build 34 preserves user/AI speaker identity through Realtime caption routing. Each display switch
  controls its own source, translations have independent revisions, and new-turn/Stop invalidation
  rejects retired work. Native tests cover switch combinations and interleaved translated captions.

- Build 33 bounds overlay logs and frame messages, rejects retired script output, and reloads
  documents on replacement/Clear to release script state. Synthetic native pixel checks pass;
  standalone public tool probes currently fail closed because their Keychain access is unavailable
  without user interaction. Installed-app connection and prior listening checks remain valid.

- Build 32 simplifies the OpenAI/local Settings implementation, keeps vision setup visible while
  off, disables unsupported loaded conversation/video routes without deleting their metadata,
  and hides the manual overlay script editor in Release. Settings transfer remains hidden.

- Build 31 reuses serial local detector workers and validates tensor shapes before allocation. Native checks pass for YOLO Tiny and RF-DETR Medium/Large, including cache identity, UI responsiveness, cancellation, recovery, and removal. Warm fixture inference measured about 7/40/67 ms respectively; first RF-DETR initialization/inference depends on filesystem/Metal cache state. The signed host passes local camera, gesture, and manual three.js composition acceptance and is back at idle. Settings and Realtime tool/caption acceptance remain.
- Build 29 adds a separate Codex login through the installed official CLI, managed refresh, explicit API-key/Codex selection, and a silent public Realtime connection test. It preserves desktop credentials and never silently falls back to the API key. Build 26 added embedded Whisper and shared verified model downloads; build 25 corrected translation text and reuse; build 24 moved Realtime onto host-owned PCM.
- Build 30 corrects truncated PCM conversion by delivering only the requested input frames, retaining the speech converter through a response, and draining its tail. Synthetic checks preserve exact duration and continuous pitch at 44.1/48 kHz; the user confirmed normal playback in a second spoken turn. Codex sign-in, refresh, and audible replies pass. Tools and live translated-caption acceptance remain open. Native local translation and public-fixture Whisper checks pass. Host updates preserve the validated build-12 HAL driver without reinstalling it.
- Build-12 microphone acceptance passed four normal cycles, short-lived clients, two simultaneous clients with `0 → 1 → 2 → 1 → 0` demand, forced client exit, local-test takeover, and host quit/relaunch while demand remained active. Callback flow, physical Yeti acquisition, prompt teardown, and return to idle all passed without recording media.
- A bounded QuickTime check exposed and selected **AI Camera** without recording, but the build-10 extension could not deliver camera demand to the host. The extension runs inside `cmiodalassistant`, whose service container is isolated from the GUI user's app-group container; sandbox logs confirmed that the shared JSON-file transport is not usable across those processes.
- Build 13 replaces that file transport with a bounded timestamped `NSData` snapshot on the read-only CoreMediaIO custom device property `4cc_aicd_glob_0000`. The host resolves the camera by stable UID, reads the raw property bytes through the legacy C API, and rejects missing, malformed, future-dated, or stale snapshots. Build 14 preserves that behavior and passes 89 Swift tests, full non-installing validation, the strict and sanitizer HAL harnesses, an unsigned four-target build, strict Release signing without `get-task-allow`, and `git diff --check`.
- Xcode automatic signing exported build 14 with the existing Developer ID Application identity and app-specific direct-distribution profile. Apple notarization submission `a790793d-5572-4bdd-b7e5-6aedaa3936eb` was accepted with no issues; the ticket was stapled and validated, strict nested signature verification passed, and Gatekeeper reports `Notarized Developer ID`. The resulting ZIP is the current distribution candidate, not yet the planned installer package.
- After the explicitly approved restart, retired camera extension build 10 was removed. Build 13 is the only active enabled generation, its provider process runs under `cmiodalassistant`, and **AI Camera** is published at its stable UID. A native probe verified that `aicd` is present on the device's global/main address, is read-only, returns bounded raw `NSData` bytes, and reports a fresh idle aggregate count of zero.
- Signed live acceptance passed normal and repeated camera cycles, two simultaneous QuickTime source clients, combined camera-plus-virtual-microphone demand, local-test takeover, forced camera-client exit, and host quit/relaunch while camera demand remained active. CoreMediaIO correctly kept aggregate camera demand at 1 until the final source client closed. Final `aicd` and `aicc` counts are zero, physical camera and microphone inputs are released, all bounded clients have exited, and the build-13 host is running idle.
- Remaining acceptance covers controlled extension freshness, permission recovery, login behavior, the audible distribution-candidate check, and recording those final results. These checks do not block preserving the reviewed automatic-lifecycle implementation in Git.

## Immediate work — close automatic lifecycle

- [x] Install the strict-signed build-12 host and HAL driver with explicit approval, reload Core Audio, and leave the camera extension at build 10.
- [x] Complete the bounded build-12 microphone demand matrix and verify host start, prompt teardown, physical-device release, multi-client levels, crash cleanup, takeover, and host relaunch.
- [x] Diagnose the camera-demand blocker and replace the cross-user app-group file with a read-only custom CoreMediaIO property.
- [x] Complete full non-installing validation and strict Release signing for build 13.
- [x] With separate explicit approval, install the build-13 host and submit activation of its build-13 camera extension without replacing or reloading the validated build-12 HAL driver.
- [x] With explicit approval, restart macOS, remove build 10, publish build 13, and verify the idle read-only `aicd` property before opening a camera client.
- [x] Verify camera-only, microphone-only, simultaneous, and multi-client external demand with bounded native clients.
- [x] Verify that any external camera or microphone client cancels both local tests before client capture starts.
- [x] Verify cross-lane handoff, forced client cleanup, host-absent recovery, and final physical-device release.
- [ ] Verify camera property freshness after a controlled extension crash/restart, permission loss and recovery, and login behavior.
- [ ] Repeat the short audible Yeti/HyperX check for the final distribution candidate.
- [ ] Complete the remaining checks above and record their signed results in `VALIDATION.md`.

## Product backlog

Items inside a section are not priority ordered. Work must continue to satisfy the safety and privacy constraints at the end of this file.

### Installation, onboarding, and product identity

- [x] Improve first-install and update guidance for enabling the media extension. Detect approval state, give an explicit step-by-step path, and always offer to open the relevant System Settings/Preferences page when macOS permits it.
- [x] Create a production app icon and use the same canonical asset in Finder, Login Items, Extensions, the popup header, Dock, App Switcher, and Settings. The app icon shown inside the popup must not drift from the bundled application icon.
- [x] Use the canonical production icon in the reusable About window.
- [x] Derive a clear monochrome macOS template image for the menu-bar/system-tray item from the same visual identity. Verify the tray glyph and full-color app icon look like one product at standard and Retina sizes.
- [x] Keep the menu-bar host accessory-only, but show its production icon in the Dock and App Switcher while Settings is open; return to accessory-only behavior when Settings closes.
- [x] Treat **Command-Q** from Settings, Preview, or About as **Close Window** so the camera service remains available. Show a compact three-second reminder with the canonical app icon and an explicit **Quit** action; deliberate Quit actions must still terminate immediately.
- [ ] Add a quick status indicator to the menu-bar icon for **attention needed**, **idle**, **camera in use**, **microphone in use**, and **error**. Define an unambiguous combined camera-and-microphone state.
- [ ] Add GitHub release update checks for production/release builds only. Development builds must not poll for updates, and update checks must not install anything without an explicit user action.

### Control center layout and visual design

- [x] Move camera and microphone tests into a dedicated resizable Preview window. Keep the popup
  free of media, with five quick controls above device setup and Preview in the footer.
- [x] Show processed frames in Preview with aspect-fit rendering for both local tests and external
  camera use. Opening the window alone does not request capture; closing it releases local tests.
- [x] Preserve external-client priority: a client takeover cancels local tests and their stale media
  before serving the client. Local test controls stay disabled during external use.
- [x] Keep the bounded 10 Hz microphone meter below the large preview during local microphone tests.
  Hide and clear it on takeover or test completion.
- [x] Use a compact product-icon/title header and an accessible status dot: yellow for setup,
  green for ready, red for active camera/microphone capture. Keep activity text out of the header.
- [x] Adopt the compact Kortexa Control Center-inspired popup silhouette: a native transient menu-bar popover with rounded corners, a menu-bar pointer, approximately 400-point base width, content-driven height, and a distinct footer. Prefer the native `NSStatusItem` plus `NSPopover` behavior (or an equivalent native implementation) over simulated window chrome.
- [x] Add **About · Quit** at the right side of the footer, with **About** immediately to the left of **Quit**. About must close the popup and open or foreground one reusable, titled, closable About window.
- [x] Give the About window the same visual hierarchy as the Control Center reference: centered 80-point production icon, bold **AI Camera** name, one-line purpose subtitle, Kortexa website link, and adjacent version/build and MIT-license rows. Keep device readiness and privacy details in the main controls and Settings. Return the app to accessory-only behavior when the last standalone window closes.

### Profiles and production packaging

- [x] Remove the **Kortexa Local** preset from Settings in production/release builds; keep development access where useful.
- [x] Add validated import and export of versioned profiles so development presets such as **Kortexa Local** can be moved between installations quickly.
- [x] Keep secrets out of ordinary profile exports. Export secret references by default and require a separate explicit secure flow for any secret transfer.
- [x] Ship an importable example OpenAI profile with OpenAI endpoint definitions and an `OPENAI_API_KEY` environment/Keychain reference. Never include a real API key in the repository or app bundle.
- [x] Replace the raw Profile JSON editor with validated individual profile, model, vision, conversation, overlay, import, export, reload, and reset controls.
- [x] Restrict normal Settings choices to models and media services verified as running on a development service; store the Kortexa API credential beside those AI controls in Keychain and keep maintenance credential-free.
- [x] Restore a mutually exclusive voice-pipeline selector for separate ASR/agent/TTS, canonical OpenAI Realtime, or a custom OpenAI-compatible Realtime endpoint.
- [ ] Add the bounded WebRTC conversation session described in `docs/realtime-conversation.md`: canonical OpenAI Realtime, self-hosted OpenAI-compatible Realtime, and an explicitly experimental ChatGPT/Codex subscription provider; keep separate ASR, agent, and TTS stages as the selectable fallback.
- [x] Add explicit agent start/stop with server VAD and bounded utterances: connect with microphone egress closed, admit audio only while armed, pause during replies, and route bounded PCM to the call and local output.
- [ ] Add Realtime Settings for provider, endpoint, model, voice, and Keychain-backed credentials or OAuth; profiles store secret references only. Test the standard protocol against canonical OpenAI and `api.server`.
- [x] Normalize public Realtime function calls into one bounded local `render_overlay`/`clear_overlay`
  executor. API-key and separate Codex login use this same public contract; private delegation is
  outside the current product. Live voice-to-tool acceptance remains in the current priorities.
- [x] Redesign AI & Advanced around an OpenAI-first Conversation flow with masked Keychain credentials, current Realtime model/voice choices, collapsible Tools, Vision & Gestures, and Overlays groups; hide profile and a development service-specific controls from the normal UI.
- [x] Add an advanced compatible Realtime path, including the public Kortexa `/v1/realtime/calls` endpoint and an isolated Hermes selector that sends `X-Kortexa-Agent: hermes` only when explicitly enabled.
- [x] Securely download the compact YOLOv3 Tiny model from Apple's Core ML gallery, verify its pinned SHA-256 artifact integrity, and run bounded in-process object detection without network inference before enabling the Built-in control.
- [x] Reorganize Settings into General, AI, and Privacy; use native switches for feature groups; move Virtual Devices to General; remove the Processing and credential-maintenance copy; and derive privacy disclosure from active local and external routes.
- [x] Add optional in-process HY-MT2 1.8B transcript translation through pinned llama.cpp, with an explicit integrity-checked 1.1 GB Q4_K_M model download, removal, source/target language settings, and bounded work outside the real-time audio callback path. Do not use Tencent's smaller 1.25-bit or 2-bit artifacts until their required tensor layout and STQ kernel are available in a stable upstream llama.cpp release.
- [x] Present toggled AI feature groups as consistent cards, preserve their header layout while disabled, and use the same local-model status/download/removal pattern for HY-MT2 and YOLOv3 Tiny.
- [x] Make OpenAI transcription independently usable with Conversation disabled, default to `gpt-transcribe`, share the masked Keychain API key with OpenAI Realtime, and suppress duplicate batch ASR while Realtime is active.
- [ ] Decide whether AI Camera will adopt AGPL-3.0 or obtain an Ultralytics Enterprise license before offering the official YOLO26n Core ML model; Ultralytics explicitly licenses its trained YOLO26 models under those terms, which are not an automatic fit for this MIT project.
- [x] Offer Apache-2.0 RF-DETR Medium and Large as integrity-checked downloadable Core ML detectors, keep YOLOv3 Tiny as the lightweight option, and select Medium by default while identifying Large as the higher-accuracy choice for M4 Pro / M3 Max-class hardware and above.

### Development and production isolation

- [ ] Add a co-installable **AI Camera Dev** product flavor so development can continue while the production app remains installed in `/Applications`. Give it a distinct app name and bundle identifier; camera-extension identifier, Mach service, stable device/stream UUIDs, and virtual-camera name; HAL bundle/install name, factory UUID, plug-in/box/device/model identifiers, and device name; plus a distinct app group, Application Support/profile path, generation marker, defaults domain, Keychain service, and login item.
- [ ] Keep feeder authorization flavor-specific: the production extension must accept only the production host and the development extension only the development host, with the existing team, path, hardened-runtime, entitlement, and PID-version checks intact. Dev and production demand signals, profiles, permissions/status, secrets, and component maintenance actions must never cross.
- [ ] Add explicit build/run/package flavor selection and clear visual **Dev** identity. Ordinary development builds and tests must not install or activate either flavor automatically. Validate side-by-side install, upgrade, client selection, crash, repair, and removal; prove that every development maintenance action leaves the production app, marker, driver, extension, login item, profile, Keychain items, and live virtual devices unchanged.

### Natural interaction and conversation UX

- [x] Expose activation mode and wake-window controls in Settings; they are currently Profile JSON options.
- [x] Make local Apple Vision gesture classification palm-relative and rotation-independent, with deterministic open-palm, fist, point, victory, and pinch tests and an individual Settings toggle.
- [ ] Show speaker-labelled user transcripts and agent responses in one bounded conversation view and optional overlay.
- [ ] Let the agent choose a voice only from a configured local allowlist, with a deterministic fallback.

### AI-generated camera composition

- [ ] Define bounded structured overlay instructions for text, shapes, boxes, and locally rasterized SVG.
- [ ] Reject external resources, oversized SVG, excessive element counts, and stale overlay work. Model-rendered scripts are covered by the section below.
- [ ] Continue sending clean pre-overlay frames to inference so generated content cannot recursively contaminate vision input.
- [ ] Run an end-to-end `snappy` test that adds random annotations and verifies composed pixels in an independent virtual-camera client.

### Future live face filters and conversational graphics

Follow-up direction: local face landmarks (MediaPipe is a candidate) anchor generated three.js
filters, such as a moving hat, while spoken questions can produce floating graphics such as a pie
chart. Composite these into the outgoing camera image so other call participants see the result.
Evaluate tracking stability, occlusion, frame freshness, and bounded landmark access after the
current OpenAI/local completion work. See [the follow-up design item](https://github.com/kortexa-ai/aicamera/issues/45).

### Model-rendered overlay scripts (transparent render layer)

Design: `docs/overlay-script-renderer.md`. The model gets a bounded `render_overlay` tool; the script (three.js, WebGL2) runs in a hidden in-app WKWebView and its transparent frames are composited onto the published camera frames.

- [ ] Keep the cheaper structured/SVG overlay path for simple labels; use script rendering for rich 2D/3D/animated content.
- [x] Phase 0 spike: the `AICameraOverlaySpike` dev tool proves hidden WKWebView + three.js + `readPixels` to `CVPixelBuffer` + alpha composite at 30 fps. Results and WebKit/SDK quirks are recorded in `docs/overlay-script-renderer.md`.
- [x] Add `OverlayScriptRenderer` (on-screen at near-zero window alpha so WebKit keeps rendering invisibly, bounded `window.AICamera` bridge, non-persistent storage) and a lock-based single-slot overlay-frame mailbox (`LatestValueSlot`); composite only fresh frames in `OverlayRenderer`; keep the inference path clean. Manual camera-test acceptance confirmed the live camera, rotating cube, and ring composite correctly.
- [x] Add the public Realtime bounded tool executor described in `docs/realtime-conversation.md`;
  expose `render_overlay(script, ttlSeconds?)` and `clear_overlay()` with canvas dimensions,
  transparency, bridge, and coordinate contracts; tear down on lane stop, cancellation, and expiry.
  Legacy chat-completions tool support is outside the current product.
- [x] Add `overlays.script` profile settings (`enabled`, `maxScriptBytes`, `maximumFps`, `defaultTTLSeconds`, `maximumTTLSeconds`, `allowSceneData`); scripts are memory-only and never persisted.
- [x] Add a dev-only overlay script box to the control center (visible during a local camera test when script overlays are enabled) for acceptance without a model round-trip.
- [ ] Add a web-content crash watchdog (no fresh frame means the overlay disappears), memory caps, and an end-to-end acceptance test where an independent virtual-camera client sees the composed script pixels.
- [ ] Keep a hosted Chromium renderer (Electron/ElectronBun) as a swap-in option behind the same protocol if WebGPU/typegpu is required later.

### Agent camera and microphone tools

- [ ] Define the smallest useful tool set, such as scene snapshot requests, stage enablement, mute, gain, and supported hardware controls.
- [ ] Require explicit capabilities and user-visible state. An agent must not silently change hardware selection, privacy grants, recording, installation, or remote egress.
- [ ] Bound tool frequency, arguments, media exposure, and result sizes. Record only non-media audit events unless recording is explicitly enabled.

### Public repository readiness

- [ ] Rewrite the README for a public audience: concise product purpose, supported macOS versions, privacy and host-absent behavior, virtual-device installation and approval overview, pure-passthrough quick start, screenshots after the visual redesign, architecture links, local build/test commands, release downloads, known limitations, and support paths.
- [ ] Review the existing root MIT `LICENSE` for the intended copyright holder and year, then expose the same license information in About, the README, installer metadata, and release artifacts.
- [x] Add `CONTRIBUTING.md` with the repository layout, supported toolchain, setup/build/test commands, code style, real-time and media-privacy rules, system-component safety boundary, test and documentation expectations, issue/PR guidance, and a strict ban on committed credentials, signing material, or captured media.
- [ ] Before changing repository visibility, audit tracked files and Git history for secrets, signing identifiers/material, machine-specific paths, generated products, private media, and third-party license obligations. Keep local signing/configuration files ignored and document any required history cleanup before publishing.

### Distribution

- [ ] Produce a Developer ID-signed, hardened, notarized, and stapled production build. Add a step-by-step release guide that separates the operator's Apple Developer tasks from automated checks: enrollment/access, identifiers and capabilities, certificates and provisioning profiles, local notary credentials, archive/sign verification, notarization submission, stapling, and Gatekeeper assessment. Guide the operator interactively through each Apple portal or Keychain step without committing or printing credentials, team identifiers, or signing identities.
- [ ] Create a Developer ID Installer-signed, notarized, and stapled installer package for GitHub Releases while keeping the app and every nested component Developer ID Application-signed. It should install or upgrade only **AI Camera.app** in `/Applications`; package scripts must never activate the camera extension, copy or reload the HAL driver, change defaults, or hide an approval/reboot. Preserve the existing protected-transaction guarantees (strict nested identity checks, root-private same-volume staging, rollback, generation marker, and immutable destination) or provide and validate an equally strong installer transaction. Publish checksums, versioned release notes, and matching uninstall/repair instructions.
- [ ] Add a repeatable release-packaging command that fails closed on wrong versions, bundle/component identity mismatches, missing hardened runtime, debug entitlements, unsigned nested code, wrong Application-versus-Installer certificate class, failed notarization/stapling of the final distributed container, or a dirty/unreviewed release input. Keep Apple credentials in local Keychain/environment references only.
- [ ] Complete clean-machine installer, first-run approval, virtual-device publication, upgrade-in-place, rollback, repair, uninstall, reboot-boundary, and Gatekeeper acceptance. Confirm package execution itself performs no camera-extension activation and no HAL copy or Core Audio reload.
- [ ] Verify GitHub update-check behavior in production and confirm that development builds make no update requests.

## Completed milestones

### Foundation and media paths

- [x] Create the private repository, generated Xcode project, Swift core package, scripts, and CI-safe validation.
- [x] Include a tracked root MIT license.
- [x] Define versioned configuration and model-adapter protocols without fixed hardware, endpoint, team, or credential assumptions.
- [x] Implement bounded AVFoundation camera capture, inference sampling, Vision gestures, overlays, and the CoreMediaIO source/feeder extension.
- [x] Implement bounded physical microphone capture, ASR windows, agent routing, streamed speech mixing, and the duplex Core Audio HAL loopback device.

### Control center, hardening, and automatic lifecycle

- [x] Add the menu-bar control center, persistent virtual-device health/source rows, Settings, permission guidance, installation, repair, update, and removal flows.
- [x] Make new profiles pure passthrough and keep AI, conversation, transcription, mirroring, and overlays opt-in.
- [x] Resolve system defaults through loop-safe direct-hardware filtering and deterministic fallback warnings.
- [x] Publish bounded camera and microphone client demand and reconcile both hardware lanes independently.
- [x] Add idle-only camera and microphone tests with client priority, processed preview, bounded level meter, clean takeover boundaries, and per-lane stale-callback gates.
- [x] Add optional launch at login with `SMAppService.mainApp`.
- [x] Add fail-closed profile handling, strict feeder authorization, bounded real-time paths, protected signed installation, and build/update detection.
- [x] Replace explicit AVAudioEngine input-device assignment with exact-UID `AVCaptureAudioDataOutput` capture and a two-slot, size-capped processing handoff.

### Acceptance completed so far

- [x] Pass strict unit, build, script, installer-rendering, HAL harness, ASan/UBSan, and TSan validation.
- [x] Pass development-signed build-9 placeholder, live camera, stop/restart, simultaneous-client, microphone loopback, ASR/agent/TTS, and barge-in acceptance.
- [x] Install the strict-signed build-10 host and pass local camera/microphone test, simultaneous-test, stop-one-lane, live preview/meter, and inline Settings navigation checks.

## Non-negotiable constraints

- Camera and microphone lanes remain independent and start only for matching external demand, an explicit local test, or an explicitly activated agent microphone.
- Network inference never runs on capture, CoreMediaIO, HAL, or other real-time callbacks.
- All media and network queues remain bounded; stale work is replaced, dropped, expired, or cancelled.
- Raw camera and microphone media is memory-only unless the user explicitly enables recording.
- Remote egress remains fail-closed and requires configured privacy grants, approved destinations, and explicit AI stages.
- Secrets use environment-variable or Keychain references and are never committed to profiles, examples, logs, or documentation.
- Automatic reconciliation never requests permissions, installs components, changes system defaults, or hides required approval/reboot steps.
- Feeder signing, team, path, runtime, and PID-version authorization must not be weakened.
- System installation, extension activation, driver reload, and reboot checks remain manual and approval-gated.

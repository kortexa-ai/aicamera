# Validation record

## Build 52: Codex login approval warning

- The Codex login description now shows a yellow, fully wrapped “Use at your own risk” warning.
  It distinguishes observed Realtime access from unconfirmed OpenAI approval and states that
  OpenAI's response is unknown. The API-key description and authentication behavior are unchanged.
- Full local validation passes: 182 Swift tests, rendered-installer metadata checks, unsigned
  app/framework/extension/driver builds, plist/entitlement checks, and the HAL harness.
- Signed installed Settings inspection confirms the complete yellow warning is visible without
  clipping. Protected installation and strict source/installed signature verification pass;
  the host and generation marker report 52. Camera extension 44 has the same CodeDirectory hash
  and registration roster as before the host updates; the embedded audio driver remains 12.

## Build 51: quick controls and a simpler desktop UI

- Full local validation passes: 182 Swift tests, twenty rendered-installer metadata cases,
  unsigned app/framework/extension/driver builds, plist/entitlement checks, and the HAL harness.
- Seven runtime-control unit tests cover translation's transcription dependency, independent
  caption/gesture generations, Off/On stale-result rejection, actor-hop scene writes, and readiness.
  The real coordinator passes synthetic cancellation-insensitive ASR/translation, bounded queued
  admission, late-error suppression, independent agent captions, disabled gestures, and mute priority.
  A prior variant fails the new overlapping-ASR regression; the corrected implementation passes.
  The existing native caption-privacy harness also passes.
- Native hotkey fixtures pass registration, action mapping, held-key suppression, unknown events,
  unregister/re-register, without observing keyboard input. In the signed host, Control–Option–M
  worked with Finder focused, and Control–Option–A reached Listening and then stopped the agent,
  releasing its microphone. No new keyboard-monitoring authorization was requested.
- Installed UI inspection verifies the five quick controls, header cog/readiness dot, plain footer
  actions, and absence of redundant processing/device headings. The large resizable Preview is
  flush with its top/side edges and has no idle/footer prose. About retains product artwork,
  purpose/link, version, and license. In-app artwork loads the bundled icon without Finder badges.
- Preview camera/microphone tests and the live level meter work. Closing Preview releases local
  tests. With QuickTime using AI Camera and AI Camera Microphone, Preview displays processed video
  and disables local tests. Pausing all three optional quick features and closing Preview leave
  both external media lanes active. No Movie Recording recording was started or saved.
- Settings, Preview, and About share Dock visibility. Closing Settings/About while Preview remains
  keeps the Dock icon; closing the final standalone window returns to accessory mode. Command-Q
  from About closes that window, shows the canonical-logo reminder, and keeps the host running.
  The reminder retains its timeout and explicit Quit action.
- Protected installation leaves source, installed host, and the generation marker at build 51.
  Strict nested signature checks pass and the installed Release has no debug entitlement.
  Camera extension 44 retains its CodeDirectory hash and unchanged system-extension registration
  roster across these host updates; the embedded audio driver stays at 12. No system component
  was installed or activated. The user confirmed that updates no longer require extension reapproval.
- Final quick states are restored to Transcribe/Translate/Gestures on, Mute off, and Agent off.
  The intermittent pre-existing empty local translation warning is tracked in issue 55; its source
  text was not retained and its root cause is not yet established.


## Build 45: host updates preserve the enabled camera extension

- All 175 Swift tests and full build/script/metadata/HAL validation pass. Twenty additional temporary-plist cases execute the actual rendered installer metadata guards, including different valid host/component versions and rejection of missing, malformed, or altered versions. The camera target must declare both its own build and marketing version.
- Protected installation upgraded the host from 44 to 45 while preserving camera extension 0.1.0/44. Source and installed host strict nested signatures pass. Both host bundles and the protected host marker report 45; their embedded camera extensions report 44.
- The embedded camera extension's CodeDirectory hash and Info.plist hash match the pre-update bundle. All AI Camera system-extension registration rows, including the enabled 44 row, are unchanged after host installation. No extension activation/deactivation/update, driver installation, or authorization prompt was requested.
- Installed menu inspection shows Camera Ready and Microphone Ready, with no camera Update action. QuickTime New Movie Recording selected AI Camera and AI Camera Microphone; the host served both external lanes with Camera Ready and no extension replacement. The temporary preview was closed without recording and the agent stopped; the host is unmuted and idle. Real extension-code or protocol updates still require advancing its component version and separate operator acceptance; signing does not bypass macOS replacement approval.

## Build 44: closed-fist mute takes precedence over pinch

- The new regressions reproduce the previous failure: 72 compact closed-fist variants with thumb–index proximity (three thumb offsets, four rotations, three scales, mirrored/unmirrored hands) classify as pinch, and the held victory → fist sequence emits no mute. All these checks pass after compact four-finger flexion is tested before thumb–index contact.
- All 175 Swift tests and the full unsigned build/script/metadata/HAL validation pass. Pinches with an extended index, a curled index and other fingers extended, or thumb–index contact outside the compact palm remain pinches.
- The native caption-privacy harness now sends the actual classification of a synthetic tucked-thumb fist through the Realtime-enabled coordinator, checks exactly one start and mute, and verifies muted speech handling. It passes without capture, credentials, network, or model weights.
- Protected signed Release installation and relaunch pass. Strict nested signatures verify for source and installed bundles; both bundle versions and the protected generation marker report 44. No camera extension or audio driver was installed or activated.
- Franci confirmed physical victory activation in build 43. Physical closed-fist acceptance after this correction remains a separate check; no user media was recorded to develop the fix.

## Build 43: outgoing agent status and usable held gestures

- Full `scripts/validate.sh` passes 171 Swift tests, the unsigned four-target build, metadata/script checks, and the HAL harness. Native caption privacy also verifies exactly one victory start and fist mute through the real coordinator with Realtime enabled.
- A regression reproduces the prior activation mismatch: one partly hidden folded fingertip could allow a visible victory label while its minimum confidence vetoed activation. Aggregate confidence of all 14 required usable landmarks admits that clear synthetic held pose; uncertain, missing, invalid, stale, brief, conflicting, and repeatedly held input remains bounded or rejected.
- The native compositor harness checks all seven outgoing status states, clear title-bar space, Show Status suppression, and deterministic animated orb geometry. Its saved images contain generated solid backgrounds only. Hand inference has a separate bounded queue from JPEG preparation.
- Signed installed-app acceptance with QuickTime New Movie Recording selected both AI Camera and AI Camera Microphone. The menu's Start agent reached Listening while both virtual-device clients were active. Stop preserved the call media lanes. Mute retained the camera, removed microphone demand from physical capture, hid captions, and disabled the agent; explicit Unmute restored availability. The temporary preview was closed without starting a recording, leaving the agent off and the original unmuted preference restored.
- Strict nested signatures pass for the Release source and installed bundle; both versions and the protected installation marker are 43. No camera extension or audio driver was installed or activated.
- Physical held-victory acceptance and a user-heard response after this confidence change remain separate; the unattended test proves installed connection during actual external demand, not recognition of a person's hand. No camera or microphone buffers were saved.

## Build 42: deliberate Realtime activation and consecutive turns

- Full `scripts/validate.sh` passes 168 Swift tests, the unsigned four-target build, metadata/script checks, and the HAL harness. The demand tests cover agent activation during camera-only demand, release of only agent-owned capture, preservation of call microphone demand, privacy mute with video retained, permission/configuration denial, and explicit restart on call routing changes.
- The production WebSocket session passes an in-memory socket fixture: unarmed/pre-arm/old-turn PCM denial, consecutive turns without reconnecting, response/playback input gating, tool continuation, duplicate/late audio and tool rejection, and cancellation while connecting. Continuous silence does not expire an explicitly started agent; actual utterances and responses remain bounded.
- The actual local reply monitor passes generated offline PCM/gain and mute/reset silence at 44.1/48 kHz. A 100 ms all-zero buffer on the current physical output verifies the hardware playback-drain callback without capturing input or requiring a listener. The host waits for call and local reply output completion before rearming.
- Native caption privacy and the existing controlled caption scheduling/speaker/cancellation regressions pass after integration. Gesture tests cover dwell, confidence, stale frames, latching, and direct victory-to-fist transitions; capture timestamps also fence queued controls after a camera restart.
- Installed UI inspection confirms Start agent, Agent muted while privacy mute is on, explicit Unmute restoring availability, and the gesture guidance in Settings. The app remains idle, with the agent off and the original unmuted preference restored. Physical gesture and live provider/call acceptance remain separate.
- Protected signed Release source/installed strict nested signatures pass; both bundle versions and the protected installation marker report 42. No driver or camera extension changed.
- One optional public Codex Realtime-to-overlay probe stopped at the guarded credential read: Keychain returned OSStatus -25293 (interaction required/unavailable to this helper). No login prompt, credential refresh, microphone capture, network session, or recorded media resulted. Live overlay/provider acceptance remains open.

## Build 40: orderly native-model shutdown

- Full `scripts/validate.sh` passes 161 Swift tests, the unsigned four-target build, metadata/script checks, and the HAL harness.
- The native shutdown harness uses the actual AppKit termination delegate and cached Whisper Base/HY-MT2 clients, with owners retained through process exit. Public JFK audio and synthetic translation pass. Both the warmed-engine and cancel-during-load processes print `SHUTDOWN PASSED` and exit normally with code 0. Repeated shutdown is safe; retained clients and controller caches reject later inference.
- UI Quit posts an AppKit event before entering the termination modal loop, which keeps Swift cleanup able to run. The installed signed host quits from its menu without hanging and relaunches at idle. No operator speech or camera presence was required.
- Protected signed Release installation completed; source and installed strict nested signatures pass, and both bundle versions plus the protected installation marker report 40. No driver or camera extension changed.

## Build 39: persistent privacy mute

- Full `scripts/validate.sh` passes 161 Swift tests, the unsigned four-target build, metadata/script checks, and the HAL harness.
- The native caption-privacy harness passes immediate clearing, muted admission, cancellation-insensitive transcription/translation across mute and unmute, fresh recovery, and the real coordinator gesture callback. Existing controlled Realtime caption scheduling, speaker routes, and Talk cancellation/retry checks also pass.
- Signed Release installation used the protected transaction. Source and installed strict nested signatures pass; both bundle versions and the protected generation marker are 39. No driver or camera extension was changed.
- Installed menu and Settings inspection confirms Mute/Unmute, the caption privacy status, and disabled Talk/microphone testing while muted. Mute survives Quit and relaunch. Explicit Unmute restores availability. Tests restored the initial unmuted state with both media lanes idle.
- Held gesture confidence, dwell, latching, direct victory-to-fist changes, neutral release, stale timestamps, and gaps are tested synthetically. No camera/microphone samples were captured or saved for this acceptance. Actual receiving-app audio/gesture acceptance remains manual; this build does not detect another app's internal mute switch.

## Build 38: consistent model controls and caption placement

- Full `scripts/validate.sh` passes 153 Swift tests, the unsigned four-target build, metadata and
  script checks, and the HAL harness after the final user refinements. No system component changed.
- Protected signed Release installation completed. Source and installed strict nested signatures
  pass; both app versions and the protected installation generation marker report 38.
- Installed Settings/accessibility confirms Whisper, its Base/Small/Large segmented Size selector,
  the description with GB download size, and Model status/actions. Vision uses the same order with
  Tiny/Medium/Large and YOLOv3/RF-DETR family information. Downloaded model choices are preserved.
- Show gesture labels appears once under Overlays. Object detection remains enabled, Gestures
  remains under Vision & Gestures, and the user's Show detection boxes off setting is preserved.
  No inference or display preferences were changed during the review.
- Synthetic native renderer review at 1280×720 and 640×480 confirms AI Camera at the top left and
  captions at the bottom center with an 18-point inset. Long captions retain their existing bounded
  single-line truncation. Generated gray frames and sample English/Chinese text were used; no
  captured media was saved. No GPU latency measurement or isolated compute window was needed.
- The user had confirmed working QuickTime camera output and near-real-time live translated
  captions on build 37. Build 38 resumed existing camera/microphone demand with that installed
  camera extension. Multilingual captions and calling-app mute privacy are tracked separately
  in issues 50 and 51; they are not implemented by this UI change.


## Build 37: camera recovery and local model selection

- Full `scripts/validate.sh`: 153 Swift tests, all four unsigned Xcode targets, metadata/script
  checks, and the HAL harness pass. No system component was installed by validation.
- Signed Release source and `/Applications/AI Camera.app` both report build 37 and pass strict
  nested signature verification. The protected installation generation marker reports 37.
- Installed Settings shows Base/Small/Large on M4 Pro, distinct tier descriptions, and matching
  Whisper/HY-MT2 Local model rows with green name/check/trash controls. Large download exposes
  progress and Cancel; Save stays disabled until the model is verified and ready.
- Hardware policy tests cover eligible M4 variants and M5 chips, base M4, older Apple chips,
  Intel, malformed names, and unknown hardware. Existing Base/Small saved values are unchanged.
- Native controller checks also pass actual M4 Pro detection and unsupported-hardware
  download/client refusal. Large completed its verified Settings download and the public JFK
  fixture checks: English 2.02 s and auto-detect 2.25 s for 11 s of audio; cancellation returned
  in 0.001 s. Silence, recovery, cached clients, and HY-MT2 coexistence pass with a combined
  peak resident footprint of 2.91 GB. The active Base setting was preserved. These fixture
  measurements are not guarantees for arbitrary speech or simultaneous camera processing.
- Read-only September 5 registration logs explain the missing camera: during replacement,
  launchd rejected the new CoreMediaIO job with error 37 (operation already in progress), then
  removed the old job. SystemExtensions still reported the replacement activated/enabled.
  The named service was absent, consistent with the user's QuickTime observation. No reboot,
  launchd reset, extension activation, or HAL change was performed for this diagnosis.
- Obsolete generated DerivedData trees, exported app bundles, four archives, six build 13/14
  distribution ZIPs, and old Debug app copies were removed at the user's request. Finder's
  bundle-identifier query returns only the installed app and the two current build products.
  Settings, model weights, local signing configuration, and OS-managed extension records remain.

## Build 36 Talk cancellation and final captions

Date: 2026-09-05

- A synthetic native check reproduced a delayed translation appearing after Talk-only cleanup
  while the coordinator remained active. The previous Stop test stopped the entire pipeline.
  Explicit Talk Stop/failure now cancels pending Realtime captions before transport teardown;
  normal completion lets final translation finish. Canceled event consumers and superseded
  transcript revisions cannot admit new translation work. A retired tool-result failure also
  checks its session generation before reporting an error or closing the current conversation.
- Controlled native checks pass active/pending cancellation with the coordinator still running,
  normal final translation after completion, retry, and canceled-event rejection. Existing
  speaker switches, interleaved captions, bounded scheduling, new-turn isolation, and pipeline
  Stop checks still pass. Actual HY-MT2 publication of synthetic user/AI captions also passes.
  No media, network, or credentials were used by the harness.
- Full validation passed 151 Core tests, the unsigned four-target build, and the HAL harness.
  The real-model rerun admitted a caption in 0.000032 seconds and published both translated
  speakers by 0.484 seconds with existing local caches. These synthetic timings are not a latency
  guarantee or live spoken acceptance.
- The protected passwordless transaction installed signed build 36. Strict source/installed
  signatures pass; bundle versions and the protected generation marker are 36. With a local camera
  test active, Codex Talk reached Listening and timed out on silence, releasing only Talk's microphone
  test. A subsequent explicit cancellation also retained the camera test. Stopping that test returned
  the host to idle. No system component was installed or activated. Live spoken caption/tool and
  playback-cancellation acceptance remain separate.

## Build 35 transcription migration

Date: 2026-09-05

- Startup, reload, and hidden import now disable unsupported transcription without looking for
  a Keychain credential or moving audio to another service. Strict public OpenAI base-URL matching
  rejects custom paths, ports, user info, query/fragment values, wrong adapters, and missing endpoints.
  Existing endpoint metadata and grants remain unchanged. Local Whisper, supported public Realtime,
  and independent caption/translation settings are preserved.
- Five additional Core tests cover supported/unsupported transcription, missing routes, exact
  metadata preservation, and Whisper with inert old endpoint metadata. Full validation passed
  151 tests, the unsigned four-target build, and the HAL harness without installing system software.
- The native harness compiles the actual configuration controller with no credential resolver.
  Disposable synthetic-file checks passed startup/reload/import, persisted disablement, idempotence,
  explicit OpenAI setup, local Whisper relaunch, and preservation of invalid files. The user's
  settings, credentials, network, and media were not used by the harness.
- The protected passwordless transaction installed signed build 35. Strict source and installed
  signatures pass; both bundle versions and the protected generation marker are 35. Native Settings
  and Privacy checks confirm the saved Codex, Whisper Base, translation, and local vision routes
  remain intact, with transfer/custom endpoints hidden. The app is idle with both capture tests
  stopped. No system component was installed or activated.

## Build 34 installed-app Realtime lifecycle

Date: 2026-09-05

- The signed installed host passed silent public Realtime connection tests with both the saved
  API key and the separate Codex login, without another credential prompt. API-key Talk reached
  Listening after cancellation of an earlier connection. Silence produced the expected no-speech
  error and released Talk-owned microphone capture. Stop during Listening retained a microphone
  test that had been started separately; stopping that test then returned the host to idle.
- Two short synthetic requests were played through the built-in speaker, selected for that
  playback process alone. Codex Talk reached Listening but detected no speech. This does not prove
  spoken request, caption, or model-invoked overlay behavior; the acoustic cause was not established.
  No audio routing defaults, device volume, Keychain permissions, or system components were changed.
- The original saved Codex route, model, voice, local Whisper, translation, and vision settings
  were restored and checked in Settings. Native accessibility confirmed both local capture tests
  stopped and Talk idle. Media was not recorded. Live speech, translated captions, overlay tool
  continuation, and playback cancellation remain separate acceptance checks.

## Build 34 Realtime speaker routing

Date: 2026-09-05

- Realtime previously discarded the transcript source, so AI replies followed Show transcript
  and never reached the Show agent response lane. The host now preserves the source. The coordinator
  routes user speech to transcript state and AI speech to agent-response state; each display switch
  applies independently. Translation revisions are separate per source, while work remains one active
  and one latest pending value. New turns cancel the old worker without allowing overlapping jobs.
- The native harness passes all four user/AI switch combinations, interleaved partials and finals,
  user translation during AI partial output, and AI translation without replacing the user caption.
  Controlled completions still verify supersession, nonblocking admission, new-turn invalidation,
  and Stop. Local HY-MT2 successfully publishes translated text for both speakers. This uses only
  synthetic text and no media, network, or credentials.
- Publication checks running state again after fetching the scene snapshot. Startup also checks
  again before scheduling expiry, so Stop cannot leave a late publisher or newly scheduled timer.

- Final full validation passed 146 tests and the unsigned four-target build. The native rerun
  passed all scheduling and speaker checks. With that run's local caches, admission took 0.000021
  seconds, the user translation arrived at 0.381 seconds, and both user/AI translated captions
  were published by 0.531 seconds. These are synthetic examples, not a latency guarantee.
- The protected passwordless transaction installed signed build 34. Strict source and installed
  signatures pass; source/installed versions and the protected generation marker are 34. Native
  accessibility confirms the host is idle with camera and microphone tests stopped. No system
  component was installed or activated. Live voice/caption/tool acceptance remains separate.

## Native Realtime caption scheduling

Date: 2026-09-05; host code from build 33

- A native coordinator harness passed partial/final publication, nonblocking admission while a
  translation is suspended, one active/latest pending work, superseded-result rejection, new-turn
  isolation, and Stop. Controlled completions deliberately ignored cancellation to exercise the
  coordinator's own guards. The actual HY-MT2 client then published synthetic English text as a
  Chinese caption: admission took 0.000045 seconds and the final caption arrived in 0.746 seconds.
  No microphone, camera, network, Keychain, or captured-media file was used.
- This check proves scheduling/publication for the existing shared transcript route. Review also
  found that Realtime events discard their speaker source, so AI replies use Show transcript and
  do not honor Show agent response independently. A separate routing correction is required before
  speaker-specific overlay acceptance can pass.
- AGENTS.md now records the process-local legacy Keychain guards required for unattended probes;
  no saved Keychain setting or ACL was changed.

## Build 33 overlay lifetime and message bounds

Date: 2026-09-05

- Script admission uses UTF-8 bytes and rejects nonfinite/out-of-range TTLs. Replacement, Clear,
  and expiry invalidate old pixels and reload the document, releasing previous script globals and
  timers. Navigation is restricted to the renderer document. Logs are rate-limited, bounded in
  memory, and no longer written to public unified logs or the unbounded diagnostic file. No existing
  diagnostic file was read or deleted during this work.
- The bridge publishes at most one unacknowledged frame. Native checks validate generation,
  increasing sequence, exact dimensions and encoded length before decoding. Opted-in scene updates
  have a 64 KiB bound, one active evaluation, and one replaceable pending value. Three regression
  tests cover pixels, stale generations/replays, payload bounds, booleans, fractions, and nonfinite
  sequence numbers. Full validation passed 146 tests and the unsigned four-target build.
- The production renderer's synthetic native harness passed UTF-8/TTL bounds, continuous
  publication, new-document isolation from an old timer/global, immediate replacement/Clear,
  rejection of late output, expiry, script-error recovery, coalesced scene updates, and stop/restart.
  First pixels arrived in 0.174 seconds; a two-second sample contained 53 distinct fresh frames.
  No camera, microphone, network, credentials, or image files were used by this harness.
- The public tool probe compiles but could not run a model round trip: both API-key and separate
  Codex reads return OSStatus -25293 with interaction disabled. The first attempt exposed a macOS
  compatibility issue: `LAContext.interactionNotAllowed` alone did not suppress a legacy Keychain
  ACL dialog. That exact probe was stopped. Adding the process-local legacy no-interaction switch
  and query guard made both reads fail promptly without another dialog; no item ACL, password,
  credential file, or security setting was changed. The native renderer result above is distinct
  from uncompleted public tool/continuation acceptance.

- The final native rerun passed with first pixels at 0.188 seconds and 51 fresh frames in two
  seconds. Its host process peaked at 81,494,016 resident bytes; this excludes WebKit's separate
  content/GPU processes and is not a total renderer memory benchmark. Signed build 33 was installed
  through the protected passwordless transaction. Source and installed deep signatures pass;
  source/installed versions and the protected generation marker are 33. No component was activated.

## Build 32 OpenAI/local Settings cleanup

Date: 2026-09-05

- Removed obsolete compatible-service state, unused generic endpoint bindings, and the empty
  custom-vision disclosure. Conversation uses one canonical OpenAI credential path and keeps
  API-key/Codex drafts separate from the saved active authentication choice. Local vision setup
  remains available while processing is off; individual switches reflect enabled stages.
- Settings transfer and custom endpoints remain hidden at the user's request. The Release popup
  no longer exposes the manual script editor. README and configuration guidance now describe the
  current OpenAI/local product rather than older private-service controls.
- Loading settings disables unsupported conversation and remote video stages without deleting
  their endpoint definitions, credential references, or unrelated local transcription. Migration
  failure blocks capture. Four regression tests cover metadata preservation, idempotence, public
  API-key/Codex routes, independent local transcription, and rejected endpoint overrides.
- Full validation passed 143 tests and the unsigned four-target build. The protected passwordless
  installer installed signed build 32; strict source and installed signatures pass, and both
  bundle versions and the protected generation marker are 32. No system component was activated.

- Native UI/accessibility acceptance verified all three tabs, absent transfer/custom-endpoint
  controls, vision setup while off, truthful group/individual switches, active-route labels,
  authentication/transcription drafts across tab switches, and Privacy's saved Codex/local routes.
  API-key and Codex silent public connection tests both passed. The Release camera preview loaded
  without the script editor and stopped to idle. Original Codex, Whisper Base, translation, and
  RF-DETR Large settings were retained. Completed connection messages are cleared when the selected
  authentication, model, or voice changes so an old result cannot describe a new draft.

## Build 31 local detector reuse and bounds

Date: 2026-09-05

- Pipeline construction now creates/reuses a cheap serial actor for each detector. Core ML loading,
  image preparation, prediction, and postprocessing run off the main actor. Prediction cannot abort
  mid-call; cancellation checks at the boundaries discard retired work. Cache removal is verified
  using a disposable empty model directory, with no changes to real model weights.
- RF-DETR validates batch/shape agreement, at most 1,000 queries and 256 classes before tensor
  allocation, finite scores/coordinates, and the 128-result scene limit. Filtering below-threshold
  scores before sorting preserves stable top-K semantics while reducing routine candidate work.
  Four new Core tests cover overflow-sized dimensions, nonfinite values, ties/background selection,
  and result limits. Full validation passed 139 tests and the unsigned four-target build.
- The native harness used only the pinned public Darknet and Roboflow photos listed in
  [local-models.md](docs/local-models.md#local-detector-runtime). All three downloaded models detected
  the dog, bicycle, and car in Darknet's fixture. RF-DETR also detected the close-up dog; YOLO Tiny
  returned no detections on that photo at confidence 0.25. The harness verified finite normalized
  boxes, cached identity, main-actor responsiveness during first inference, cancelled-call recovery,
  cancellation before loading, and cache invalidation on removal.

  | Model | Client construction | First load/inference | Three warm calls | Cancellation return |
  |---|---:|---:|---:|---:|
  | YOLO Tiny | 0.040 ms | 0.100 s | 6.70–7.73 ms | 4.68 ms |
  | RF-DETR Medium | 0.020 ms | 4.183 s | 39.25–39.87 ms | 25.62 ms |
  | RF-DETR Large | 0.023 ms | 4.076 s | 64.69–68.34 ms | 51.64 ms |

  Main-actor five-millisecond probes continued during the calls. The process peaked at 203,046,912
  resident bytes while retaining all three clients. These are individual public-fixture measurements
  with existing filesystem/Metal cache state, not a broad benchmark or a real-time frame guarantee.
  The capture/render path continues while first inference warms up; stale inference is discarded.
- A final native rerun passed after full validation; the warmed filesystem/Metal caches reduced
  first RF-DETR inference to about 0.08/0.11 seconds. This confirms the first-call timings above
  depend on cache state rather than providing a controlled cold-start benchmark.
- The protected passwordless installer installed signed build 31. Source and installed bundles
  pass strict deep signature verification; both versions and the protected generation marker are
  31. During a local camera test, RF-DETR Large boxes and a manually rendered three.js ring appeared
  over the live preview; Clear removed the ring. The user reported that the live camera/gesture
  check looked good. The camera test was stopped and the host returned to idle. This checks local
  composition, not Realtime tool invocation or delivery to another call participant. No system
  component was updated or activated, and no camera or microphone media was recorded.

## Build 30 PCM duration correction

Date: 2026-09-05

- After the user reported accelerated Realtime playback, a native synthetic five-second 24 kHz
  tone reproduced a delivery bug: the prior converter returned only 163,840 frames for twenty
  quarter-second chunks. That is 3.4133 seconds at 48 kHz or 3.7152 seconds at 44.1 kHz. Its input
  callback supplied more frames than requested, then discarded the remainder with each converter.
- The shared helper now supplies only the requested frames and retains a cursor through each
  input buffer. Streaming speech reuses one converter, distinguishes a temporary lack of input
  from end-of-stream, and drains the final tail before playback completion. Player format mismatch
  fails explicitly. Capture resampling uses the same corrected delivery helper.
- `scripts/validate-audio-conversion.swift` uses only synthetic PCM in memory. Twenty 24 kHz
  quarter-second chunks produce exactly 220,500 frames at 44.1 kHz and 240,000 frames at 48 kHz:
  five seconds in both cases. Irregular chunks, including one-frame input, and whole responses
  produce identical duration and continuous 997 Hz waveforms. RMS error is below 0.000003 for
  float conversion. Planar stereo capture to 24 kHz and interleaved integer capture to 16 kHz
  also preserve duration; integer conversion RMS error is below 0.000018. Stereo channels agree
  and all output samples are finite. No device, network, Keychain, or media file is opened.
- The callback follows Apple's requested-frame contract in
  [TN3136](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions).
  The playback format check follows
  [AVAudioPlayerNode's buffer-rate requirement](https://developer.apple.com/documentation/avfaudio/avaudioplayernode).
  Hardware listening acceptance remains separate from these deterministic signal checks.
- Full `scripts/validate.sh` passed 135 Swift tests, the unsigned four-target build, metadata and
  installer checks, and HAL harnesses. The protected passwordless installer installed signed
  build 30. Source and installed bundles pass strict deep signature verification; both versions
  and the protected install-generation marker are 30. No system component was updated or activated.
- The user repeated a spoken Realtime turn in build 30 and confirmed that playback now sounds
  normal. This closes the reported speed-up acceptance check. Tool and translated-caption
  acceptance remain separate.

## Build 29 separate Codex login

Date: 2026-09-05

- Authentication uses only the installed official Codex CLI's public account RPCs, with AI Camera's
  own home and OS Keychain namespace. It neither creates an agent thread nor reads the desktop or
  `esp32-voice` credential. The stored profile selects Codex with endpoint auth kind `none`, so older
  app builds cannot silently use the saved API key. No `auth.json` was created in the dedicated home.
- Five Core tests cover device URL/code validation, credential/header bounds, expiry refresh hints,
  Keychain namespace hashing, JSONL framing, legacy API-key defaults, and rejection of key fallback.
  The full validation suite passed 135 Swift tests, metadata/installer checks, HAL harnesses, and
  the unsigned four-target build before signed acceptance.
- The native harness with installed CLI 0.153.4 passed isolated empty-account initialization,
  device-code response validation and cancellation notification, empty-account logout, and helper
  restart. It also passes three stop-during-start/replacement cycles: an abandoned startup cannot
  terminate or launch over its replacement. The harness opens no browser and completes no login.
- Signed build 28 passed strict deep verification for source and installed app; both versions and
  the protected install-generation marker read 28. The user completed the app's separate device
  login. Account status survived the signed host update, and Save selected Codex explicitly.
  Test Connection accepted the credential on public OpenAI Realtime without opening capture.
  Refresh Login succeeded, followed by another successful public connection.
- Build 29 adds generation guards for helper startup and credential cleanup. Full validation still
  passes 135 tests; the protected passwordless installer installed it at `/Applications/AI Camera.app`.
  Source and installed signatures pass strict deep verification; source, installed, and protected
  marker versions are 29. Neither system component was updated or activated.
- The user heard a spoken Codex Realtime reply and reported a slight playback speed-up. This
  establishes an audible response for this account, with an unresolved playback correctness issue.
  It does not establish subscription billing coverage. Tool continuation, translated captions,
  real-account sign-out, and broader speech/error acceptance remain in the manual matrix.
- Setup is available while Conversation is off. Incomplete Codex login cannot be saved or enabled;
  changing the authentication draft leaves the saved route active until Save. Connection tests use
  a separate cancellable session and generation-bound status; model/voice/auth changes and Settings
  closure cancel the test. UI attempts to cancel a live successful handshake completed too quickly
  to establish the manual cancellation check; the native helper cancellation check is separate.

## Build 26 embedded Whisper and streamed model downloads

- `scripts/validate.sh` passed 130 Swift tests, metadata and installer checks, HAL harnesses, and
  the unsigned four-target build. Focused tests cover bounded PCM input, old profile defaults,
  local endpoint exclusion, streamed download limits, integrity failure, cancellation, and private
  partial-file cleanup. The translation download-generation/removal/cache harness also passed
  after migration to the shared downloader.
- Whisper uses the official MIT-licensed v1.8.6 XCFramework and pinned Base/Small model artifacts.
  [Provenance and checksums](docs/local-models.md) are documented. A narrow C bridge prevents the
  two native engines' incompatible GGML headers from entering the same Swift module.
- Native checks on this M4 Pro used only the SHA-256-pinned upstream 11-second JFK WAV fixture.
  Both models recognized the expected speech in English and auto-detect modes, returned no text
  for silence, reused cached clients, cancelled inference, recovered, and continued transcribing
  with HY-MT2 loaded in the same process. No microphone, camera, Keychain, or private recording was
  used by the harness.

  | Model | First request including setup | Warm auto-detect | Cancellation return | Peak resident bytes with HY-MT2 |
  |---|---:|---:|---:|---:|
  | Base | 7.611 s | 0.227 s | 0.059 s | 1669283840 |
  | Small Q5_1 | 8.268 s | 0.719 s | 0.002 s | 1743486976 |

  These are single fixture measurements with existing filesystem/Metal cache state. They are
  neither a broad accuracy benchmark nor a guaranteed interactive latency. Cold model/GPU setup
  is visible on the first speech window; later pipeline starts reuse the client.
- Whisper, translation, and vision now stream public weights to private temporary files with
  received-size bounds and incremental SHA-256. UI progress is throttled; cancellation removes
  partial data. Vision cancellation during non-interruptible Core ML compilation discards the
  eventual result and keeps a single job until cleanup finishes.
- `scripts/install-app.sh` installed signed Release build 26 through its protected passwordless
  transaction. Strict nested verification passed for both source and `/Applications/AI Camera.app`;
  both bundle versions and the protected install-generation marker read 26. The Release build
  reports upstream quoted-include framework-header warnings and the existing AppIntents metadata
  warning. Host installation did not update or activate the camera extension or HAL driver.
- Native Settings acceptance verified provider setup while off, Base readiness, Save & Enable,
  a disabled save for missing Small weights, determinate Small download progress, cancellation,
  retry, and verified readiness. Model drafts survived switching to Privacy and back. Privacy
  identifies Whisper as local while separately identifying configured Realtime egress. The saved
  Whisper profile has no active remote ASR endpoint ID and preserves inert OpenAI metadata.
- Small remained selected after quitting and relaunching the installed app. Removing that test
  download immediately disabled transcription and captions and removed its readiness. Base was
  then saved and enabled again, English-to-Chinese translation was restored, and closing Settings
  returned the host to idle with both local tests stopped. Existing HY-MT2 and RF-DETR weights were
  preserved.
- Live microphone captions and translated captions during audible Realtime playback remain in
  the host acceptance matrix. The fixture proves native inference; it does not prove the physical
  microphone/speaker path or virtual-device behavior.

## Build 25 local translation correctness and reuse

Date: 2026-09-05

Machine: `snappy`, Apple Silicon, macOS 26.5.2, Xcode 26.6

- Token pieces accumulate as bounded bytes and decode once after end-of-generation. Incomplete
  UTF-8, empty output, and output limits fail explicitly. The 256-token generation limit no longer
  returns a silently cut-off translation. The pinned runtime's actual default batch capacity is
  2,048; its context now declares that capacity explicitly for the existing prompt bound.
- Model loading and inference observe cancellation through native callbacks and boundary checks.
  The process-global llama backend initializes once; one engine cannot free another's backend.
  The model controller retains a client across pipeline restarts and releases its cache on removal.
  Download and hash cancellation cannot publish into a newer download generation.
- `scripts/validate.sh` passed 117 Swift tests, the unsigned four-target build, script/metadata and
  installer checks, and the HAL harness. Five new tests cover byte-split multilingual/emoji text,
  invalid and incomplete UTF-8, atomic byte-limit rejection, character limits, and empty output.
- The native synthetic harness passed Chinese, Japanese, and Arabic output, cancellation during
  inference, successful recovery, client reuse, and independent engine teardown. This run measured
  0.625 seconds for its first translation and 0.370/0.378 seconds for warm requests. Cancellation
  returned in 0.127 seconds. Peak resident memory was 2,681,438,208 bytes for the harness, which
  intentionally held two engines. An earlier first run took 14.3 seconds; these startup runs have
  different filesystem/Metal cache conditions and are not a controlled speed comparison.
- A deterministic native fixture completed a cancelled old download after removal and after a
  replacement download started. The old temporary file was cleaned up, the model stayed absent,
  the new downloading state survived, and only the new fixture was installed. Cache identity and
  removal checks passed. No real model was removed or downloaded by this harness.
- The protected passwordless installer installed signed Release build 25 at `/Applications/AI Camera.app`.
  Source and installed bundles passed strict deep signature verification; source, installed host,
  and protected marker all report 25. Neither system component was updated or activated. Native
  tests used synthetic text and temporary fixtures, with no Keychain access or captured media.
- Signed Settings acceptance preserved the ready HY-MT2 model and enabled English-to-Chinese
  translation; closing Settings returned the installed host to idle with both local tests stopped.
- Live translated-caption acceptance remains in the Realtime matrix. Embedded Whisper and the
  common download progress/storage experience remain implementation work.

## Build 24 host-owned Realtime audio

Date: 2026-09-05

Machine: `snappy`, Apple Silicon, macOS 26.5.2, Xcode 26.6

- Realtime now uses public OpenAI WebSocket PCM from the selected AVCapture microphone through
  the `RealtimeConversationClient` Core protocol. The separate WebRTC capture/rendering dependency
  is removed. Local Talk routes generated speech to the macOS output without microphone monitoring.
- `scripts/validate.sh` passed 112 Swift tests with zero failures, the unsigned four-target build,
  script/metadata checks, installer rendering checks, and HAL harness. Eleven new policy tests cover
  absolute input/response deadlines, late VAD events, transcript accumulation/bounds, strict tool
  arguments, conditional tool exposure, and lossless splitting of large PCM messages for playback.
  `git diff --check` passed. No driver or system extension was installed or activated by validation.
- A memory-only public WebSocket probe using the configured API credential completed setup in
  1.34 seconds and received six nonzero audio chunks totaling 108,000 PCM bytes, followed by a
  completed response. The microphone was never armed; the request used synthetic text. This proves
  transport and generated-audio delivery, not audible host playback or subscription billing.
- Signed UI checks passed the no-speech timeout, explicit Stop after starting Talk, repeated starts,
  and preservation of a microphone test started before Talk. A Talk-owned test returned to idle
  with its level meter removed; a pre-existing microphone test remained active until explicitly
  stopped. No camera or microphone content was recorded or persisted.
- Review also corrected partial ASR windows and resampler state at Realtime transitions, so the
  resumed batch lane cannot upload audio retained from a Realtime turn. Translation runs outside
  the transport event consumer with one active task and one replaceable pending final caption.
- The protected installer built and relaunched signed Release build 24 at `/Applications/AI Camera.app`
  through passwordless `sudo`. Source and installed bundles passed strict deep signature checks;
  both bundle versions and the protected generation marker report 24. The installed app contains
  AICameraCore and llama frameworks, with no WebRTC framework. The HAL driver remains build 12;
  neither system component was updated or activated.
- Audible one-utterance replies, VAD-to-playback completion, live tool continuation, and translated
  captions still require acceptance. Dedicated Codex authentication, embedded Whisper, and Settings
  simplification remain separate implementation work. Native UI orchestration and hardware playback
  are not covered by the Core unit tests. Existing Swift 6 actor-isolation warnings in model and
  configuration code remain for the next review pass.

## Build 23 OpenAI-only transcription provider UX

Date: 2026-08-31

Machine: `snappy`, Apple Silicon, macOS 26.5.2, Xcode 26.6

- Normal Transcription Settings now identifies OpenAI directly and exposes no custom or nominally embedded provider. Embedded Whisper remains a separate milestone and will appear only with a real integrity-checked model download, readiness, and removal lifecycle.
- At launch, import, and reload, an enabled non-OpenAI transcription endpoint is replaced by canonical OpenAI when the shared Keychain credential exists. Without that credential, the unsupported lane, translation, and transcript overlay are disabled. The prior endpoint definition remains inert so profile round trips do not destroy advanced metadata.
- `swift test` passed 101 tests with zero failures. `scripts/validate.sh` passed the complete safe suite, unsigned four-target build, strict C checks, installer rendering, and HAL harness without installing or activating a system component.
- The protected installer installed and relaunched signed Release build 23 at `/Applications/AI Camera.app`; strict deep signature verification passed. The saved active lane migrated from `http://127.0.0.1:4002` to `https://api.openai.com` with adapter `openAITranscription`, model `gpt-transcribe`, automatic language selection, and the existing Keychain account reference. The old `asr` endpoint remains inert.
- Signed UI acceptance showed Conversation off, Transcription on, Provider **OpenAI**, model/language controls, the correctly masked shared key, and nested local translation. No custom or embedded provider was offered. No microphone test, transcription request, recording, or media persistence was started.

## Build 22 independent OpenAI transcription

Date: 2026-08-31

Machine: `snappy`, Apple Silicon, macOS 26.5.2, Xcode 26.6

- Transcription now runs independently of Conversation. Its OpenAI-first Settings card configures service, model, language, and a masked Keychain credential shared with canonical OpenAI Realtime; `gpt-transcribe` is the default model. Translation remains nested under Transcription.
- Compatible imported ASR endpoints remain selected when Transcription is toggled back on. An explicit save switches that lane to OpenAI. Active Realtime sessions suppress and cancel batch ASR while continuing to publish Realtime transcripts, so the same microphone audio is not uploaded twice.
- Configuration validation now requires a compatible transcription endpoint whenever Transcription itself is enabled, even if Conversation is disabled. Unit coverage verifies the independent configuration and the OpenAI multipart model, language, audio, route, and response contract.
- `swift test` passed 101 tests with zero failures. `scripts/validate.sh` passed the full safe suite, unsigned four-target Xcode build, strict C checks, installer rendering checks, and HAL harness. `git diff --check` passed. Validation installed or activated no driver or system extension.
- The approved protected installer built and installed Apple Development-signed Release build 22 at `/Applications/AI Camera.app`, then relaunched it. Strict deep signature verification passed and the installed host reports build 22. The intentionally unchanged HAL driver remains build 12.
- Signed UI acceptance showed Conversation disabled while Transcription remained enabled, the service/model/language controls, correctly masked shared OpenAI key, and nested Translate controls. The existing compatible local endpoint remained active with an explicit offer to switch to OpenAI. No microphone test, transcription request, recording, or media persistence was started during UI acceptance.

## Build 14 dependency refresh and notarized distribution candidate

Date: 2026-08-21

Machine: `snappy`, Apple Silicon, macOS 26.5.2, Xcode 26.6

- Updated LiveKit WebRTC from `144.7559.13` to `144.7559.14` and the vendored three.js overlay runtime from r149 to npm release `0.185.1` / r185. Both three.js copies are byte-identical classic-script bundles generated from the official ESM release and retain the upstream MIT license. Added `LSApplicationCategoryType=public.app-category.video` to remove the actionable archive metadata warning.
- The overlay spike now records the page's three.js revision and WebGL2 availability. Its development-only content security policy permits its existing inline harness script; the production overlay keeps its strict external-script policy. The final r185 spike rendered 55 frames in two seconds at 29.7 fps through WebGL2 and completed alpha-compositing samples successfully.
- `scripts/validate.sh` passed with 89 Swift tests and a successful unsigned four-target build. The strict C11 HAL harness and its AddressSanitizer/UndefinedBehaviorSanitizer and ThreadSanitizer variants passed. `git diff --check` passed. The audio driver remains the previously validated build 12; the app and camera extension report build 14.
- The universal Release archive and exported app, frameworks, camera system extension, and HAL driver are signed with the existing Developer ID Application identity. Strict nested verification passed, and neither the app nor extension contains `get-task-allow`.
- Apple accepted notarization submission `a790793d-5572-4bdd-b7e5-6aedaa3936eb` with no issues. The ticket was stapled and validated, strict signature verification still passed, and Gatekeeper accepted the app with source `Notarized Developer ID`. The final stapled archive is `build/AICamera-0.1.0-build14-notarized-final.zip`, SHA-256 `514407f0369f4cc88b3184e0559b408a09dd862bfd03d0c3b3b8b733d4e42a35`.
- This work did not install or launch build 14, request media access, activate or replace the camera extension, copy or reload the HAL driver, register a login item, or change System Settings. Installed build 13 remains active and unchanged.

## Builds 11–13 post-restart demand-delivery validation

Date: 2026-08-16

Machine: `snappy`, Apple Silicon, macOS 26.5.2, Xcode 26.6

- The restart removed the retired camera-extension generation. Camera extension build 10 is active, enabled, and published. Its newer embedded generation has not been activated.
- Native inspection showed why the build-10 HAL selector was invisible through Core Audio although the direct driver harness could call it: custom HAL selectors must be declared through `kAudioObjectPropertyCustomPropertyInfoList` and use a supported cross-process type.
- Build 11 declares `aicc` as a `CFPropertyList` custom property, returns a retained `CFNumber`, reads it with explicit ownership in Swift, rejects nonzero qualifiers, and extends the direct harness for the exact custom-property contract. Full validation, strict C11, ASan/UBSan, TSan, signing, and `git diff --check` passed.
- With explicit approval, the protected installer installed the strict-signed build-11 host and HAL driver and reloaded Core Audio. The app, driver, and protected generation marker report 11; `get-task-allow` is absent. Camera extension build 10 was not updated.
- A separate native Core Audio process verified the live device, the one-entry custom-property info list, selector `aicc`, `CFPropertyList` data type, no qualifier type, pointer-sized result, and a nonnegative `CFNumber` value. A bounded no-recording AudioDevice client then produced 469 callbacks while the same live property transitioned `0 → 1 → 0`; a long-lived watcher independently observed the same levels, proving the value is not stale across queries.
- Host acceptance exposed a separate app-side timing defect: `@Published` emits from `willSet`, and the synchronous snapshot subscriber reconciled against the previous demand value. The HAL returned to zero, but the long-running host remained at **Microphone in use**. The host was quit cleanly; all bounded clients exited, the live count is zero, and the physical input is released.
- Build 12 defers demand reconciliation to the next MainActor turn. An independent review confirmed that level-triggered reconciliation remains safe under rapid transitions and that analogous manager/configuration subscriptions are already deferred. Build 12 passed 68 Swift tests, full non-installing validation, the strict HAL harness, sanitizer variants, strict Release signing, and `git diff --check`.
- With explicit approval, the protected installer installed the strict-signed build-12 host. The in-app microphone update then installed HAL build 12 and reloaded Core Audio through a visible administrator authorization. The protected marker, app, and HAL driver report 12, strict signature checks pass, and `get-task-allow` is absent. Camera extension build 10 remained active and was not updated.
- Four normal microphone cycles and 50–100 ms clients each produced live callbacks, demand `0 → 1 → 0`, physical Yeti acquisition only while requested, prompt host startup, return to idle, and hardware release. Two simultaneous clients produced `0 → 1 → 2 → 1 → 0`. Forced client exit cleared demand. External demand cancelled local tests, and a client that stayed open across host quit/relaunch was served after relaunch. The Core Audio watcher and UI state agreed except when a separately configured transcription endpoint reported its own connection failure.
- A no-recording QuickTime Movie Recording preview exposed and selected **AI Camera**, but the host remained at **Waiting for a camera client**. Unified logs showed the build-10 extension running inside `cmiodalassistant` and resolving its app-group container under that service account, separate from the GUI user's container; sandbox policy denied the expected shared JSON-file access. QuickTime was closed without recording or saving, all temporary clients exited, HAL demand returned to zero, and the physical microphone was released.
- Build 13 replaces the unusable camera file transport with a bounded timestamped `NSData` snapshot on the read-only `4cc_aicd_glob_0000` CoreMediaIO device property. Source start/stop transitions and one-second active heartbeats update the DAL cache. The host resolves the device by stable UID, reads only 1–4096 raw bytes, retries one size race, decodes the bounded snapshot, and rejects missing, malformed, negative-count, future-dated, or older-than-two-second values. Four new shared-wire tests bring the Swift total to 72. Full non-installing validation, the strict HAL harness, unsigned four-target build, strict Release signing, absence of `get-task-allow`, embedded property-name inspection, and `git diff --check` pass. An independent current-macOS review confirmed the custom-key mapping, raw `NSData` ABI, UID lookup, memory ownership, locking, cache notification, and fail-closed freshness behavior with no blocking defect. CoreMediaIO reports aggregate first-client/last-client source activity, normally 0 or 1 rather than exact client cardinality; that matches the host's `> 0` contract. The app and extension report build 13; the intentionally unchanged bundled audio driver reports build 12.
- With separate explicit approval, the protected installer installed app build 13 and left HAL build 12 unchanged. Strict installed signature and entitlement checks pass, and the protected generation marker reports 13. The camera update inherited approval and reached **activated enabled** for build 13. macOS invalidated build 10 and marked it for removal at restart, but launchd rejected the build-13 job submission because the build-10 job was still in progress. Build 10 then exited, build 13 did not launch, the virtual camera disappeared from bounded AVFoundation discovery, and the native `aicd` probe failed closed with `device-missing`. After an explicit status refresh, the Camera row correctly reported **Active — device unavailable** and instructed a restart. Live property and camera acceptance require that restart; none was performed.
- After a separately approved restart, build 10 was removed and build 13 remained the only **activated enabled** generation. Its provider process runs under `cmiodalassistant`, bounded AVFoundation discovery again exposes **AI Camera** at stable UID `38A6609A-FA9E-44FE-B667-4536B8491009`, and the refreshed host reports both virtual devices **Ready**.
- A native CoreMediaIO probe resolved the live device, verified global/main selector `aicd`, confirmed `settable=false`, read 123–124 raw bytes, and decoded a fresh idle snapshot with aggregate count 0. A normal no-recording QuickTime source changed `aicd` `0 → 1 → 0`; the host changed **Ready → Camera in use → Ready**, authorized its feeder, and returned to idle after client close.
- Two separate QuickTime processes opened the source concurrently without recording. CoreMediaIO correctly kept aggregate `aicd` at 1 after the first client closed and returned it to 0 only after the final client closed. This confirms the first-client/last-client stream contract rather than exact client cardinality.
- Combined camera and virtual-microphone demand produced `aicd=1`, `aicc=1`, physical Yeti running, host state **Camera and microphone in use**, and 469 audio callbacks. After the audio client stopped, `aicc` returned to 0 and the host remained **Camera in use** until the camera client closed. Final physical input state returned to zero.
- Starting both local tests and then opening an external camera client cancelled both tests; both buttons returned to **Test camera**/**Test microphone** and only **Camera in use** remained. Force-killing the exact no-recording QuickTime test process changed `aicd` `1 → 0` and restored idle within three seconds.
- With a camera source left active, quitting the host preserved fresh `aicd=1` and extension placeholder service. Relaunching the signed host reacquired demand and restored **Camera in use** without reopening the client; closing that client returned `aicd` to 0 and the host to idle. Extension logs recorded authorized feeders with no rejection, revocation, or sink-consume error.
- Final post-acceptance state is `aicd=0`, `aicc=0`, physical Yeti running state 0, physical camera `inUse=false`, no QuickTime/audio/FFmpeg test client, and an idle build-13 host. No recording was started or saved and no media was persisted.

## Build 10 local-test and source-navigation validation

Date: 2026-08-16

Machine: `snappy`, Apple Silicon, macOS 26.5.2, Xcode 26.6

- Added idle-only **Test camera** and **Test microphone** controls. The camera uses the normal processed preview; the microphone displays a 10 Hz UI poll of a one-slot, normalized peak snapshot written only on the bounded audio processing queue.
- Local tests may run together. Any external camera or microphone demand cancels both tests and performs a serialized full coordinator teardown and scene reset before client capture starts, so test-derived inference, transcripts, speech, and overlays cannot enter a client session.
- Camera and microphone starts remain independent. Demand polling now publishes one atomic combined snapshot in common run-loop modes; desired lanes start before undesired lanes stop. Per-lane gates reject stale callbacks, and a failed camera feeder cleanup is retained separately so it cannot pin or starve microphone demand.
- Inline source settings buttons route to stable Camera and Microphone anchors under **Settings → General**, including repeat requests while Settings is already open. The physical-input eligibility note applies to both lanes.
- `scripts/validate.sh` passed with 68 Swift tests and a successful unsigned four-target Xcode build. The strict C11 HAL harness passed. AddressSanitizer/UndefinedBehaviorSanitizer and ThreadSanitizer HAL variants passed. `git diff --check` passed.
- Tests cover local-test arbitration and external-client cancellation, bounded audio-level normalization, loop-safe physical-input policy, pure-passthrough defaults, lifecycle decisions, and the existing privacy, adapter, conversation, and transport boundaries. Independent lifecycle and UX source reviews found no remaining concrete issue.

The protected installer then replaced and relaunched the signed Release host without reinstalling or activating either system component. The installed app remains build 10, its protected generation marker is 10, strict nested signature verification passes, and `get-task-allow` is absent.

Signed native host acceptance passed for the following cases without persisting media:

- Camera-only testing started the resolved hardware camera and replaced the idle camera symbol with a live processed preview. Stopping it restored the idle preview and state.
- Microphone-only testing started the resolved Yeti through `AVCaptureAudioDataOutput`. The bounded meter produced finite live values between 0 and 1 and disappeared immediately on stop.
- Both tests ran together. Stopping either lane left the other active; both orders passed without a stale preview, meter, error, or callback.
- Local-only tests did not open an unconsumed CoreMediaIO feeder or virtual microphone output. The earlier AVAudioEngine physical-input path was replaced after native probes showed that explicit input-node device assignment caused startup error `-10875`; AVCapture probes received and converted samples from both the default and an explicitly selected alternate physical microphone.
- Both inline source settings buttons opened the foreground Settings window on **General** and targeted their stable Camera or Microphone sections. Updated capture copy and the shared physical-input eligibility note were present.
- Independent lifecycle, UX, and AVCapture reviews found no remaining concrete source-level issue after queue separation, full audio format preservation, partial-graph rollback, bounded copied-buffer caps, and teardown hardening.

Two daemon-level acceptance items remain after the user-owned reboot. The extension reports build 10 as activated/enabled, but macOS is not currently publishing **AI Camera** and build 9 remains queued for removal; the permanent health row now reports **Active — device unavailable** instead of **Ready**. The on-disk HAL binary matches the current build and **AI Camera Microphone** is visible, but the live Core Audio device object does not yet expose the new `aicc` demand property. A bounded FFmpeg client read the virtual microphone successfully into a null sink, but could not trigger client-demand takeover in that stale live instance. Reboot or an explicitly approved Core Audio refresh is required before external-client cancellation, cross-lane takeover, and final physical-device release can be accepted.

## Build 10 signed installation and physical-input safety follow-up

Date: 2026-08-16

Machine: `snappy`, Apple Silicon, macOS 26.5.2, Xcode 26.6

- The protected installer replaced `/Applications/AI Camera.app` with a strict-signed Release build 10. The app is running; camera extension build 10 reports **activated enabled**; HAL microphone build 10 is loaded and visible to Core Audio. Camera extension build 9 remains reboot-gated for cleanup.
- The menu-bar panel keeps permanent virtual-device health rows, reports the resolved physical inputs, uses a foregrounded Settings window, and keeps the login-item control under **Settings → General**.
- System-default resolution now reads the CoreMediaIO camera default and Core Audio microphone default. Only recognized direct-hardware transports are eligible. Software loopbacks, aggregate/auto-aggregate, network, unknown-transport, and wired/wireless/legacy Continuity inputs fail closed.
- If an ineligible default is selected, the host chooses the first compatible physical input in stable name-and-ID order and shows an orange warning naming the default and fallback. If no compatible input exists, capture remains blocked until the user selects a compatible physical device or video frame rate.
- A read-only native resolver check selected **HD Webcam eMeet C950** and **Yeti Stereo Microphone** from the current defaults. It excluded OBS Virtual Camera, the Continuity camera/microphone, BlackHole, and AI Camera from physical-input choices while preserving supported duplex virtual devices as advanced audio destinations.
- `scripts/validate.sh` passed with 62 Swift tests and a successful unsigned four-target Xcode build. The strict C11 HAL harness passed. AddressSanitizer/UndefinedBehaviorSanitizer and ThreadSanitizer HAL variants also passed. `git diff --check` passed.
- Pure policy tests cover known physical transports, virtual/aggregate/network/unknown/Continuity rejection, default retention, deterministic fallback admission, and no-hardware failure. An independent resolver review found no remaining issues after compatibility, ordering, warning-text, and fallback-API corrections.

This follow-up did not change the system camera or microphone default to AI Camera. A live self-default warning/fallback check and the broader independent/simultaneous/multi-client demand matrix remain signed native acceptance work.

## Build 10 automatic-lifecycle validation

Date: 2026-08-16

Machine: `snappy`, Apple Silicon, macOS 26.5.2, Xcode 26.6

- `scripts/validate.sh` passed after the build-10 automatic lifecycle and documentation changes.
- Swift Package Manager ran 54 tests with 0 failures, including pure-passthrough defaults, independent camera/microphone decisions, and fail-closed invalid-profile demand.
- The unsigned app, core framework, CoreMediaIO extension, and HAL driver built successfully. App-group metadata, component build 10 versions, entitlements, embedded paths, scripts, installer rendering, and the exported driver factory passed validation.
- The strict C11 HAL compile and in-process harness passed. Demand remained zero for output-only `StartIO` and companion-host reads, became active only after real external `ReadInput` operations, handled concurrent first reads and multiple clients without duplicate identities, cleared on stop/removal, and retained the existing clock, loopback, wrap, reset, malformed-input, and sample-rate checks.
- AddressSanitizer/UndefinedBehaviorSanitizer and ThreadSanitizer harness variants passed after the demand-table changes.
- Camera demand now uses serialized current-state snapshots, a one-second active heartbeat, and two-second host expiry. The extension and host integration compiled in both unsigned targets; crash expiry and physical camera release still need signed native acceptance.
- `SMAppService.mainApp` login controls compile and expose macOS approval state. Authorization status now refreshes periodically and on app activation; invalid saved profiles block demand until repaired; transient failures expose an explicit retry path. Login/logout, permission revocation, and failure recovery still need signed native acceptance.

This validation did not request camera/microphone access, register a login item, install/reload the HAL driver, submit a system-extension request, or alter the installed build-9 app. Signed build-10 demand, permission-loss, login, update, and physical-release checks remain the current release boundary.

## Build 9 signed acceptance record

Date: 2026-08-13
Machine: `snappy`, Apple Silicon, macOS 26.5.2, Xcode 26.6

## Safe automated validation

- `scripts/validate.sh` passed after the final build-9 source changes.
- `swift test` ran 50 tests with 0 failures.
- The unsigned Debug build passed for the app, core framework, CoreMediaIO system extension, and Core Audio HAL driver.
- Validation compiled every shell script, compiled the installer AppleScript without running it, rendered its privileged shell command, and passed `/bin/sh -n` on that command.
- Bundle identifiers, embedded paths, resources, property lists, entitlements, and the exported HAL factory symbol passed the project checks.
- The strict C11 HAL build and non-installing harness passed property validation, clock and restart behavior, independent clients, timeline gaps, concurrent ring wrap, reset, and coalesced 44.1/48 kHz changes.
- AddressSanitizer, UndefinedBehaviorSanitizer, float-cast-overflow, ThreadSanitizer, and the separate property-size/canary checks passed earlier in this acceptance cycle.
- Streaming transport tests cover redirect rejection, cumulative and buffer limits, startup cancellation, active-body cancellation, sample-rate validation, and complete-WAV fallback.

Safe validation does not request media access, start inference services, install a driver, or submit a system-extension request.

## Signed build and installer checks

- Apple Development-signed Release build 9 passed strict nested signature verification for the app, framework, camera extension, and bundled audio driver.
- The app and extension both report build 9, have hardened runtime enabled, and do not contain `get-task-allow`.
- Exact Apple-anchored, same-team host and extension identity requirements passed. The installer accepts that strict identity for a signed Debug predecessor, while its new-product no-debug requirement rejects the same Debug host.
- Sandboxed native probes confirmed that `PROC_PIDUNIQIDENTIFIERINFO` and PID-version-bound `csops_audittoken` queries work across users on this host. The checked layout and selectors match the current XNU ABI.
- The finalized protected installer completed a build-9 replacement transaction. The app root and generation marker are root-owned and immutable, the marker contains `9`, and no lock or private staging residue remains.
- The installer verifies identity before and after private staging, rejects debug entitlements on the new product, strips ACL and group/world write access, uses no-follow final and rollback moves, binds the final move to the staged inode before marker commit, and rolls back catchable failures and signals.

## Development-signed camera acceptance

Build 9 is installed at `/Applications/AI Camera.app`. The camera extension reports `(0.1.0/9) [activated enabled]`.

All camera clients were bounded AVFoundation canaries. They kept media in memory and wrote no frames to disk.

- With the host stopped, the source produced 12 unique animated 1920×1080 placeholder frames with strictly increasing timestamps. Frame intervals were 0.03331–0.03387 seconds. A separate classifier identified all 24 sampled frames as placeholders.
- Starting the host authorized its feeder in the real `_cmiodalassistants` service through the PID-version-bound kernel path after Security-framework lookup was unavailable. No status `-4`, rejection, or binding revocation occurred.
- With the host live, one canary received 24 distinct 1280×720 hardware-fed frames; all 24 were non-placeholder frames and timestamps increased strictly. A second canary received 12 unique frames with 0.03310–0.03413-second intervals.
- Host stop returned the source to the animated placeholder. The post-stop canary received 12 unique 1920×1080 frames with increasing timestamps, and the classifier identified all 24 sampled frames as placeholders.
- Host restart again produced 24 distinct non-placeholder frames with increasing timestamps.
- Two simultaneous independent source clients each received 24 distinct non-placeholder frames with increasing timestamps.
- Final host stop completed without a feeder stop error. After the user re-enabled the updated extension in System Settings, the app reports **Stopped**, virtual camera **Ready**, and virtual microphone **Ready**.
- After the finalized installer transaction, a stopped-host sanity canary again received 12 unique 1920×1080 placeholder frames with increasing timestamps; the app and both device rows remained **Ready**.

Older terminated camera-extension generations remain queued for removal by macOS. Their cleanup is reboot-gated and does not block active build 9. The user will perform that reboot.

## Audio and conversation acceptance

- The installed HAL driver publishes the duplex **AI Camera Microphone** device with UID `ai.kortexa.aicamera.audio.device` at 48 kHz. Independent clients previously captured non-silent microphone loopback, concurrent reads, and silence after proxy stop.
- Silent ASR → agent → bounded streamed PCM TTS completed in a development-signed build. Complete-WAV fallback, repeated bounded admissions, virtual-microphone output, and accepted barge-in cancellation passed.
- The changed local ASR, agent, and TTS routes passed their real request paths. ASR accepted both WAV and raw PCM requests with the pinned MLX 0.31.1 runtime.
- No raw media was persisted. In-memory acceptance buffers were released after aggregate metrics were computed.

After acceptance, the normal wake-phrase profile was restored. The default input is **Yeti Stereo Microphone**, the default output is **HyperX Virtual Surround Sound**, AI Camera is stopped, and both virtual devices report **Ready**.

## Remaining release boundary

Development-signed device acceptance is complete. Restoring the Yeti/HyperX defaults is not a new audible human check; repeat that short check for the final distribution candidate.

Build 13 was the previously installed and accepted Developer ID build. Build 14 is now the current non-installed distribution candidate after the dependency refresh. Its exact signing, notarization, and archive evidence is recorded at the top of this file.

A distributable release still needs the planned installer package, clean-machine install/upgrade/rollback/removal checks, and the user-owned reboot that clears retired extension generations.

These operations can change system state or request authorization. They remain manual and approval-gated.

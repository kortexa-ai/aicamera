# Model-rendered camera overlays

The host accepts bounded `render_overlay` and `clear_overlay` Realtime function calls. Generated
three.js scenes run in a hidden WKWebView and publish transparent pixels to the camera compositor.
API-key and separate Codex authentication use the same public function-call contract. Normal
Settings exposes Tools; the manual script editor appears only in Debug local camera tests.

The companion `show_card` / `clear_cards` tools use a native text renderer for concise answers,
requested sticky notes, and metrics. One card may coexist with the three.js scene. Card rasterization
is cached; the capture path reads a small immutable value and never waits for a tool or disk I/O.
Both visual layers are omitted from clean inference frames. See [agent tools](realtime-conversation.md#notes-cards-and-quiet-responses)
for limits and note visibility.

The optional `render_face_effect` tool uses the same renderer with a small local face anchor.
Native gating hides its pixels when tracking is absent, stale, or from a retired track; a normal
overlay does not activate tracking. See [face effects](face-effects.md) for the coordinate contract.

## Current data flow

```text
public Realtime function call
  → validated local command (script bytes, TTL, enabled capability)
  → OverlayScriptRenderer (main-thread lifecycle, isolated WebKit content)
  → bundled three.js/WebGL2 scene, 640 × 360 transparent canvas
  → one unacknowledged base64 RGBA frame, script generation and sequence
  → native size/generation checks, premultiplied BGRA conversion
  → one latest-frame slot, maximum accepted age 150 ms
  → host alpha composition over camera annotations
  → camera preview / virtual-camera feeder
```

Capture reads the latest slot without waiting for WebKit or inference. The clean inference path
omits generated overlays, so the model does not recursively analyze its own graphics. The canvas
is upscaled to the selected camera output size.

## Lifetime and bounds

Presentation mode reuses these same scene pixels. `set_camera_layout` can put the live camera
above them in an aspect-preserving inset, with status/caption margins and a bounded lifetime.
The compositor restores full camera when graphics are missing or expire. Reset view clears the
scene and card without deleting saved notes. This mode affects Preview and the virtual-camera
feeder only; the clean inference renderer always keeps its original full-camera transform.

Only one script is active. Native admission checks UTF-8 byte size (default 64 KiB), finite TTL,
and the configured TTL range (default 30 seconds, maximum 60). A replacement immediately clears
old pixels and loads a fresh document. That releases previous script globals, timers, callbacks,
and scene resources. Multiple replacements during initial loading share one pending script slot.
Clear and expiry invalidate the current generation, clear pending pixels, and reload a blank
renderer document. Stop tears down the window and web view.

The bridge sends at most one frame until native code acknowledges its generation and sequence.
Rendering continues while publication waits. The host verifies current generation, increasing
sequence, fixed dimensions, and exact encoded size before base64 decoding. A stale, replayed,
malformed, or oversized frame cannot repopulate the mailbox after Clear or replacement.

Freshness expiry removes a stalled overlay from the compositor. A web-content crash clears state
and reloads the bundled page. WebKit provides process isolation; the app does not claim a hard
JavaScript CPU/GPU memory quota. Host queues, frame sizes, and visible overlay lifetime are bounded.

## Script contract

Scripts use the existing `THREE` global and `AICamera.scene`, `AICamera.camera`, and
`AICamera.onFrame(dt => …)`. They must not create another canvas, renderer, page, or frame loop.
The bundled PerspectiveCamera starts at `(0, 0, 6)` and looks toward the origin. For example:

```javascript
const mesh = new THREE.Mesh(
  new THREE.BoxGeometry(1.5, 1.5, 1.5),
  new THREE.MeshStandardMaterial({ color: 0x8b5cf6 })
);
AICamera.scene.add(mesh);
AICamera.onFrame(dt => { mesh.rotation.y += dt; });
```

The default is a transparent background. Network requests, external textures, fonts, media,
iframes, workers, forms, and additional windows are blocked by the page policy and host controls.
Navigation is restricted to the bundled renderer document. WebKit uses nonpersistent storage.

`overlays.script.allowSceneData` defaults to false. When enabled through the retained configuration
schema, the bridge can read bounded local `AICamera.sceneData`. Host updates are at most 64 KiB,
with one JavaScript evaluation active and one replaceable pending snapshot. Scripts never receive
raw camera frames. Script messages are limited to a short, rate-limited in-memory UI value; they
are never written to unified logs or a diagnostic file.

## Validation and remaining acceptance

`scripts/validate-overlay-runtime.swift` exercises the production renderer with generated geometry,
without cameras, microphones, credentials, or network. It checks byte/TTL bounds, continuous frame
publication, fresh-document replacement, Clear, expiry, script-error recovery, scene updates, and
stop/restart. `scripts/validate-realtime-tools.swift` adds public model-generated tools, native pixel
verification, function outputs, audio/caption continuation, and Clear. Its Keychain reads forbid
interaction; an unavailable credential is a reported test limitation, not a request to unlock it.

See [testing commands](testing.md) and [measured evidence](../VALIDATION.md). Current virtual-camera
acceptance in another call app is deferred. Future face tracking and conversational graphics build
on this host compositor; landmark tracking and another participant's view still need separate work.

## Historical renderer spike

The measurements below describe the original August experiment, not the current hardened bridge.
Its WebKit observations informed the fixed 640 × 360 base64 channel. The production window stays
on-screen beneath the desktop with near-zero alpha so WebKit continues rendering.

## Phase 0 spike results (2026-08-19, the development Mac, macOS 26.5 SDK, M4 Pro)

Run: `swift run AICameraOverlaySpike --channel base64 --width <w> --height <h> --mode hidden`

| Config | fps | js render | readPixels | channel xfer | CI composite | frame interval |
|---|---|---|---|---|---|---|
| base64, 640x360 | 29.2 | 0.02 ms | 1.11 ms (p95 2) | 5.19 ms (p95 6.3) | 1.12 ms (p95 1.8) | 34.3 ms (p95 49) |
| base64, 1280x720 | 29.5 | 0.20 ms | 2.30 ms (p95 5) | 19.24 ms (p95 20.2) | 2.27 ms (p95 2.9) | 34.0 ms (p95 36) |

Composited sample frames verified visually (rotating cube + ring over synthetic camera
background, correct alpha, no fringing): `/tmp/aicamera-overlay-spike/base64-{360p-v2,720p}/`.

**Conclusion:** the pixel path works at 30 fps in both resolutions. Base64 at 360p is cheap
(~8 ms/frame total); base64 at 720p holds 30 fps but costs ~24 ms/frame (mostly btoa +
base64 decode). Phase 1 should default to a 640x360 overlay canvas (upscaled) or add the raw
binary loopback channel for full-resolution scenes.

### WebKit / SDK quirks discovered (affect Phase 1 design)

1. **`WKScriptMessage.body` does not deliver `ArrayBuffer`** (top-level or nested in a
   dictionary) on this WebKit — it arrives as an empty `NSDictionary`. Only JSON-serializable
   types (string, number, bool, null, array, dict) work. The base64 string is the payload.
2. **WebGL2 `readPixels` only accepts an `ArrayBufferView` destination** in the 7-argument
   form: `gl.readPixels(x, y, w, h, RGBA, UNSIGNED_BYTE, uint8Array)`. Passing an
   `ArrayBuffer` silently fails with `GL_INVALID_OPERATION` (buffer stays zero); the
   8-argument `(offset, view)` form throws. Reuse one `Uint8Array` per page.
3. **`requestAnimationFrame` only fires while the window is on-screen.** A window positioned
   off-screen (x = -30000) renders nothing. A window placed at (0,0) with window level below
   the desktop wallpaper renders continuously and is invisible to the user. Phase 1 uses the
   below-desktop level.
4. **`CVPixelBufferCreate` rejects `kCVPixelFormatType_32RGBA`** on this OS (returns
   `kCVReturnInvalidPixelBufferAttributes`); 32BGRA works. The spike converts straight-alpha
   RGBA to premultiplied BGRA in the copy loop, which is also the layout CoreImage expects.
5. **`NWListener` fails with `POSIX 22 (EINVAL)` in a plain CLI process** on this macOS, while
   raw POSIX `socket/bind/listen` work. The spike's `--channel http` path is therefore
   unverified in CLI context. Phase 1 must verify `NWListener` inside the app bundle (or use
   raw POSIX sockets / `URLSession`-free loopback).
6. **SDK 26.5 API changes hit by the spike:** `NWConnection.close()` removed (use
   `cancel()`), `NWListener.stateUpdatingHandler` renamed to `stateUpdateHandler`,
   `NWListener.State.waiting` now carries an `NWError` (port read from `listener.port`),
   `CVPixelBufferPoolCreate` takes `(allocator, poolAttributes, pixelBufferAttributes, out)`,
   `NWParameters.allowLocalEndpoint` removed.

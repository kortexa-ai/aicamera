# Model-rendered overlay scripts

Status: Phase 0 spike in progress. See the "Model-rendered overlay scripts" section of `PLAN.md` for the backlog.

## Goal

Give the conversation agent a tool that renders model-generated content on top of the live
camera frames. The model writes a small JavaScript scene (three.js, WebGL2). The scene runs in a
hidden in-app WKWebView. Each rendered frame is read back as pixels and alpha-composited onto the
published virtual-camera frame, so any camera client (Zoom, QuickTime, a local test) sees the
overlay.

## Why WKWebView + three.js (and not the alternatives)

| Option | Verdict | Reason |
|---|---|---|
| WKWebView + three.js (WebGL2) | **Chosen** | In-process, no new signed binary, WebKit web-content process gives crash isolation, three.js is the most common 3D library in model training data so generated code is reliable. |
| typegpu / WebGPU | Not in WKWebView | WebGPU is unavailable in Safari/WebKit. typegpu only runs in Chromium. |
| Hosted Chromium (Electron/ElectronBun) | Swap-in later | Separate signed process, ~200 MB RAM, startup latency, lifecycle and update management. Worth it only if WebGPU becomes a hard requirement. Keep behind the same renderer protocol. |
| JavaScriptCore + custom Swift render API | Rejected | Model code quality drops against a made-up API, and a JS crash takes down the app (JSC is in-process). |

The structured/SVG overlay path from the "AI-generated camera composition" backlog item stays for
simple labels and boxes. Script rendering is for rich 2D/3D/animated content. The two coexist.

## Data flow

```text
agent (LLM)
  | tool call: render_overlay(script, ttlSeconds?)
  v
PipelineCoordinator.runAgent
  | validate (size, TTL, known tool) -> execute locally
  v
OverlayScriptRenderer (actor)
  | hidden NSWindow (off-screen, near-zero alpha) + WKWebView
  | page: overlay.html + vendored three.js + bridge (window.AICamera)
  | rAF loop: renderer.render() -> gl.readPixels(RGBA) -> postMessage(ArrayBuffer)
  v
OverlayFrameMailbox (single slot, timestamped CVPixelBuffer, 32RGBA)
  |
  v
OverlayRenderer.render()
  | camera frame (CoreImage) -> existing labels -> composite latest FRESH overlay (<= ~150 ms)
  v
VirtualCameraFeeder (CMIO sink, capacity 1) -> camera clients
```

The inference path is unchanged: `analysisRenderer` keeps rendering clean frames, so generated
content can never feed back into the model.

## Components

### 1. `OverlayScriptRenderer` (app target, actor)

- Owns one hidden window and one WKWebView. The window is ordered in (required for continuous
  rendering) but placed off-screen with near-zero alpha; the app is accessory-only, so no Dock or
  window-list presence.
- Loads the bundled page with `loadFileURL` (dev spike) or a custom `WKURLSchemeHandler` scheme
  (Phase 1, cleaner isolation). All remote requests blocked with a `WKContentRuleList`; opaque
  origin; no cookies/storage; no automatic windows.
- `load(script:)`: bounded to one in-flight load; a generation counter (same pattern as
  `VideoPipelineController.runGeneration`) rejects stale loads and stale frame callbacks.
- `stop()`: tears down the page, clears the mailbox, cancels the watchdog.
- Watchdog: if no frame arrives for ~2 s while a script is active, the overlay is treated as
  stale and disappears. A web-content crash therefore degrades to "no overlay", never to a hung
  camera lane.

### 2. `OverlayFrameMailbox`

Single-slot, timestamped `CVPixelBuffer` mailbox (pattern of the existing `LatestValueMailbox`).
New frames replace old ones; the compositor reads the latest and drops it when older than the
freshness bound. No queue, no backpressure: the capture callback never waits for the web view.

### 3. `OverlayRenderer` change

After the camera frame and the existing labels are drawn, composite the latest fresh overlay
frame (CIGetAlphaComposite). Absent or stale overlay means the frame is published unchanged.
The clean `analysisRenderer` path never composites.

### 4. Agent tool protocol extension (Phase 2)

Realtime is now the primary tool transport; see `realtime-conversation.md` for the WebRTC,
standard function-call, experimental Codex delegation, activation, and fallback design. The
request/response contract below remains the legacy chat-completions fallback so both paths feed the
same bounded local tool executor.

Current legacy protocol: `AgentClient.respond(to:) async throws -> String`. Proposed:

```swift
public struct AgentTool: Equatable, Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue   // JSON Schema
}

public struct AgentToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    public var arguments: JSONValue
}

public struct AgentToolResult: Equatable, Sendable {
    public var callID: String
    public var output: JSONValue
}

public struct AgentResponse: Equatable, Sendable {
    public var text: String?
    public var toolCalls: [AgentToolCall]
}

public protocol AgentClient: Sendable {
    func respond(to request: AgentRequest) async throws -> String
    // New, with protocol-extension fallbacks so existing adapters keep working:
    func respond(to request: AgentRequest, tools: [AgentTool]) async throws -> AgentResponse
    func respond(to request: AgentRequest, toolResults: [AgentToolResult]) async throws -> String
}
```

`OpenAIAgentClient` implements the tool-aware variants with the standard `tools` / `tool_calls`
chat-completions fields. The coordinator enforces the bounds: at most one tool round-trip per
turn, at most a few tool calls, known tool names only, validated arguments, and the existing
endpoint timeout.

Tools:

- `render_overlay(script: string, ttlSeconds?: number)` — load a new scene script.
- `clear_overlay()` — remove the current overlay.

Validation: script byte cap (default 64 KB), TTL cap (default 60 s max), one active script at a
time (new replaces old), memory-only (never persisted, consistent with the media-privacy rule).

### 5. Profile schema

New `overlays.script` block (schema version bump):

```json
"script": {
  "enabled": true,
  "maxScriptBytes": 65536,
  "maximumFps": 30,
  "defaultTTLSeconds": 30,
  "maximumTTLSeconds": 60,
  "allowSceneData": false
}
```

`allowSceneData` is opt-in: when true, the bridge exposes the current `SceneSnapshot`
(detections, gesture, transcript) to the script via `window.AICamera.getScene()`. The data stays
local (the web view has no network), but it is a visible setting because it changes what a
model-generated script can see.

## Security model

Model-generated JavaScript is untrusted. Defense in depth:

1. WebKit web-content process isolation: a script crash or leak does not take down the host app.
2. No network: all remote requests blocked; opaque origin; no shared storage.
3. No native access except the explicit `window.AICamera` bridge (bounded, typed messages).
4. Size/TTL/rate caps enforced by the coordinator and the renderer.
5. Watchdog degrades to "no overlay" on hang or crash.

## Dev loop ("quick way to render")

- The same page + bridge can be opened in a browser (via a tiny local dev server or `file://`)
  with a `?dev` flag that fakes the camera background, so scripts can be iterated with full
  DevTools. The same script string is then what the tool call carries.
- The control center gains a dev-only script paste box (local camera test only) for manual
  acceptance without a model round-trip.
- `AICameraOverlaySpike` (dev tool, not shipped) runs the whole pixel path headlessly:
  `swift run AICameraOverlaySpike --duration 6 --out /tmp/aicamera-overlay-spike`.
  It renders a rotating cube over a synthetic background, prints per-stage latency stats, and
  saves sample PNGs.

## Phase plan

- **Phase 0 (spike, in progress)** — prove the pixel path and measure latency:
  hidden WKWebView renders a three.js cube; `readPixels` to `CVPixelBuffer`; alpha composite over
  a synthetic background; verify `ArrayBuffer` message delivery; verify continuous rendering with
  the window off-screen; record p50/p95 for render, readPixels, and post-to-native stages.
- **Phase 1 (renderer)** — `OverlayScriptRenderer` + mailbox + `OverlayRenderer` compositing +
  `overlays.script` profile settings + dev script paste box. No model yet.
- **Phase 2 (agent tool)** — tool-calling protocol extension, `render_overlay` / `clear_overlay`,
  validation, TTL expiry, teardown on stop/barge-in, system-prompt guidance plus 2-3 example
  scripts.
- **Phase 3 (hardening)** — crash watchdog, memory caps, privacy setting, docs, end-to-end
  acceptance (independent virtual-camera client sees composed script pixels), PLAN/VALIDATION
  updates.
- **Phase 4 (optional)** — hosted Chromium (Electron/ElectronBun) renderer behind the same
  protocol if WebGPU/typegpu is required.

## Phase 0 spike results (2026-08-19, snappy, macOS 26.5 SDK, M4 Pro)

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

## Open questions (for Phase 1)

1. Does `NWListener` work inside the signed app bundle? If not, use raw POSIX sockets for the
   loopback channel.
2. Default overlay canvas size: 640x360 (cheap, upscaled) vs 1280x720 (sharp, ~24 ms/frame
   with base64). Decide after the raw channel is measured in-app.
3. Below-desktop window level in the real app: verify it survives Spaces, screen sleep/wake,
   and display changes without user-visible artifacts.

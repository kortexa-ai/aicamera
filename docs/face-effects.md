# Face-following graphics

With **Tools** enabled and the camera active, ask the agent for a face-following graphic such as
“Put a little sun above my head.” The `render_face_effect` tool replaces the generated overlay
and starts local tracking for that effect's lifetime. It uses the [macOS Vision face-landmark request](https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest)
already available on the Mac. No model download, account, or MediaPipe package is required.

This first implementation follows one clear, fully visible face with 2D position, scale, and eye-line
roll. It does not identify the person, infer gaze/emotion, track a dense 3D mesh, account for hair, or
provide occlusion. Multiple clear faces, a partial/off-screen face, missing landmarks, and stale
observations hide the effect. Real-person movement, lighting diversity, glasses, and independent
call-client acceptance remain separate from the synthetic checks.

## Lifetime and privacy

Tracking is inactive until a face effect is requested. It runs at most eight times per second on
its own serial analysis queue, with one shared request in flight, including across camera/effect restarts. The capture/render path does not wait
for Vision. Late results from a retired camera run or effect generation are discarded. Geometry
older than 350 ms is unusable; the native compositor path suppresses face-effect pixels even if a
script neglects to hide itself. Each new track after loss has a temporary random ID, so old pixels
cannot reappear at a retired position while the new anchor is reaching WebKit.

The small anchor travels only to the isolated local overlay page. It is not included in scene
summaries, Realtime inputs, notes, or network payloads. No camera buffers or landmark history are
recorded. The existing renderer blocks network access and retains one pending frame. Clear,
expiry, privacy mute, camera shutdown, a normal `render_overlay`, and renderer failure end tracking
or suppress its output. The app's normal camera, captions, call microphone, and independent
agent-listening controls retain their existing behavior.

Use **Reset view** in the popup to clear an effect or information card without speaking to the
agent or changing call audio. This also restores full-camera layout. Saved notes remain.

Face effects require the full camera layout. Clear the effect before putting the camera into a
presentation inset; restore full camera before starting a face effect. A native information card,
including a sourced weather forecast, can coexist with the effect.

## Script contract

`render_face_effect` accepts the same `script` and optional `ttlSeconds` arguments and bounds as
`render_overlay`: one script, 64 KiB by default, and a 1–60 second lifetime with a 30 second default.
The host checks that the script starts before reporting success. A failed script stops tracking
and returns an error so the agent can correct it. A started effect waits for a clear face; it does
not claim that pixels are already visible.
Read `AICamera.faceAnchor` inside every animation callback. It is either null or has:

| Field | Meaning |
| --- | --- |
| `box` | `{x, y, width, height}` face rectangle |
| `center` | Face rectangle center `{x, y}` |
| `top` | Estimated point above the face, not an exact hair boundary |
| `leftEye`, `rightEye` | Eye-region centers ordered left-to-right on screen |
| `roll` | Eye-line roll in radians, suitable for `group.rotation.z` |

Coordinates use the overlay canvas with a top-left origin and normalized values. The host applies
the camera's aspect-fill crop and mirror, then compensates for the overlay canvas's own crop. A
4:3 camera and the 16:9 WebGL canvas therefore use the same alignment contract.
`AICamera.facePosition(point)` projects one of these points onto the scene's z=0 plane and returns
a `THREE.Vector3`. Keep the default camera for face effects. The optional second argument selects
a plane between z=-5 and z=5; a degenerate projection returns null.

For example, a small floating shape can follow the estimated top anchor:

```javascript
const shape = new THREE.Mesh(
  new THREE.SphereGeometry(0.2, 24, 16),
  new THREE.MeshStandardMaterial({ color: 0xffbb38 })
);
AICamera.scene.add(shape);
AICamera.onFrame(() => {
  const face = AICamera.faceAnchor;
  shape.visible = !!face;
  if (!face) return;
  const point = AICamera.facePosition(face.top);
  if (!point) { shape.visible = false; return; }
  shape.position.copy(point);
  shape.rotation.z = face.roll;
});
```

Use projected box width to scale larger graphics, leave the eyes/captions clear, and check null
before using a projected point. A cheerful sun is an illustration; use `get_weather_forecast` and
retain its source/time/units for weather facts. Rendering an effect does not establish those facts.

## Synthetic validation

Core tests cover aspect-fill/mirroring, output/canvas coordinates, bounds, stale generations,
tracking loss and reacquisition, small local payloads, and tool capability/argument limits. The
native WebKit fixture checks actual pixel positions and host-enforced disappearance/replacement.
The face detector fixture rejects a blank generated frame and can use an explicitly supplied
fictional portrait to check native landmarks plus a three.js sun in the host compositor.
See [testing](testing.md#face-effect-anchors) for commands. No human camera presence is needed.

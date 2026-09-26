# Call-app layout and mirror quick controls

Issue: https://github.com/kortexa-ai/aicamera/issues/72

WhatsApp for Mac crops the outgoing 16:9 frame to 4:3 and mirrors its self-view, so AI Camera's
captions and cards fell outside the visible area and text read backwards. Two toolbar quick
controls address this without touching the camera image: **Layout** confines generated content
(captions, status, cards, script overlays) to a centered 4:3 region, and **Mirror** pre-flips that
generated content about the frame's center. Detection boxes and gesture labels stay on the video.
Both states live in UserDefaults like the other quick controls and reach the renderer through
`RuntimeFeatureState.Snapshot.presentation`; the saved profile schema is unchanged.

Host build 57; the camera extension (46) and HAL driver (12) are unchanged. Validation:
`scripts/validate.sh` with the new `OverlayPresentationTests`, then installed acceptance in
WhatsApp with each control on and off, recorded in the issue.

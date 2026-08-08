# AICamera Project Instructions

## Scope

These rules apply to this repository.

## Build and test

- Generate the Xcode project with `scripts/bootstrap.sh`.
- Run the full local validation with `scripts/validate.sh`.
- Keep model endpoints, device IDs, signing teams, and credentials configurable.
- Never add real API keys or signing credentials to tracked files.
- Do not install or activate system extensions or audio drivers during automated tests.
- Treat camera and microphone buffers as private data. Do not persist them unless a user explicitly enables recording.

## Architecture

- Keep media capture and rendering in the macOS host app.
- Keep the CoreMediaIO extension small. It only publishes host-produced frames.
- Keep model integrations behind protocols in `Sources/AICameraCore`.
- Real-time media paths must be bounded and must not wait for network inference.
- Update `PLAN.md` when non-trivial scope or status changes.

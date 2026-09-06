# Agent-input shortcut fixture

[Tracking issue](https://github.com/kortexa-ai/aicamera/issues/61)

Extend the native shortcut fixture to cover Control–Option–Space and repeated-key behavior.
Provide an explicit mode that permits an older running app to retain its exclusive A/M shortcuts,
while still requiring Space registration. This fixture sends synthetic events only to its own
application event target; it does not observe keyboard input or send physical keystrokes.

Keep production shortcut definitions, the installed app, capture, and system components unchanged.
Native event routing does not establish actual spoken conversation acceptance. The durable test
procedure is in `docs/testing.md`; execution and delivery evidence belong in the tracking issue.

# Companion settings compatibility

Issue: https://github.com/kortexa-ai/aicamera/issues/66

Compare the current settings reader/writer with the pinned public 0.2.0 core using disposable
synthetic files. Check default upgrade/downgrade, ignored optional listening fields, rejection and
file preservation for the new weather permission, and recovery after explicitly disabling weather.
Prepare a compact acceptance/rollback guide. Do not mutate user settings, credentials, installed
bundles, system components, or public release tags; do not fetch or silently substitute a release.

# Weather forecasts in the camera

Enable **Settings → AI → Tools → Weather forecasts**, then ask the active agent for a forecast
for a named U.S. place. For example: “Show the Seattle forecast in Fahrenheit.” The agent can use
a compact card or combine the verified forecast with a three.js illustration. A sun or raincloud
is an illustration; it does not follow a face yet.

This uses the [National Weather Service API](https://www.weather.gov/documentation/services-web-api).
Its public API is free to use, including commercial use, and requires an application User-Agent.
Coverage is limited to supported U.S. forecast locations. The tool returns predictions, not current
weather observations, emergency alerts, or worldwide weather. No account or API key is needed.
Market quotes need a separate data provider and are not available through this tool.

## Place and privacy

The tool accepts latitude, longitude, and optional `celsius` or `fahrenheit` units. Celsius is the
default. The agent must use the approximate coordinates of the public place requested by the user,
ask when the place is missing or uncertain, and check the service's nearby city/state against the
request. There is no geocoder in this increment. A service's nearby place can differ from the
requested city; the agent must clarify a mismatch instead of silently relabeling the result.

The host rounds coordinates to two decimal places before making a request. It does not access
device location, infer an address from notes, or include audio, camera frames, transcripts, note
contents, cookies, or model credentials in weather requests. As with other HTTPS services, NWS can
see the requesting device's public IP address. Forecast results return to the active Realtime
conversation and can be shown to other call participants when requested.

The Settings toggle is off by default, including for existing settings. Enabling it adds the exact
`api.weather.gov` host and an `approximateLocation` grant for the built-in `builtin-nws-forecast`
service identity. This fixed data service does not create a model endpoint. Both Tools and weather
must be enabled, and the privacy gate must authorize the host and grant before the tool is offered
or used. Disabling weather revokes its grant; an existing host allowlist entry alone cannot permit
a request. No agent tool can enable this permission. Turning it off does not turn off notes or
other Tools.

## Response and lifetime

`get_weather_forecast` returns up to four upcoming forecast periods. Each has its time interval,
temperature and unit, short conditions, wind description, and precipitation probability when
provided. The result retains the nearby city/state, approximate coordinates, source URL, provider
issuance time, and original retrieval time. Cards should show the period and units, with NWS and
the issuance time in their source footer. The model must not claim a successful lookup after an
error or treat provider text as instructions.

The client resolves the fixed `/points` route, then accepts only a same-host HTTPS grid forecast
URL with the documented shape. Redirects are denied. Each response is capped at 256 KiB, requests
use a six-second timeout and an eight-second resource deadline, and only one lookup may be in
flight. A single location's result can be reused from memory for at most five minutes and only while its
first returned period remains relevant. There is no disk cache or stale fallback on service error.
Forecasts older than 36 hours or issued more than five minutes in the future are rejected. All
network, decoding, and tool continuation work stays outside camera/audio callbacks.

Pausing agent input lets an already requested forecast and answer finish while the call microphone
stays live. Stopping the agent, privacy mute, or disabling the tool cancels/discards pending work.
Provider failures, unsupported coverage, invalid data, and rate limits produce a short failure.
They must not be replaced with a model-invented forecast.

Synthetic and public HTTP checks are described in [testing](testing.md). Spoken tool selection and
a live-call check remain distinct from transport and native-card validation.

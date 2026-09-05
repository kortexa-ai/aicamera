# Separate Codex login for AI Camera

AI Camera can ask the installed Codex CLI to create a separate login for public OpenAI Realtime.
This is the personal integration requested for this app, based on the `esp32-voice` device-login
experiment. It is not a registered AI Camera OAuth client or a promise that a ChatGPT subscription
includes general Platform API usage. The API-key choice remains available and uses Platform billing.

## Sign in

1. Install the [Codex CLI](https://learn.chatgpt.com/docs/cli) if it is not already available.
2. Open **Settings → AI → Conversation**, choose **Codex login**, and press **Sign In to Codex**.
3. Complete the official browser sign-in and enter the code shown in Settings. The page identifies
   Codex because the installed official client owns this login. Device-code sign-in may need to be
   enabled in your ChatGPT account or workspace settings.
4. After the account appears, use **Test Connection** to check the credential and selected model
   without capturing audio. Then save the choice and use Talk. The active-authentication status stays
   on the previously saved option until you save. A Keychain access dialog may appear the first
   time the signed AI Camera app reads this dedicated credential.

**Cancel Sign-in** stops the pending ceremony. **Refresh Login** asks Codex to renew its managed
tokens. **Sign Out** stops an active Talk, disables Conversation when it uses Codex, and clears
only AI Camera's dedicated login through Codex. It does not sign the desktop coding session out.
If an account cannot use public Realtime, select the API-key option explicitly; the app does not
silently fall back to a separately billed key.

## Authentication boundary

The [official app-server interface](https://learn.chatgpt.com/docs/app-server#authentication)
provides `account/login/start` with `chatgptDeviceCode`, completion notifications, cancellation,
`account/read` with managed refresh, and `account/logout`. AI Camera invokes the installed executable
with a private `CODEX_HOME` at `~/Library/Application Support/AI Camera/Codex`, a minimal environment,
and `cli_auth_credentials_store="keyring"`. It creates no agent thread and sends no media to Codex's
app-server. The [Codex authentication guide](https://learn.chatgpt.com/docs/auth#credential-storage)
describes OS credential storage and managed token refresh.

The helper uses private standard-input/output pipes, a 64 KiB JSON-line limit, at most eight pending
requests, 30-second request deadlines, and bounded read delivery. Device URLs and codes are validated
before opening the browser. CLI stderr and raw authentication responses are not copied into app
logs. Termination and malformed output close the helper and fail pending operations. Request
cancellation removes its pending continuation; login cancellation also uses Codex's cancel RPC.

The direct Keychain backend stores a JSON credential bundle under service `Codex Auth` and account
`cli|` plus the first 16 hexadecimal SHA-256 characters of the canonical home path. This integration
follows the [public Codex storage implementation](https://github.com/openai/codex/blob/7dc7c7a7566a970f6d4d09e1384f854aebaf39e0/codex-rs/login/src/auth/storage.rs).
AI Camera reads only the entry for its own directory. Access tokens stay in memory while needed;
refresh tokens remain owned by Codex in Keychain. The app never reads `~/.codex/auth.json`, browser
cookies, the desktop credential entry, or `esp32-voice` credentials. It rejects an existing
`auth.json` in its dedicated directory instead of importing a file-based login.

JWT expiry is decoded only as a local refresh hint. Before a new turn, a token within two minutes
of expiry triggers one managed refresh, followed by a fresh Keychain read. OpenAI validates the
credential. Token refresh, sign-in, and sign-out are serialized; there is no second refresh owner.
The current direct-Keychain layout is a Codex implementation dependency. If it changes, the app
must fail and be updated rather than search other credential stores.

## What is established

The official documentation establishes Codex login and its token lifecycle. The
[public Realtime WebSocket guide](https://developers.openai.com/api/docs/guides/realtime-websocket)
documents bearer API-key authentication. It does not establish that a dedicated Codex OAuth token
is a supported general-purpose Realtime credential or that its audio usage is covered by a
subscription. The separate `esp32-voice` experiment observed public Realtime session acceptance
for this account. AI Camera's signed-app check also completed sign-in, refresh, and public session
setup, and the user heard a spoken reply. A reported playback-speed issue remains under review.
These results establish observed account access, not subscription billing or a distribution contract.

Use the signed-app acceptance procedure in [testing.md](testing.md#codex-login) to verify account
access, speech, refresh, cancellation, and sign-out. Results and remaining limits belong in
[`VALIDATION.md`](../VALIDATION.md). Revisit a general distribution claim only when OpenAI documents
the applicable third-party Realtime authentication and entitlement contract.

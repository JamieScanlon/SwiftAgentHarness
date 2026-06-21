# OAuth callback and token flow

The server serves `GET /oauth/callback` and returns a success/error HTML page. It also **delivers** the callback (authorization `code`, `state`, or `error`) to the SwiftAgentKit manual OAuth flow so the code can be exchanged for a token.

We use SwiftAgentKit’s README: **Convenience (custom callback only)**—we use the `callbackReceiver` parameter to plug in our Vapor route; token exchange and URL opening use library defaults.

## Flow

1. User starts OAuth (e.g. Todoist); SwiftAgentKit opens the auth URL in the browser.
2. User authorizes; provider redirects to `http://localhost:8080/oauth/callback?code=...&state=...`.
3. **APILayer** handles the request: it builds `OAuthCallbackServer.CallbackResult` and calls `OAuthCallbackDelivery.deliver(result:)`, then returns the HTML page.
4. The manual flow (waiting in `receiver.waitForCallback`) receives the result and exchanges the code for a token, then connects with the token.

## Wiring

- Creates `OAuthCallbackDelivery`, passes `delivery.receiver` to `MCPOAuthHandler(callbackReceiver:)`, and sets the delivery on **APILayer** so the route can call `deliver(result:)`.

## Verifying token exchange and headers

After you complete the browser OAuth flow and see the "Authorization successful" page, the following happens in order:

1. **Callback delivery** – Our route receives the redirect and delivers the authorization code to the waiting SwiftAgentKit flow. At **debug** log level you should see:
   - `OAuth callback received (state: ..., code length: N)` (APILayer)
   - `Delivered OAuth callback result to waiting flow (success: true, hadCode: true)` (OAuthCallbackDelivery)

2. **Token exchange** – SwiftAgentKit exchanges the code for an access token at the provider's token endpoint. If this succeeds, you should see (from SwiftAgentKit):
   - `Successfully connected to remote MCP server with new OAuth token` (MCPOAuthHandler).
   If you do **not** see this after the callback logs, token exchange failed (e.g. wrong endpoint, missing `client_secret`, or provider error). Check SwiftAgentKit and any token-exchange error in the logs.

3. **Token on requests** – When the MCP client sends a request to the remote server (e.g. Todoist), the transport adds the token via `Authorization: Bearer <token>`. To confirm this, enable **debug** logging for SwiftAgentKit (e.g. `SwiftAgentKitMCP` / `RemoteTransport`) and look for:
   - `Added authentication headers` (RemoteTransport.send).

If (1) and (2) appear but you still get 401 on tool calls, either the token is not being attached (check step 3) or the provider is rejecting the token (e.g. wrong scope or resource).

## Troubleshooting: HTTP 401 Unauthorized (e.g. Todoist)

- **Scope:** Todoist does not support the default `mcp` scope. Use a space-separated list of Todoist scopes (RFC 6749 §3.3), e.g. `"scope": "data:read data:read_write task:add"`. SwiftAgentKit validates each token against the server's `scopes_supported` and sends the combined value in the auth URL and token request. After changing scope, re-authorize so the new token has the chosen scopes.
- **Keychain -34018:** If you see "Keychain storage failed, switching to in-memory storage", the token is stored only in memory and is lost when the process exits. You will need to complete OAuth again on each restart. Fix keychain access (e.g. entitlements or run outside a sandbox that blocks keychain).
- **Expired or invalid token:** Clear the stored Todoist token and re-run the OAuth flow (e.g. `MCPOAuthHandler.removeAuthentication(for: "todoist")` or delete the keychain/in-memory entry for the server).
- **First-time connection:** Ensure the API server is running on port 8080 so `http://localhost:8080/oauth/callback` is reachable when the provider redirects.

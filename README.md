```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             curl -fsSL https://fx.sh/setup.sh | bash
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

fx is a coding agent CLI written in Zig: a small native binary that is open source (Apache-2.0), model-agnostic, and embeddable as a harness in larger systems. Its interface stays closer to a Unix shell than an IDE in the terminal.

## Highlights

- **Any model:** Vercel AI Gateway, ChatGPT or Grok subscriptions, or your own OpenAI-compatible endpoint such as Ollama or OpenRouter
- **Any interface:** interactive shell, one-shot `fx ask` for scripts, or embedded through libfx and ACP
- **Shell-like output:** inline rendering that preserves your terminal scrollback
- **Extensible:** skills, MCP servers, and subagents

<p>
  <a href="https://vercel.com/labs#labs-products"><img alt="Vercel Labs Product" src="https://img.shields.io/badge/LABS-PRODUCT-0a0a0a.svg?style=for-the-badge&amp;logo=Vercel&amp;labelColor=000000" height="28"></a>
  <a href="https://github.com/vercel-labs/fx/releases/latest"><img alt="fx CLI release" src="https://img.shields.io/github/v/release/vercel-labs/fx.svg?style=for-the-badge&amp;labelColor=000000&amp;label=release" height="28"></a>
  <a href="https://github.com/vercel-labs/fx/blob/main/LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/github/license/vercel-labs/fx.svg?style=for-the-badge&amp;labelColor=000000" height="28"></a>
</p>

## Install

```bash
curl -fsSL https://fx.sh/setup.sh | bash
```

## Get started

Sign in with one of:

- `fx login`: Vercel AI Gateway
- `fx login codex`: ChatGPT subscription (OpenAI Codex OAuth)
- `fx login grok`: Grok subscription (xAI OAuth)
- `fx setup`: AI Gateway API key

Then start the interactive shell from a project:

```bash
cd your_project
fx
```

Or make a one-shot request:

```bash
fx ask "explain the changes in this repository"
```

Inside the shell, run `/help` to browse interactive commands.

In tmux, use your usual prefix bindings to switch sessions or enter copy mode.
fx preserves those tmux views while resizing, including when the switcher zooms a split pane.

## Documentation

Visit [fx.sh/docs](https://fx.sh/docs) for the full manual: sessions, models, custom model connections, permissions, configuration, skills, MCP, subagents, embedding, and the complete CLI and slash command references. Agents can read any page as Markdown by appending `.md` to its URL, or fetch [llms-full.txt](https://fx.sh/llms-full.txt) for everything in one file.

## Custom model connections

Add named connections for any OpenAI Chat Completions endpoint, including local servers such as Ollama, gateways such as OpenRouter, and first-party APIs such as DeepSeek:

```bash
fx provider add deepseek
fx provider add local --base-url http://localhost:11434/v1 --no-auth --model llama3 --context-window 8192
fx provider add openrouter --base-url https://openrouter.ai/api/v1 --api-key-env OPENROUTER_API_KEY --model openai/gpt-4.1
fx provider list
fx provider remove deepseek
```

`add` writes the connection to `~/.fx/settings.json`, saves the selected model, and switches the profile to it. Known presets such as `deepseek` prefill the endpoint, API key environment variable, model, context window, tool support, and reasoning efforts. Pass `--save-api-key` to store the key under `~/.fx/provider-credentials/` (0600) instead of reading an environment variable, `--no-select` to define a connection without switching to it, and `--reasoning-efforts low,high,max` to advertise `reasoning_effort` values for endpoints that support them.

The `/provider` picker lists saved connections beside the builtin providers and adds `add connection…` and `manage connections…` rows. The wizard walks through the connection name, endpoint, auth, model, and metadata, writes the same settings as the CLI, and masks the API key while it is typed. `manage connections…` edits or removes saved connections without leaving the session; removing the active connection falls back to Vercel.

Connections remain plain JSON and can still be hand-edited or committed. Select one for a single invocation with environment variables:

```bash
FX_PROVIDER=openrouter FX_MODEL=openai/gpt-4.1 fx ask "review this change"
```

For DeepSeek, use `https://api.deepseek.com`; fx appends `/chat/completions`. A `base_url` that already names the `/chat/completions` endpoint is accepted unchanged.

See [Custom model connections](https://fx.sh/docs/configure-fx/custom-model-connections) for connection JSON, model metadata, and behavior details.

## Gateway provider routing

When the active model goes through the Vercel AI Gateway, one model is often served by several providers (for example Anthropic directly, AWS Bedrock, or Google Vertex). fx can tell the gateway which providers to use, in what order:

```jsonc
// ~/.fx/settings.json
{
  "provider_order": ["bedrock", "anthropic"], // try Bedrock first, then Anthropic
  "provider_strict": false                     // true restricts requests to only these providers
}
```

Both keys also work in a committed project `.fx.json`, and per launch:

```bash
fx --provider-order azure,openai --provider-strict
fx ask --provider-order bedrock "review this change"
FX_PROVIDER_ORDER=vertex FX_PROVIDER_STRICT=1 fx
```

Slugs are the gateway's provider identifiers (letters, digits, dashes, for example `anthropic`, `bedrock`, `vertexAnthropic`), listed on the [models page](https://vercel.com/ai-gateway/models). An empty `provider_order` in a higher-precedence layer clears a list set by a lower one. Routing applies to gateway requests only; custom model connections ignore it.

## Themes

fx ships with `fx-dark` and `fx-light` and follows your terminal's light or dark mode. Pin a variant with `FX_THEME=light` or `FX_THEME=dark`, or drop a VS Code format theme at `~/.fx/themes/<name>.json` and select it with the `theme` setting or `FX_THEME=<name>` per launch. Without an explicitly selected theme, diff markers and edit counts stay monochrome; selecting any theme adds its diff marker colors. See [Configuration](https://fx.sh/docs/configure-fx/configuration) for all environment variables.

## Login shell

Shell commands run through a supported login shell (`bash`, `zsh`, `sh`, or `dash`). fx resolves it from your passwd entry and falls back to the first installed shell when the configured shell is unsupported or missing. Set `login_shell` to an absolute shell path in `~/.fx/settings.json`, or override it per launch with `FX_LOGIN_SHELL=<path>`. `fx status` reports the resolved shell and `fx doctor` warns when a configured shell is unavailable.

## Outbound proxy

Route outbound traffic through an HTTP proxy by adding a `proxy` block to `~/.fx/settings.json`, or pass it per launch:

```jsonc
// ~/.fx/settings.json
{
  "proxy": {
    "url": "http://user:pass@proxy.example:8080",
    "no_proxy": ["localhost", ".corp", "10.0.0.0/8"],
    "apply_to": ["model"] // model, mcp, upgrade, children, web, or all
  }
}
```

```bash
fx --proxy http://127.0.0.1:8080
fx ask --proxy http://127.0.0.1:8080 --proxy-apply-to model,upgrade "review this change"
FX_PROXY=http://127.0.0.1:8080 fx
```

`apply_to` defaults to `model`, which covers the AI Gateway, custom model connections, model catalogs, version checks, the permission reviewer, and provider sign-in. `mcp` covers HTTP and SSE MCP transports, `upgrade` covers auto-upgrade and `fx upgrade`, `web` covers `web_fetch`, and `children` exports `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` to shell commands, stdio MCP servers, and skill installs. `all` names every surface at once. An unknown name is an error rather than a silently narrower scope, so a typo cannot leave traffic on a direct connection. `children` stays off unless you name it, so child processes keep inheriting your environment.

The standard `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`, and `NO_PROXY` variables apply to every surface that has no explicit setting, so a narrow `apply_to` leaves the rest of your environment alone. fx reads the layers in this order: `--proxy` with `--no-proxy` and `--proxy-apply-to`, then `FX_PROXY`, `FX_NO_PROXY`, and `FX_PROXY_APPLY_TO`, then `proxy` under `workspaces["<workspace_path>"]`, then the top-level `proxy` block, then the standard variables. `no_proxy` accepts hosts, `.suffix` entries, `*`, `host:port`, IPv4 and IPv6 addresses, and CIDR blocks, and it replaces the default list of `localhost`, `127.0.0.1`, and `::1`.

fx fails closed. A proxy that is configured but unusable stops the process instead of opening a direct connection, and only a bypass entry produces one. `fx doctor` reports that failure as a check instead of exiting, so it stays usable when every other command refuses to start.

`web_fetch` resolves, dials, and pins its own sockets so a target cannot slip past the public-address policy. With `web` in scope it sends a plain HTTP request in absolute form, and for HTTPS it asks the proxy for a `CONNECT` tunnel and still verifies the target certificate against the target name, so the proxy can neither read nor alter the request. The target address policy still runs first, which keeps `web_fetch` on public endpoints even behind a proxy, and an `https://` proxy URL is refused for that surface because the fetch transport would have to nest its own TLS session inside one it cannot verify.

The **Proxy** row in `/settings` edits the stored URL and shows it with credentials masked, and a saved change takes effect on the next launch. `/status` lists the effective proxy for each surface, and `fx doctor` names the layer that supplied the URL.

A URL passed on the command line is visible to other users in `ps`, and a `children` proxy exports the URL with its credentials to every child process. Store it in `~/.fx/settings.json`, which fx keeps at mode 0600, when that matters.

## Embed fx

fx builds as a native binary or WebAssembly. Applications embedding fx can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `fx acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

ACP clients can keep their MCP tools loaded on every turn, steer a running turn, supply a session system prompt, serve MCP servers over the ACP connection, and choose each session's workspace. See [ACP embedding](CONTRIBUTING.md#acp-embedding).

The SDK is published to npm as [libfx](https://www.npmjs.com/package/libfx). See the [WebAssembly SDK](sdk/README.md) and the runnable Node.js, browser, Next.js, and Nuxt [examples](examples/README.md). The WebAssembly SDK is experimental.

## Slack workspace installation

Run `fx slack install` to install the fx bot in the configured Vercel Slack
workspace. Keep the command running and authorize Slack in a browser on the same
computer. The HTTPS callback at fx.sh returns the authorization to the CLI;
PKCE state and the verifier stay in memory. The companion web bridge must be
deployed and configured first.

After the CLI saves the installation, the browser returns to an fx.sh confirmation
page. You can close that tab or refresh it after the command exits.

`fx slack status --json` reports local installation metadata without tokens.
Plain-text output omits Slack IDs and shows expiration as a readable UTC date
and time. JSON output retains the IDs and Unix timestamps for scripts.
`fx slack refresh` rotates the local bot credentials when needed. Credentials
live in the owner-only file `~/.fx/slack/installation.json`; no hosted database
or background refresh service is created. An expired refresh token requires
installation again. This workspace operation is separate from each employee's
MCP user authorization. Employees connect their own account with
`/mcp auth slack --open` in an fx session (or `fx mcp auth slack` from a terminal).
For `https://mcp.slack.com/mcp`, the CLI recognizes the fx app by its public
Client ID and uses the HTTPS callback for personal login. Changing that Client
ID requires a CLI update. OAuth uses the canonical form of Slack's advertised
resource, `https://mcp.slack.com/`, while the MCP transport remains at
`https://mcp.slack.com/mcp`. First login and reauthorization request the full shared
`user_scopes` list from fx.sh. If local `scopes` are configured, they must include
every shared scope; extra local scopes are not requested. A narrower or explicitly
empty list stops authorization before opening the browser, leaving the configuration
and stored credentials unchanged. Remove the override only if you want to authorize
the full shared scope set. Per-user read-only subsets are not supported for the fx app. Saved scopes,
Slack's advertised capabilities, and scope challenges cannot expand this
request. The shared list contains nine personal scopes configured for fx and
advertised by Slack MCP; changing it requires a deliberate configuration update
and any necessary Slack approval. This does not revoke
permissions on previously issued tokens or change token refresh behavior. It
opens an ephemeral loopback listener instead of the configured `callback_port`,
keeps PKCE and personal tokens in the CLI, and shows “Slack connected” after
saving to the existing MCP credential store. Other MCP providers and different
Slack app Client IDs retain their direct callback behavior without contacting
fx.sh. Fx app authorization requires fx.sh to be available; an unavailable
metadata endpoint returns `SlackBridgeUnavailable`. Deploy the web
personal-authorization routes and scope metadata before releasing this CLI.
Missing or invalid shared scopes stop authorization rather than falling back
to Slack's broader capabilities. Keep the registered
localhost callback for older clients until they have upgraded. Slack workspace
approval requirements still apply to personal authorization.

Bot installation does not establish whether
Slack will display a hoverable “Sent using @fx” attribution; that requires a
live message test.

## Build from source

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/vercel-labs/fx.git
cd fx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## Security

Report security vulnerabilities through the [contact page](https://fx.sh/contact) instead of a public issue.

## License

[Apache-2.0](LICENSE). Third-party licenses and attributions are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).

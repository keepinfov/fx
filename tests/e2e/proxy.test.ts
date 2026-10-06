import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  cleanupIsolatedTestHome,
  createIsolatedTestHome,
  runFx,
} from "../evals/eval-helpers";
import { createConfiguredProviderFixture } from "./fixtures/chat-completions";

/**
 * A minimal HTTP forward proxy. It records every request it carries and
 * forwards that request to the origin named by the absolute-form request
 * target.
 *
 * fx probes the provider once with CONNECT before a model request. Answering
 * CONNECT with 501 keeps the probe from tunnelling, and the model request still
 * travels through the proxy, so the recorded requests stay the evidence that
 * matters here.
 */
function startForwardProxy() {
  const seen: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      seen.push(`${request.method} ${request.url}`);
      if (request.method === "CONNECT") return new Response("connect refused", { status: 501 });
      const headers = new Headers(request.headers);
      for (const hop of ["host", "connection", "content-length", "accept-encoding"]) {
        headers.delete(hop);
      }
      const body = request.method === "POST" ? await request.arrayBuffer() : undefined;
      return fetch(request.url, { method: request.method, headers, body });
    },
  });
  return {
    url: `http://127.0.0.1:${server.port}`,
    seen,
    stop() {
      server.stop(true);
    },
  };
}

/**
 * Environment that clears every standard proxy variable, so only the explicit
 * configuration under test can route traffic.
 */
function proxyEnv(env: Record<string, string | undefined>, extra: Record<string, string | undefined>) {
  return {
    ...env,
    HTTPS_PROXY: undefined,
    HTTP_PROXY: undefined,
    ALL_PROXY: undefined,
    NO_PROXY: undefined,
    https_proxy: undefined,
    http_proxy: undefined,
    all_proxy: undefined,
    no_proxy: undefined,
    ...extra,
  };
}

function closedPort(): number {
  const probe = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response("") });
  const port = probe.port;
  probe.stop(true);
  return port;
}

/**
 * A raw TCP proxy that answers CONNECT with 200 and then records every byte the
 * client sends inside the tunnel.
 *
 * `startForwardProxy` never gets this far because it refuses CONNECT, so it can
 * only observe plaintext forwarding. Whether the origin request is encrypted is
 * only visible on the raw tunnel bytes, which is what this probe captures.
 */
function startTunnelProbeProxy() {
  const connects: string[] = [];
  const chunks: Buffer[] = [];
  type Probe = { mode: "headers" | "tunnel"; buffer: string };
  const sockets = new Map<object, Probe>();
  const server = Bun.listen({
    hostname: "127.0.0.1",
    port: 0,
    socket: {
      open(socket) {
        sockets.set(socket, { mode: "headers", buffer: "" });
      },
      data(socket, data) {
        const probe = sockets.get(socket);
        if (!probe) return;
        if (probe.mode === "headers") {
          probe.buffer += Buffer.from(data).toString("latin1");
          const end = probe.buffer.indexOf("\r\n\r\n");
          if (end === -1) return;
          connects.push(probe.buffer.slice(0, end).split("\r\n")[0] ?? "");
          const rest = probe.buffer.slice(end + 4);
          probe.mode = "tunnel";
          probe.buffer = "";
          socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
          if (rest.length > 0) chunks.push(Buffer.from(rest, "latin1"));
          // Hang up once the client has had a moment to flush its request, so
          // the run terminates instead of waiting on a reply this probe never
          // sends.
          setTimeout(() => socket.end(), 250);
          return;
        }
        chunks.push(Buffer.from(data));
      },
      close(socket) {
        sockets.delete(socket);
      },
      error(socket) {
        sockets.delete(socket);
      },
    },
  });
  return {
    url: `http://127.0.0.1:${server.port}`,
    connects,
    bytes: () => Buffer.concat(chunks),
    stop() {
      server.stop(true);
    },
  };
}

function isolatedHomeWithFxDir(): string {
  const home = realpathSync(createIsolatedTestHome());
  mkdirSync(join(home, ".fx"), { mode: 0o700 });
  return home;
}

describe("outbound proxy", () => {
  test("carries model traffic through the configured proxy", async () => {
    const fixture = createConfiguredProviderFixture();
    const proxy = startForwardProxy();
    try {
      const result = await runFx(["ask", "--json", "--no-save", "hello"], {
        cwd: fixture.workspace,
        env: proxyEnv(fixture.env, {
          FX_PROXY: proxy.url,
          FX_PROXY_APPLY_TO: "model",
          // An empty list routes even loopback through the proxy, which is the
          // only way a local endpoint can exercise the proxy path.
          FX_NO_PROXY: "",
        }),
        timeoutMs: 30000,
      });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(JSON.parse(result.stdout).output).toBe("local reply");
      expect(fixture.requests).toHaveLength(1);
      expect(proxy.seen.some(entry => entry.includes("/v1/chat/completions"))).toBe(true);
    } finally {
      proxy.stop();
      fixture.close();
    }
  }, 45000);

  test("leaves the local endpoint direct while the proxy covers model traffic", async () => {
    const fixture = createConfiguredProviderFixture();
    const proxy = startForwardProxy();
    try {
      const result = await runFx(["ask", "--json", "--no-save", "hello"], {
        cwd: fixture.workspace,
        // The default bypass list keeps local model servers reachable without
        // touching the proxy.
        env: proxyEnv(fixture.env, { FX_PROXY: proxy.url, FX_PROXY_APPLY_TO: "model" }),
        timeoutMs: 30000,
      });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(fixture.requests).toHaveLength(1);
      expect(proxy.seen).toEqual([]);
    } finally {
      proxy.stop();
      fixture.close();
    }
  }, 45000);

  test("never falls back to a direct connection when the proxy is unreachable", async () => {
    const fixture = createConfiguredProviderFixture();
    try {
      const result = await runFx(["ask", "--json", "--no-save", "hello"], {
        cwd: fixture.workspace,
        env: proxyEnv(fixture.env, {
          FX_PROXY: `http://127.0.0.1:${closedPort()}`,
          FX_PROXY_APPLY_TO: "model",
          FX_NO_PROXY: "",
        }),
        timeoutMs: 15000,
      });
      expect(result.code).not.toBe(0);
      expect(fixture.requests).toHaveLength(0);
    } finally {
      fixture.close();
    }
  }, 40000);

  test("reports the stored proxy and its scope per surface", async () => {
    const home = isolatedHomeWithFxDir();
    try {
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({
          proxy: {
            url: "http://user:hidden@127.0.0.1:3128",
            no_proxy: [".corp"],
            apply_to: ["model", "mcp"],
          },
        }),
        { mode: 0o600 },
      );
      const result = await runFx(["status"], {
        env: proxyEnv({ HOME: home }, {}),
        timeoutMs: 20000,
      });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(result.stdout).toContain("proxy=http://[redacted]@127.0.0.1:3128");
      expect(result.stdout).toContain("proxy_origin=settings");
      expect(result.stdout).toContain("proxy_surfaces=model:configured mcp:configured upgrade:off children:off web:off");
      expect(result.stdout).not.toContain("hidden");

      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ proxy: { url: "http://127.0.0.1:3128", apply_to: ["web"] } }),
        { mode: 0o600 },
      );
      const webOnly = await runFx(["status"], {
        env: proxyEnv({ HOME: home }, {}),
        timeoutMs: 20000,
      });
      if (webOnly.code !== 0) throw new Error(webOnly.stdout + webOnly.stderr);
      expect(webOnly.stdout).toContain("proxy_surfaces=model:off mcp:off upgrade:off children:off web:configured");
    } finally {
      cleanupIsolatedTestHome(home);
    }
  }, 40000);

  test("exports the proxy to child processes only for the children surface", async () => {
    const fixture = createConfiguredProviderFixture();
    const probePath = join(fixture.home, "probe.sh");
    const dumpPath = join(fixture.home, "probe-env.txt");
    const proxyUrl = "http://10.255.255.1:8080";
    try {
      writeFileSync(probePath, `#!/bin/sh\nenv | grep -i proxy | sort > ${dumpPath}\nsleep 1\n`, { mode: 0o755 });
      writeFileSync(
        join(fixture.home, ".fx", "mcp.json"),
        JSON.stringify({ mcpServers: { probe: { command: "/bin/sh", args: [probePath] } } }),
        { mode: 0o600 },
      );
      const writeSettings = (applyTo: string[]) =>
        writeFileSync(
          join(fixture.home, ".fx", "settings.json"),
          JSON.stringify({ proxy: { url: proxyUrl, no_proxy: [".corp"], apply_to: applyTo } }),
          { mode: 0o600 },
        );

      writeSettings(["model"]);
      await runFx(["mcp", "list", "--connect"], { env: proxyEnv(fixture.env, {}), timeoutMs: 25000 });
      const modelOnly = existsSync(dumpPath) ? readFileSync(dumpPath, "utf8") : "";
      expect(modelOnly).not.toContain("HTTP_PROXY");

      writeSettings(["model", "children"]);
      await runFx(["mcp", "list", "--connect"], { env: proxyEnv(fixture.env, {}), timeoutMs: 25000 });
      const withChildren = readFileSync(dumpPath, "utf8");
      expect(withChildren).toContain(`HTTP_PROXY=${proxyUrl}`);
      expect(withChildren).toContain(`http_proxy=${proxyUrl}`);
      expect(withChildren).toContain(`HTTPS_PROXY=${proxyUrl}`);
      expect(withChildren).toContain("NO_PROXY=.corp");
      expect(withChildren).toContain("no_proxy=.corp");
    } finally {
      fixture.close();
    }
  }, 70000);

  test("stops on an unusable proxy configuration and lets doctor explain it", async () => {
    const home = isolatedHomeWithFxDir();
    try {
      const env = proxyEnv({ HOME: home }, { FX_PROXY: "socks5://127.0.0.1:1080" });
      const status = await runFx(["status"], { env, timeoutMs: 20000 });
      expect(status.code).not.toBe(0);
      expect(status.stderr).toContain("invalid proxy configuration");

      const doctor = await runFx(["doctor"], { env, timeoutMs: 20000 });
      expect(doctor.stdout).toContain("[fail] proxy:");
    } finally {
      cleanupIsolatedTestHome(home);
    }
  }, 30000);

  test("proxy TLS: never sends the origin request in plaintext through a proxy", async () => {
    const originPort = closedPort();
    const marker = "fx-tunnel-marker-9f3c1a";
    const fixture = createConfiguredProviderFixture(undefined, {
      baseUrl: `https://127.0.0.1:${originPort}/v1`,
    });
    const probe = startTunnelProbeProxy();
    try {
      const result = await runFx(["ask", "--json", "--no-save", "hello"], {
        cwd: fixture.workspace,
        env: proxyEnv(fixture.env, {
          FX_PROVIDER: "remote",
          FX_TEST_PROVIDER_TOKEN: marker,
          FX_PROXY: probe.url,
          FX_PROXY_APPLY_TO: "model",
          // Route even loopback through the proxy so the tunnel is exercised.
          FX_NO_PROXY: "",
        }),
        timeoutMs: 25000,
      });

      // The proxy must never see the origin credentials or the request body in
      // the clear. Two outcomes are acceptable: a real TLS handshake to the
      // origin inside the tunnel, or a refusal that never opens the connection.
      // A plaintext request line is exactly the defect this pins.
      const bytes = probe.bytes();
      const asText = bytes.toString("latin1");
      expect(asText).not.toContain(marker);
      expect(/^(POST|GET|PUT|PATCH|DELETE) /.test(asText)).toBe(false);
      if (bytes.length > 0) expect(bytes[0]).toBe(0x16);
      expect(result.code).not.toBe(0);
    } finally {
      probe.stop();
      fixture.close();
    }
  }, 45000);
});

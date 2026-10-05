//! Outbound proxy policy for fx.
//!
//! One process-wide resolution decides whether a network surface may use a
//! proxy, and a per-client factory applies it to `std.http.Client`. std owns
//! the transport: `Client.http_proxy` / `Client.https_proxy` hold `*Proxy`
//! values that must outlive the client, and std implements the CONNECT tunnel
//! and the plain absolute-form request path. std has no `no_proxy` concept at
//! all, so bypass matching (host, suffix, host:port, `*`, IP, CIDR) lives here.
//!
//! Policy, highest priority first:
//!   1. an explicit surface scope (`apply_to`), resolved once at startup from
//!      `FX_PROXY` today and from profile settings once those land;
//!   2. standard `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` / `NO_PROXY`,
//!      applied to every surface that has no explicit setting. This mirrors
//!      std's own `initDefaultProxies` lists so the environment keeps behaving
//!      the way it does for curl and git;
//!   3. no proxy.
//!
//! Fail closed: when a proxy is selected for a surface, the client is never
//! silently downgraded to a direct connection. Only an explicit bypass entry
//! produces a direct client. A proxy that is configured but unreachable
//! surfaces the transport error instead of a direct retry.

const std = @import("std");
const io_mod = @import("io.zig");
const text_utils = @import("text_utils.zig");

/// Network surfaces that can be routed independently.
///
/// `children` covers exported proxy environment variables for child processes
/// (shell, stdio MCP servers, git). It is accepted in `apply_to` but export
/// wiring is not implemented yet, so it currently has no effect.
pub const Surface = enum { model, mcp, upgrade, children };

/// Default scope of an explicit proxy: model traffic only. MCP, upgrade, and
/// child processes keep using the standard environment fallback.
pub const default_apply_to = &[_]Surface{.model};

/// Loopback names and addresses are never sent to an explicitly configured
/// proxy unless the list is replaced. Local model servers (Ollama, LM Studio,
/// vLLM) and local MCP servers are plain loopback traffic, and routing them
/// through a corporate proxy breaks them without adding any security.
pub const default_no_proxy = &[_][]const u8{ "localhost", "127.0.0.1", "::1" };

pub const Config = struct {
    /// Proxy URL, for example `http://user:pass@127.0.0.1:8080`.
    url: []const u8,
    /// Bypass entries. Empty slice means "nothing bypasses".
    no_proxy: []const []const u8 = default_no_proxy,
    apply_to: []const Surface = default_apply_to,
};

pub const ConfigError = error{ InvalidProxyUrl, UnsupportedProxyScheme, OutOfMemory };

/// Explicit configuration layers, highest priority first. `override` carries
/// per-launch flags, `stored` carries profile settings after the config
/// runtime merged workspace and profile layers. `FX_PROXY` sits between them
/// and the standard environment fallback.
pub const Sources = struct {
    override: ?Config = null,
    stored: ?Config = null,
};

/// A `proxy` block from `settings.json`. Owns its strings and lists.
pub const StoredConfig = struct {
    url: []const u8,
    /// Null keeps `default_no_proxy`.
    no_proxy: ?[]const []const u8 = null,
    /// Null keeps `default_apply_to`.
    apply_to: ?[]const Surface = null,

    pub fn deinit(self: *StoredConfig, alloc: std.mem.Allocator) void {
        alloc.free(self.url);
        if (self.no_proxy) |entries| {
            for (entries) |entry| alloc.free(@constCast(entry));
            alloc.free(entries);
        }
        if (self.apply_to) |surfaces| alloc.free(surfaces);
        self.* = undefined;
    }

    /// Borrowed resolution view; valid while this value lives.
    pub fn config(self: *const StoredConfig) Config {
        return .{
            .url = self.url,
            .no_proxy = self.no_proxy orelse default_no_proxy,
            .apply_to = self.apply_to orelse default_apply_to,
        };
    }
};

const Rule = union(enum) {
    all,
    /// Exact host or boundary suffix match, lowercased, without a leading dot.
    host: []const u8,
    host_port: HostPortRule,
    cidr4: Cidr4,
    cidr6: Cidr6,

    const HostPortRule = struct { host: []const u8, port: u16 };
    const Cidr4 = struct { addr: [4]u8, bits: u6 };
    const Cidr6 = struct { addr: [16]u8, bits: u7 };
};

const SurfaceSet = std.EnumSet(Surface);

const State = struct {
    arena: std.heap.ArenaAllocator,
    explicit_url: ?[]const u8 = null,
    explicit_proxy: ?*std.http.Client.Proxy = null,
    explicit_rules: []const Rule = &.{},
    explicit_surfaces: SurfaceSet = SurfaceSet.initEmpty(),
    env_http_proxy: ?*std.http.Client.Proxy = null,
    env_https_proxy: ?*std.http.Client.Proxy = null,
    env_rules: []const Rule = &.{},
    env_configured: bool = false,
};

/// Process-lifetime resolution, installed once at startup before threads that
/// open connections are spawned. Every field is read-only afterwards, so
/// `applyToClient` never allocates and is safe to call from any thread.
var global_state: ?*State = null;

const EnvSource = struct {
    map: ?*const std.process.Environ.Map = null,

    fn get(self: EnvSource, key: []const u8) ?[]const u8 {
        if (self.map) |map| return map.get(key);
        return io_mod.getenv(key);
    }
};

/// Installs the explicit configuration from flags and profile settings, with
/// `FX_PROXY` in between and the standard environment as the fallback for
/// surfaces without an explicit setting. Called once by the composition root;
/// a later call replaces the previous resolution.
pub fn initResolved(sources: Sources) ConfigError!void {
    return resolveAndInstall(.{}, sources);
}

/// Installs the environment-driven configuration only: `FX_PROXY` and its
/// companions when present, otherwise the standard proxy variables alone.
pub fn initFromEnvironment() ConfigError!void {
    return resolveAndInstall(.{}, .{});
}

/// Test and embedder entry point: reads the same variables as
/// `initFromEnvironment` but from `environ` instead of the process block.
fn initFromEnvMap(environ: *const std.process.Environ.Map, sources: Sources) ConfigError!void {
    return resolveAndInstall(.{ .map = environ }, sources);
}

/// Releases the process-wide resolution. Only tests need this; production
/// resolves once and keeps the state for the process lifetime.
fn reset() void {
    if (global_state) |state| destroyState(state);
    global_state = null;
}

fn destroyState(state: *State) void {
    const child_allocator = state.arena.child_allocator;
    state.arena.deinit();
    child_allocator.destroy(state);
}

/// The resolution outlives every caller, so it is allocated from a dedicated
/// process-lifetime allocator rather than one owned by a caller that may only
/// live for a command or a test.
fn newState() ConfigError!*State {
    const state = try std.heap.page_allocator.create(State);
    state.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    return state;
}

fn resolveAndInstall(env: EnvSource, sources: Sources) ConfigError!void {
    const state = try newState();
    errdefer destroyState(state);
    // The private arena owns the whole resolution, including the config
    // entries parsed out of the environment.
    const arena = state.arena.allocator();

    if (sources.override) |config| {
        try applyExplicit(state, arena, config);
    } else if (explicitConfigFromEnv(arena, env)) |config| {
        try applyExplicit(state, arena, config);
    } else if (sources.stored) |config| {
        try applyExplicit(state, arena, config);
    }
    try applyEnvironment(state, arena, env);

    if (global_state) |previous| destroyState(previous);
    global_state = state;
}

fn explicitConfigFromEnv(arena: std.mem.Allocator, env: EnvSource) ?Config {
    const raw_url = env.get("FX_PROXY") orelse return null;
    const url = std.mem.trim(u8, raw_url, " \t\r\n");
    if (url.len == 0) return null;

    const no_proxy = if (env.get("FX_NO_PROXY")) |raw|
        splitList(arena, raw) catch return null
    else
        default_no_proxy;

    const apply_to = if (env.get("FX_PROXY_APPLY_TO")) |raw| blk: {
        const parsed = splitList(arena, raw) catch return null;
        const surfaces = surfaceList(arena, parsed) catch return null;
        break :blk if (surfaces.len == 0) default_apply_to else surfaces;
    } else default_apply_to;

    return .{ .url = url, .no_proxy = no_proxy, .apply_to = apply_to };
}

fn applyExplicit(state: *State, arena: std.mem.Allocator, config: Config) ConfigError!void {
    const url = std.mem.trim(u8, config.url, " \t\r\n");
    if (url.len == 0) return;
    // Build the proxy from the arena copy, never from the caller's buffer:
    // std keeps pointers into the URL (its host may alias the input string)
    // for the lifetime of the client, and a caller that owns that buffer, such
    // as the parsed settings JSON, may free it long before the last request.
    state.explicit_url = try arena.dupe(u8, url);
    state.explicit_proxy = try buildProxy(arena, state.explicit_url.?);
    state.explicit_rules = try parseRules(arena, config.no_proxy);
    state.explicit_surfaces = surfaceSet(config.apply_to);
}

fn applyEnvironment(state: *State, arena: std.mem.Allocator, env: EnvSource) ConfigError!void {
    // A missing environment block is not fatal: the process then behaves as it
    // did before proxy support existed and opens direct connections.
    var map = if (env.map) |provided|
        provided.clone(arena) catch return
    else
        io_mod.cloneEnvironMap(arena) catch return;

    state.env_rules = try parseRules(arena, try splitList(arena, map.get("NO_PROXY") orelse map.get("no_proxy") orelse ""));
    state.env_http_proxy = try envProxy(arena, map, &.{ "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY" });
    state.env_https_proxy = try envProxy(arena, map, &.{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" });
    state.env_configured = state.env_http_proxy != null or state.env_https_proxy != null;
}

/// The standard variable lists std itself reads. A value std cannot represent,
/// such as a `socks5://` endpoint, is skipped rather than failing startup:
/// foreign proxy variables must not keep fx from running.
fn envProxy(
    arena: std.mem.Allocator,
    map: std.process.Environ.Map,
    names: []const []const u8,
) ConfigError!?*std.http.Client.Proxy {
    for (names) |name| {
        const value = map.get(name) orelse continue;
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) continue;
        return buildProxy(arena, trimmed) catch continue;
    }
    return null;
}

/// Whether `surface` resolves to a proxy at all. Diagnostics only: the exact
/// per-request decision also depends on the request host.
pub fn isEnabled(surface: Surface) bool {
    const state = global_state orelse return false;
    if (surface == .children) return false;
    if (state.explicit_proxy != null and state.explicit_surfaces.contains(surface)) return true;
    return state.env_configured;
}

/// The explicit proxy URL with credentials masked, or null when no explicit
/// proxy is configured. Caller owns the returned memory.
pub fn maskedExplicitUrl(alloc: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
    const state = global_state orelse return null;
    const url = state.explicit_url orelse return null;
    return try text_utils.redactUrlForDisplay(alloc, url);
}

/// Applies the process proxy policy to an already-created client. Safe to call
/// when no proxy is configured; `url` is the request target whose host decides
/// bypass matching. Read-only: no allocation, no locking, any thread.
pub fn applyToClient(client: *std.http.Client, surface: Surface, url: []const u8) void {
    const state = global_state orelse return;
    if (surface == .children) return;

    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const target = targetOf(url, &host_buffer) orelse return;

    if (state.explicit_proxy) |proxy| {
        if (state.explicit_surfaces.contains(surface)) {
            if (ruleMatches(state.explicit_rules, target.host, target.port)) return;
            client.http_proxy = proxy;
            client.https_proxy = proxy;
            return;
        }
    }

    if (state.env_http_proxy == null and state.env_https_proxy == null) return;
    if (ruleMatches(state.env_rules, target.host, target.port)) return;
    client.http_proxy = state.env_http_proxy;
    client.https_proxy = state.env_https_proxy;
}

/// The single client factory: a fresh client carrying the policy for
/// `surface` and the host of `url`.
pub fn initClient(alloc: std.mem.Allocator, surface: Surface, url: []const u8) std.http.Client {
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    applyToClient(&client, surface, url);
    return client;
}

/// Validates a proxy URL the way resolution will, without installing it.
pub fn validateUrl(alloc: std.mem.Allocator, url: []const u8) ConfigError!void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    _ = try buildProxy(arena.allocator(), url);
}

const Target = struct { host: []const u8, port: u16 };

fn targetOf(url: []const u8, buffer: *[std.Io.net.HostName.max_len]u8) ?Target {
    const uri = std.Uri.parse(url) catch return null;
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return null;
    const host = uri.getHost(buffer) catch return null;
    return .{ .host = host.bytes, .port = uri.port orelse defaultPort(protocol) };
}

fn defaultPort(protocol: std.http.Client.Protocol) u16 {
    return switch (protocol) {
        .plain => 80,
        .tls => 443,
    };
}

fn buildProxy(arena: std.mem.Allocator, raw_url: []const u8) ConfigError!*std.http.Client.Proxy {
    // A URL without `://` is an authority with an implicit `http` scheme, so
    // `127.0.0.1:8080` and `user:pass@host:8080` work. An explicit unknown
    // scheme is rejected instead of being guessed at.
    const uri = blk: {
        if (std.mem.find(u8, raw_url, "://") != null) {
            break :blk std.Uri.parse(raw_url) catch return error.InvalidProxyUrl;
        }
        const with_scheme = try std.fmt.allocPrint(arena, "http://{s}", .{raw_url});
        break :blk std.Uri.parse(with_scheme) catch return error.InvalidProxyUrl;
    };
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedProxyScheme;
    const host = uri.getHostAlloc(arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProxyUrl,
    };

    const authorization: ?[]const u8 = if (uri.user != null or uri.password != null) blk: {
        const buffer = try arena.alloc(u8, std.http.Client.basic_authorization.valueLengthFromUri(uri));
        const written = std.http.Client.basic_authorization.value(uri, buffer);
        if (written.len != buffer.len) return error.InvalidProxyUrl;
        break :blk buffer;
    } else null;

    const proxy = try arena.create(std.http.Client.Proxy);
    proxy.* = .{
        .protocol = protocol,
        .host = host,
        .authorization = authorization,
        .port = uri.port orelse defaultPort(protocol),
        .supports_connect = true,
    };
    return proxy;
}

fn splitList(arena: std.mem.Allocator, raw: []const u8) ConfigError![]const []const u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, raw, ',');
    while (iterator.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t\r\n");
        if (trimmed.len == 0) continue;
        try entries.append(arena, trimmed);
    }
    return entries.toOwnedSlice(arena);
}

fn surfaceList(arena: std.mem.Allocator, names: []const []const u8) ConfigError![]const Surface {
    var surfaces: std.ArrayList(Surface) = .empty;
    for (names) |name| {
        const surface = std.meta.stringToEnum(Surface, name) orelse continue;
        for (surfaces.items) |existing| {
            if (existing == surface) break;
        } else {
            try surfaces.append(arena, surface);
        }
    }
    return surfaces.toOwnedSlice(arena);
}

fn surfaceSet(surfaces: []const Surface) SurfaceSet {
    var set = SurfaceSet.initEmpty();
    for (surfaces) |surface| set.insert(surface);
    return set;
}

fn parseRules(arena: std.mem.Allocator, entries: []const []const u8) ConfigError![]const Rule {
    var rules: std.ArrayList(Rule) = .empty;
    for (entries) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "*")) {
            try rules.append(arena, .all);
            continue;
        }
        if (std.mem.findScalar(u8, trimmed, '/')) |slash| {
            if (parseCidr(trimmed[0..slash], trimmed[slash + 1 ..])) |rule| try rules.append(arena, rule);
            continue;
        }
        if (splitHostPort(trimmed)) |host_port| {
            const host = try lowerDup(arena, stripLeadingDot(host_port.host));
            if (host.len == 0) continue;
            if (host_port.port) |port| {
                try rules.append(arena, .{ .host_port = .{ .host = host, .port = port } });
            } else {
                try rules.append(arena, .{ .host = host });
            }
            continue;
        }
        const host = std.mem.trim(u8, stripLeadingDot(trimmed), " \t\r\n");
        if (host.len == 0) continue;
        try rules.append(arena, .{ .host = try lowerDup(arena, host) });
    }
    return rules.toOwnedSlice(arena);
}

const HostPortSpec = struct { host: []const u8, port: ?u16 };

fn splitHostPort(text: []const u8) ?HostPortSpec {
    if (text.len != 0 and text[0] == '[') {
        const end = std.mem.findScalar(u8, text, ']') orelse return null;
        const host = text[1..end];
        const rest = text[end + 1 ..];
        if (rest.len == 0) return .{ .host = host, .port = null };
        if (rest[0] != ':') return null;
        const port = std.fmt.parseInt(u16, rest[1..], 10) catch return null;
        return .{ .host = host, .port = port };
    }
    const first = std.mem.findScalar(u8, text, ':') orelse return .{ .host = text, .port = null };
    if (std.mem.findScalarPos(u8, text, first + 1, ':')) |_| return .{ .host = text, .port = null };
    const port = std.fmt.parseInt(u16, text[first + 1 ..], 10) catch
        return .{ .host = text, .port = null };
    return .{ .host = text[0..first], .port = port };
}

fn parseCidr(address_text: []const u8, bits_text: []const u8) ?Rule {
    const address = std.Io.net.IpAddress.parse(address_text, 0) catch return null;
    const bits = std.fmt.parseInt(u8, bits_text, 10) catch return null;
    return switch (address) {
        .ip4 => |v4| if (bits <= 32) Rule{ .cidr4 = .{ .addr = v4.bytes, .bits = @intCast(bits) } } else null,
        .ip6 => |v6| if (bits <= 128) Rule{ .cidr6 = .{ .addr = v6.bytes, .bits = @intCast(bits) } } else null,
    };
}

fn lowerDup(arena: std.mem.Allocator, text: []const u8) ConfigError![]const u8 {
    const buffer = try arena.alloc(u8, text.len);
    return std.ascii.lowerString(buffer, text);
}

/// Matches `host`/`port` against parsed bypass rules. Exposed for tests.
fn ruleMatches(rules: []const Rule, raw_host: []const u8, port: u16) bool {
    const host = stripBrackets(raw_host);
    for (rules) |rule| switch (rule) {
        .all => return true,
        .host => |pattern| if (hostMatches(host, pattern)) return true,
        .host_port => |host_port| if (host_port.port == port and hostMatches(host, host_port.host)) return true,
        .cidr4 => |cidr| if (ipv4InCidr(host, cidr)) return true,
        .cidr6 => |cidr| if (ipv6InCidr(host, cidr)) return true,
    };
    return false;
}

fn stripLeadingDot(text: []const u8) []const u8 {
    return if (text.len != 0 and text[0] == '.') text[1..] else text;
}

fn stripBrackets(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') return host[1 .. host.len - 1];
    return host;
}

fn hostMatches(host: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(host, pattern)) return true;
    if (host.len <= pattern.len) return false;
    if (!std.ascii.endsWithIgnoreCase(host, pattern)) return false;
    return host[host.len - pattern.len - 1] == '.';
}

fn ipv4InCidr(host: []const u8, cidr: Rule.Cidr4) bool {
    const address = std.Io.net.IpAddress.parse(host, 0) catch return false;
    const bytes = switch (address) {
        .ip4 => |v4| v4.bytes,
        else => return false,
    };
    return prefixMatches(4, &bytes, &cidr.addr, cidr.bits);
}

fn ipv6InCidr(host: []const u8, cidr: Rule.Cidr6) bool {
    const address = std.Io.net.IpAddress.parse(host, 0) catch return false;
    const bytes = switch (address) {
        .ip6 => |v6| v6.bytes,
        else => return false,
    };
    return prefixMatches(16, &bytes, &cidr.addr, @intCast(cidr.bits));
}

fn prefixMatches(comptime len: usize, address: *const [len]u8, network: *const [len]u8, bits: u8) bool {
    const full_bytes = bits / 8;
    const remainder: u4 = @intCast(bits % 8);
    if (!std.mem.eql(u8, address[0..full_bytes], network[0..full_bytes])) return false;
    if (remainder == 0) return true;
    const shift: u3 = @intCast(8 - remainder);
    return (address[full_bytes] >> shift) == (network[full_bytes] >> shift);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testEnv(entries: []const struct { []const u8, []const u8 }) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(testing.allocator);
    errdefer map.deinit();
    for (entries) |entry| try map.put(entry[0], entry[1]);
    return map;
}

fn rulesOf(arena: std.mem.Allocator, entries: []const []const u8) ![]const Rule {
    return parseRules(arena, entries);
}

fn matches(entries: []const []const u8, host: []const u8, port: u16) !bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rules = try rulesOf(arena.allocator(), entries);
    return ruleMatches(rules, host, port);
}

test "no_proxy matches hosts, suffixes, ports, wildcards, and CIDRs" {
    const cases = [_]struct { []const []const u8, []const u8, u16, bool }{
        .{ &.{"x"}, "x", 443, true },
        .{ &.{"x"}, "x", 80, true },
        .{ &.{"x"}, "y", 80, false },
        .{ &.{".corp"}, "api.corp", 443, true },
        .{ &.{".corp"}, "corp", 443, true },
        .{ &.{".corp"}, "notcorp", 443, false },
        .{ &.{"corp"}, "api.corp", 443, true },
        .{ &.{"Corp"}, "API.CORP", 443, true },
        .{ &.{"api.corp"}, "corp", 443, false },
        .{ &.{"*"}, "anything.example", 1, true },
        .{ &.{"api.corp:8443"}, "api.corp", 8443, true },
        .{ &.{"api.corp:8443"}, "api.corp", 443, false },
        .{ &.{"10.0.0.0/8"}, "10.1.2.3", 443, true },
        .{ &.{"10.0.0.0/8"}, "11.1.2.3", 443, false },
        .{ &.{"10.0.0.0/8"}, "api.corp", 443, false },
        .{ &.{"192.168.1.0/24"}, "192.168.1.255", 443, true },
        .{ &.{"192.168.1.0/24"}, "192.168.2.1", 443, false },
        .{ &.{"2001:db8::/32"}, "[2001:db8::1]", 443, true },
        .{ &.{"2001:db8::/32"}, "[2001:db9::1]", 443, false },
        .{ &.{"::1"}, "::1", 443, true },
        .{ &.{"localhost"}, "localhost", 80, true },
        .{ &.{}, "localhost", 80, false },
        .{ &.{"bad/entry"}, "bad", 80, false },
    };
    for (cases) |case| {
        try testing.expectEqual(case[3], try matches(case[0], case[1], case[2]));
    }
}

test "buildProxy parses scheme, port, and credentials" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const plain = try buildProxy(alloc, "http://user:pass@127.0.0.1:8080");
    try testing.expectEqual(std.http.Client.Protocol.plain, plain.protocol);
    try testing.expectEqualStrings("127.0.0.1", plain.host.bytes);
    try testing.expectEqual(@as(u16, 8080), plain.port);
    try testing.expect(plain.authorization != null);
    // The basic value is `Basic <base64(user:pass)>`.
    try testing.expect(std.mem.startsWith(u8, plain.authorization.?, "Basic "));

    const secure = try buildProxy(alloc, "https://proxy.example.com");
    try testing.expectEqual(std.http.Client.Protocol.tls, secure.protocol);
    try testing.expectEqual(@as(u16, 443), secure.port);
    try testing.expect(secure.authorization == null);

    const schemeless = try buildProxy(alloc, "proxy.example.com:3128");
    try testing.expectEqual(std.http.Client.Protocol.plain, schemeless.protocol);
    try testing.expectEqual(@as(u16, 3128), schemeless.port);

    try testing.expectError(error.UnsupportedProxyScheme, buildProxy(alloc, "socks5://proxy.example.com:1080"));
}

test "maskedExplicitUrl hides credentials" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var map = try testEnv(&.{.{ "FX_PROXY", "http://user:secret@127.0.0.1:8080" }});
    defer map.deinit();

    try initFromEnvMap(&map, .{});
    defer reset();

    const masked = (try maskedExplicitUrl(arena.allocator())).?;
    try testing.expect(std.mem.find(u8, masked, "secret") == null);
    try testing.expectEqualStrings("http://[redacted]@127.0.0.1:8080", masked);
}

test "explicit FX_PROXY applies to model and leaves other surfaces to the environment" {
    var map = try testEnv(&.{
        .{ "FX_PROXY", "http://127.0.0.1:8080" },
        .{ "HTTPS_PROXY", "http://env-proxy.example:3128" },
    });
    defer map.deinit();

    try initFromEnvMap(&map, .{});
    defer reset();

    var model = initClient(testing.allocator, .model, "https://ai-gateway.vercel.sh/v4/ai/language-model");
    defer model.deinit();
    try testing.expect(model.https_proxy != null);
    try testing.expectEqualStrings("127.0.0.1", model.https_proxy.?.host.bytes);
    try testing.expectEqual(@as(u16, 8080), model.https_proxy.?.port);

    var mcp = initClient(testing.allocator, .mcp, "https://mcp.example.com/sse");
    defer mcp.deinit();
    try testing.expect(mcp.https_proxy != null);
    try testing.expectEqualStrings("env-proxy.example", mcp.https_proxy.?.host.bytes);
}

test "default no_proxy keeps loopback providers direct" {
    var map = try testEnv(&.{.{ "FX_PROXY", "http://127.0.0.1:8080" }});
    defer map.deinit();

    try initFromEnvMap(&map, .{});
    defer reset();

    var local = initClient(testing.allocator, .model, "http://127.0.0.1:11434/v1/chat/completions");
    defer local.deinit();
    try testing.expect(local.http_proxy == null);
    try testing.expect(local.https_proxy == null);

    var named = initClient(testing.allocator, .model, "http://localhost:11434/v1/models");
    defer named.deinit();
    try testing.expect(named.http_proxy == null);
}

test "an explicit empty bypass list routes loopback through the proxy" {
    var map = try testEnv(&.{
        .{ "FX_PROXY", "http://127.0.0.1:8080" },
        .{ "FX_NO_PROXY", "" },
    });
    defer map.deinit();

    try initFromEnvMap(&map, .{});
    defer reset();

    var local = initClient(testing.allocator, .model, "http://127.0.0.1:11434/v1/models");
    defer local.deinit();
    try testing.expect(local.http_proxy != null);
    try testing.expectEqualStrings("127.0.0.1", local.http_proxy.?.host.bytes);
}

test "FX_PROXY_APPLY_TO scopes the explicit proxy" {
    var map = try testEnv(&.{
        .{ "FX_PROXY", "http://127.0.0.1:8080" },
        .{ "FX_PROXY_APPLY_TO", "mcp,upgrade" },
    });
    defer map.deinit();

    try initFromEnvMap(&map, .{});
    defer reset();

    var model = initClient(testing.allocator, .model, "https://ai-gateway.vercel.sh/");
    defer model.deinit();
    try testing.expect(model.https_proxy == null);

    var upgrade = initClient(testing.allocator, .upgrade, "https://api.github.com/repos/vercel-labs/fx/releases");
    defer upgrade.deinit();
    try testing.expect(upgrade.https_proxy != null);
}

test "standard environment alone is honored on every surface" {
    var map = try testEnv(&.{.{ "HTTPS_PROXY", "http://env-proxy.example:3128" }});
    defer map.deinit();

    try initFromEnvMap(&map, .{});
    defer reset();

    var mcp = initClient(testing.allocator, .mcp, "https://mcp.example.com/sse");
    defer mcp.deinit();
    try testing.expect(mcp.https_proxy != null);

    var upgrade = initClient(testing.allocator, .upgrade, "https://api.github.com/repos/vercel-labs/fx/releases");
    defer upgrade.deinit();
    try testing.expect(upgrade.https_proxy != null);
}

test "source priority: flags override FX_PROXY, which overrides stored settings" {
    var map = try testEnv(&.{.{ "FX_PROXY", "http://127.0.0.1:8080" }});
    defer map.deinit();

    const stored: Config = .{ .url = "http://127.0.0.1:9999" };
    try initFromEnvMap(&map, .{
        .override = .{ .url = "http://127.0.0.1:1111" },
        .stored = stored,
    });
    defer reset();

    var client = initClient(testing.allocator, .model, "https://example.com/");
    defer client.deinit();
    try testing.expectEqual(@as(u16, 1111), client.https_proxy.?.port);
}

test "stored settings apply when neither flags nor FX_PROXY are present" {
    var map = try testEnv(&.{});
    defer map.deinit();

    const stored: Config = .{ .url = "http://127.0.0.1:9999" };
    try initFromEnvMap(&map, .{ .stored = stored });
    defer reset();

    var client = initClient(testing.allocator, .model, "https://example.com/");
    defer client.deinit();
    try testing.expectEqual(@as(u16, 9999), client.https_proxy.?.port);

    // A surface outside `apply_to` still has no explicit setting.
    var mcp = initClient(testing.allocator, .mcp, "https://mcp.example.com/sse");
    defer mcp.deinit();
    try testing.expect(mcp.https_proxy == null);
}

test "an explicit url is copied so its parsed host outlives the caller buffer" {
    var map = try testEnv(&.{});
    defer map.deinit();

    // A caller-owned buffer that dies right after resolution, like the parsed
    // settings JSON that the config runtime frees when loading finishes.
    const caller_buffer = try testing.allocator.dupe(u8, "http://127.0.0.1:8080");
    try initFromEnvMap(&map, .{ .stored = .{ .url = caller_buffer, .no_proxy = &.{} } });
    defer reset();
    testing.allocator.free(caller_buffer);

    var client = initClient(testing.allocator, .model, "https://example.com/");
    defer client.deinit();
    try testing.expectEqualStrings("127.0.0.1", client.https_proxy.?.host.bytes);
    try testing.expectEqual(@as(u16, 8080), client.https_proxy.?.port);
}

test "StoredConfig owns and frees its lists" {
    const alloc = testing.allocator;
    const entries = try alloc.alloc([]const u8, 2);
    entries[0] = try alloc.dupe(u8, "localhost");
    entries[1] = try alloc.dupe(u8, ".corp");
    const surfaces = try alloc.alloc(Surface, 1);
    surfaces[0] = .mcp;
    var stored: StoredConfig = .{
        .url = try alloc.dupe(u8, "http://127.0.0.1:8080"),
        .no_proxy = entries,
        .apply_to = surfaces,
    };
    const view = stored.config();
    try testing.expectEqualStrings("http://127.0.0.1:8080", view.url);
    try testing.expectEqualStrings(".corp", view.no_proxy[1]);
    try testing.expectEqual(Surface.mcp, view.apply_to[0]);
    stored.deinit(alloc);
}

test "an unrepresentable standard proxy variable is skipped instead of failing startup" {
    var map = try testEnv(&.{.{ "ALL_PROXY", "socks5://127.0.0.1:1080" }});
    defer map.deinit();

    try initFromEnvMap(&map, .{});
    defer reset();

    var client = initClient(testing.allocator, .model, "https://ai-gateway.vercel.sh/");
    defer client.deinit();
    try testing.expect(client.http_proxy == null);
    try testing.expect(client.https_proxy == null);
    try testing.expect(!isEnabled(.model));
}

test "NO_PROXY from the environment bypasses the environment proxy" {
    var map = try testEnv(&.{
        .{ "HTTPS_PROXY", "http://env-proxy.example:3128" },
        .{ "NO_PROXY", ".internal,10.0.0.0/8" },
    });
    defer map.deinit();

    try initFromEnvMap(&map, .{});
    defer reset();

    var bypassed = initClient(testing.allocator, .mcp, "https://mcp.internal/sse");
    defer bypassed.deinit();
    try testing.expect(bypassed.https_proxy == null);

    var proxied = initClient(testing.allocator, .mcp, "https://mcp.example.com/sse");
    defer proxied.deinit();
    try testing.expect(proxied.https_proxy != null);
}

test "an invalid explicit proxy is an error rather than a silent direct connection" {
    var map = try testEnv(&.{.{ "FX_PROXY", "socks5://127.0.0.1:1080" }});
    defer map.deinit();

    try testing.expectError(error.UnsupportedProxyScheme, initFromEnvMap(&map, .{}));
    defer reset();

    // Nothing was installed, so the process does not pretend to be proxied.
    try testing.expect(!isEnabled(.model));
}

test "absent configuration leaves every client direct" {
    var map = try testEnv(&.{});
    defer map.deinit();

    try initFromEnvMap(&map, .{});
    defer reset();

    var client = initClient(testing.allocator, .model, "https://ai-gateway.vercel.sh/");
    defer client.deinit();
    try testing.expect(client.http_proxy == null);
    try testing.expect(client.https_proxy == null);
    try testing.expect(!isEnabled(.model));
}

//! Input state for the transcript-driven provider setup wizard.
//!
//! The wizard never owns the composer: the runtime reads each Enter value out
//! of the editor, hands it to `commit`, and writes the next prompt as a
//! replaceable notice. This reducer collects the answers and assembles the
//! same `provider_management.Draft` the CLI uses, so the TUI and the command
//! line share one validated path.
//!
//! Prompts ask for one value at a time. Empty answers accept the preset or
//! leave the optional field unset; `commit` rejects anything invalid and keeps
//! the wizard on the same screen.

const std = @import("std");
const configured_provider = @import("configured_provider.zig");
const provider_management = @import("provider_management.zig");
const types = @import("../shared/types.zig");

pub const Mode = enum { add, edit };

pub const AuthChoice = enum { none, env, stored };
pub const Tri = enum { default, yes, no };

pub const Screen = enum {
    name,
    base_url,
    auth,
    env,
    secret,
    model,
    context_window,
    max_output_tokens,
    tool_use,
    vision,
    reasoning_efforts,
    confirm,
};

pub const max_secret_bytes = provider_management.max_secret_bytes;
pub const max_base_url_bytes = 2048;
pub const max_model_bytes = configured_provider.max_model_bytes;
pub const max_env_bytes = 128;

/// One answered field. Copies are intentional: the editor is cleared after
/// every step, and the collected answers outlive it.
fn Text(comptime capacity: usize) type {
    return struct {
        len: usize = 0,
        bytes: [capacity]u8 = undefined,

        const Self = @This();

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        fn set(self: *Self, value: []const u8) void {
            const n = @min(value.len, capacity);
            @memcpy(self.bytes[0..n], value[0..n]);
            self.len = n;
        }

        fn setInt(self: *Self, value: u32) void {
            const written = std.fmt.bufPrint(&self.bytes, "{d}", .{value}) catch return;
            self.len = written.len;
        }

        fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}

pub const Invalid = struct {
    message: []const u8,
    screen: Screen,
};

pub const Step = union(enum) {
    prompt: Screen,
    invalid: Invalid,
    saved: provider_management.Draft,
    cancelled,
};

pub const State = struct {
    active: bool = false,
    mode: Mode = .add,
    screen: Screen = .name,
    name: Text(configured_provider.max_id_bytes) = .{},
    original_name: Text(configured_provider.max_id_bytes) = .{},
    base_url: Text(max_base_url_bytes) = .{},
    env: Text(max_env_bytes) = .{},
    secret: Text(max_secret_bytes) = .{},
    model: Text(max_model_bytes) = .{},
    context_window: Text(16) = .{},
    max_output_tokens: Text(16) = .{},
    reasoning_efforts: Text(256) = .{},
    auth: AuthChoice = .env,
    tool_use: Tri = .default,
    vision: Tri = .default,
    /// Editing: a key is already stored for this connection's binding.
    has_stored_secret: bool = false,

    pub fn nameText(self: *const State) []const u8 {
        return self.name.slice();
    }

    pub fn secretText(self: *const State) []const u8 {
        return self.secret.slice();
    }
};

pub fn beginAdd(state: *State) Step {
    state.* = .{};
    state.active = true;
    state.mode = .add;
    state.screen = .name;
    return .{ .prompt = .name };
}

pub fn beginEdit(
    state: *State,
    definition: *const configured_provider.Definition,
    stored_secret_present: bool,
) Step {
    state.* = .{};
    state.active = true;
    state.mode = .edit;
    state.screen = .name;
    state.name.set(definition.id);
    state.original_name.set(definition.id);
    state.base_url.set(definition.base_url);
    switch (definition.auth) {
        .none => state.auth = .none,
        .stored => state.auth = .stored,
        .bearer => |env| {
            state.auth = .env;
            state.env.set(env);
        },
    }
    if (definition.model_metadata.len > 0) {
        const metadata = definition.model_metadata[0];
        state.model.set(metadata.id);
        if (metadata.context_window) |value| state.context_window.setInt(value);
        if (metadata.max_output_tokens) |value| state.max_output_tokens.setInt(value);
        state.tool_use = triOf(metadata.supports_tool_use);
        state.vision = triOf(metadata.supports_vision);
        state.reasoning_efforts.len = joinEfforts(&state.reasoning_efforts.bytes, metadata.reasoning_efforts).len;
    }
    state.has_stored_secret = stored_secret_present and state.auth == .stored;
    return .{ .prompt = .name };
}

pub fn cancel(state: *State) void {
    state.active = false;
}

/// Applies one answered value. `value` is the raw editor content; leading and
/// trailing whitespace is ignored for every field.
pub fn commit(state: *State, value: []const u8) Step {
    if (!state.active) return .{ .prompt = state.screen };
    const trimmed = std.mem.trim(u8, value, " \t");
    switch (state.screen) {
        .name => {
            if (trimmed.len == 0) {
                if (state.mode == .add) return invalid(state, "Provider name is required");
            } else {
                if (state.mode == .edit and !std.mem.eql(u8, trimmed, state.original_name.slice())) {
                    return invalid(state, "Provider names cannot be changed; cancel and add a new connection");
                }
                configured_provider.validate_id(trimmed) catch |err| return invalid(state, idMessage(err));
                state.name.set(trimmed);
            }
            state.screen = .base_url;
            return .{ .prompt = .base_url };
        },
        .base_url => {
            if (!(state.mode == .edit and trimmed.len == 0)) state.base_url.set(trimmed);
            state.screen = .auth;
            return .{ .prompt = .auth };
        },
        .auth => {
            if (trimmed.len != 0) {
                state.auth = parseAuth(trimmed) orelse
                    return invalid(state, "Answer with none, env, or stored");
            }
            state.screen = switch (state.auth) {
                .none => .model,
                .env => .env,
                .stored => .secret,
            };
            return .{ .prompt = state.screen };
        },
        .env => {
            if (!(state.mode == .edit and trimmed.len == 0)) state.env.set(trimmed);
            state.screen = .model;
            return .{ .prompt = .model };
        },
        .secret => {
            if (trimmed.len == 0) {
                const keeping = state.mode == .edit and state.has_stored_secret;
                if (!keeping) return invalid(state, "API key is required");
            } else if (!provider_management.validSecret(trimmed)) {
                return invalid(state, "API key must be printable text without spaces");
            }
            state.secret.set(trimmed);
            state.screen = .model;
            return .{ .prompt = .model };
        },
        .model => {
            if (!(state.mode == .edit and trimmed.len == 0)) state.model.set(trimmed);
            state.screen = .context_window;
            return .{ .prompt = .context_window };
        },
        .context_window => {
            if (trimmed.len == 0) {
                if (state.mode == .add) state.context_window.clear();
            } else if (std.ascii.eqlIgnoreCase(trimmed, "none")) {
                state.context_window.clear();
            } else {
                const parsed = parsePositive(trimmed) orelse
                    return invalid(state, "Context window must be a positive integer");
                state.context_window.setInt(parsed);
            }
            state.screen = .max_output_tokens;
            return .{ .prompt = .max_output_tokens };
        },
        .max_output_tokens => {
            if (trimmed.len == 0) {
                if (state.mode == .add) state.max_output_tokens.clear();
            } else if (std.ascii.eqlIgnoreCase(trimmed, "none")) {
                state.max_output_tokens.clear();
            } else {
                const parsed = parsePositive(trimmed) orelse
                    return invalid(state, "Max output tokens must be a positive integer");
                state.max_output_tokens.setInt(parsed);
            }
            state.screen = .tool_use;
            return .{ .prompt = .tool_use };
        },
        .tool_use => {
            if (trimmed.len != 0) {
                state.tool_use = parseTri(trimmed) orelse
                    return invalid(state, "Answer with default, yes, or no");
            }
            state.screen = .vision;
            return .{ .prompt = .vision };
        },
        .vision => {
            if (trimmed.len != 0) {
                state.vision = parseTri(trimmed) orelse
                    return invalid(state, "Answer with default, yes, or no");
            }
            state.screen = .reasoning_efforts;
            return .{ .prompt = .reasoning_efforts };
        },
        .reasoning_efforts => {
            if (trimmed.len == 0) {
                if (state.mode == .add) state.reasoning_efforts.clear();
            } else if (std.ascii.eqlIgnoreCase(trimmed, "none")) {
                state.reasoning_efforts.clear();
            } else {
                if (!provider_management.effortsValid(trimmed)) {
                    return invalid(state, "Reasoning efforts must be comma-separated names such as low, high");
                }
                state.reasoning_efforts.set(trimmed);
            }
            state.screen = .confirm;
            return .{ .prompt = .confirm };
        },
        .confirm => {
            if (trimmed.len == 0 or isAffirmative(trimmed)) {
                return .{ .saved = assembleDraft(state) };
            }
            if (isNegative(trimmed)) {
                state.active = false;
                return .cancelled;
            }
            return invalid(state, "Answer yes to save or no to cancel");
        },
    }
}

/// Returns the wizard to an earlier screen with a message, keeping every
/// answer already collected.
pub fn revisit(state: *State, screen: Screen, message: []const u8) Step {
    state.screen = screen;
    return .{ .invalid = .{ .message = message, .screen = screen } };
}

fn assembleDraft(state: *const State) provider_management.Draft {
    const context_window = parseOptionalPositive(state.context_window.slice());
    const max_output_tokens = parseOptionalPositive(state.max_output_tokens.slice());
    return .{
        .name = state.name.slice(),
        .base_url = optional(state.base_url.slice()),
        .api_key_env = optional(state.env.slice()),
        .save_api_key = state.auth == .stored,
        .no_auth = state.auth == .none,
        .model = optional(state.model.slice()),
        .context_window = context_window,
        .max_output_tokens = max_output_tokens,
        .tool_use = state.tool_use == .yes,
        .no_tool_use = state.tool_use == .no,
        .vision = state.vision == .yes,
        .no_vision = state.vision == .no,
        .reasoning_efforts_raw = optional(state.reasoning_efforts.slice()),
        .select = true,
    };
}

fn invalid(state: *State, message: []const u8) Step {
    return .{ .invalid = .{ .message = message, .screen = state.screen } };
}

fn optional(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
}

fn parseOptionalPositive(value: []const u8) ?u32 {
    if (value.len == 0) return null;
    return parsePositive(value);
}

fn parsePositive(value: []const u8) ?u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return null;
    if (parsed == 0) return null;
    return parsed;
}

fn parseAuth(value: []const u8) ?AuthChoice {
    if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(value, "env")) return .env;
    if (std.ascii.eqlIgnoreCase(value, "stored")) return .stored;
    return null;
}

fn parseTri(value: []const u8) ?Tri {
    if (std.ascii.eqlIgnoreCase(value, "default")) return .default;
    if (std.ascii.eqlIgnoreCase(value, "yes") or std.ascii.eqlIgnoreCase(value, "y") or
        std.ascii.eqlIgnoreCase(value, "true"))
    {
        return .yes;
    }
    if (std.ascii.eqlIgnoreCase(value, "no") or std.ascii.eqlIgnoreCase(value, "n") or
        std.ascii.eqlIgnoreCase(value, "false"))
    {
        return .no;
    }
    return null;
}

fn isAffirmative(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "yes") or std.ascii.eqlIgnoreCase(value, "y") or
        std.ascii.eqlIgnoreCase(value, "true");
}

fn isNegative(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "no") or std.ascii.eqlIgnoreCase(value, "n") or
        std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "cancel");
}

fn triOf(value: ?bool) Tri {
    return if (value) |supported| if (supported) .yes else .no else .default;
}

fn joinEfforts(out: []u8, efforts: []const types.ReasoningEffort) []const u8 {
    var end: usize = 0;
    for (efforts, 0..) |*effort, index| {
        const label = effort.label();
        const separator = if (index == 0) "" else ", ";
        const needed = separator.len + label.len;
        if (end + needed > out.len) break;
        @memcpy(out[end..][0..separator.len], separator);
        end += separator.len;
        @memcpy(out[end..][0..label.len], label);
        end += label.len;
    }
    return out[0..end];
}

fn idMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ReservedProviderId => "That provider name is reserved",
        error.InvalidProviderId => "Provider names may only contain letters, digits, dashes, and underscores",
        error.LimitExceeded => "Provider name is too long",
        else => "Provider name is invalid",
    };
}

test "provider setup wizard walks every stage and assembles the draft" {
    var state: State = .{};
    try std.testing.expectEqual(Screen.name, beginAdd(&state).prompt);
    try std.testing.expectEqual(Screen.name, commit(&state, "  ").invalid.screen);
    try std.testing.expectEqual(Screen.base_url, commit(&state, "deepseek").prompt);
    try std.testing.expectEqual(Screen.auth, commit(&state, "").prompt);
    try std.testing.expectEqual(Screen.env, commit(&state, "env").prompt);
    try std.testing.expectEqual(Screen.model, commit(&state, "DEEPSEEK_API_KEY").prompt);
    try std.testing.expectEqual(Screen.context_window, commit(&state, "deepseek-flash").prompt);
    try std.testing.expectEqual(Screen.max_output_tokens, commit(&state, "32768").prompt);
    try std.testing.expectEqual(Screen.tool_use, commit(&state, "8192").prompt);
    try std.testing.expectEqual(Screen.vision, commit(&state, "").prompt);
    try std.testing.expectEqual(Screen.reasoning_efforts, commit(&state, "yes").prompt);
    try std.testing.expectEqual(Screen.confirm, commit(&state, "high, max").prompt);

    const draft = commit(&state, "yes").saved;
    try std.testing.expectEqualStrings("deepseek", draft.name);
    try std.testing.expect(draft.base_url == null);
    try std.testing.expectEqualStrings("DEEPSEEK_API_KEY", draft.api_key_env.?);
    try std.testing.expect(!draft.no_auth);
    try std.testing.expect(!draft.save_api_key);
    try std.testing.expectEqualStrings("deepseek-flash", draft.model.?);
    try std.testing.expectEqual(@as(?u32, 32768), draft.context_window);
    try std.testing.expectEqual(@as(?u32, 8192), draft.max_output_tokens);
    try std.testing.expect(!draft.tool_use);
    try std.testing.expect(draft.vision);
    try std.testing.expectEqualStrings("high, max", draft.reasoning_efforts_raw.?);
}

test "provider setup wizard routes stored auth through the secret screen" {
    var state: State = .{};
    _ = beginAdd(&state);
    _ = commit(&state, "custom");
    try std.testing.expectEqual(Screen.auth, commit(&state, "https://example.com/v1").prompt);
    try std.testing.expectEqual(Screen.secret, commit(&state, "stored").prompt);
    try std.testing.expectEqual(Screen.secret, commit(&state, "").invalid.screen);
    try std.testing.expectEqual(Screen.model, commit(&state, "sk-test-123").prompt);

    try std.testing.expectEqualStrings("sk-test-123", state.secretText());
    _ = commit(&state, "model-x");
    _ = commit(&state, "");
    _ = commit(&state, "");
    _ = commit(&state, "");
    _ = commit(&state, "");
    _ = commit(&state, "");
    const draft = commit(&state, "yes").saved;
    try std.testing.expect(draft.save_api_key);
    try std.testing.expect(!draft.no_auth);
    try std.testing.expect(draft.api_key_env == null);
}

test "provider setup wizard validates numeric and effort answers in place" {
    var state: State = .{};
    _ = beginAdd(&state);
    _ = commit(&state, "custom");
    _ = commit(&state, "https://example.com/v1");
    _ = commit(&state, "none");
    _ = commit(&state, "model-x");
    try std.testing.expectEqual(Screen.context_window, commit(&state, "zero").invalid.screen);
    try std.testing.expectEqual(Screen.context_window, commit(&state, "0").invalid.screen);
    try std.testing.expectEqual(Screen.max_output_tokens, commit(&state, "1024").prompt);
    try std.testing.expectEqual(Screen.tool_use, commit(&state, "").prompt);
    try std.testing.expectEqual(Screen.vision, commit(&state, "").prompt);
    try std.testing.expectEqual(Screen.reasoning_efforts, commit(&state, "").prompt);
    try std.testing.expectEqual(Screen.reasoning_efforts, commit(&state, "low,low").invalid.screen);
    try std.testing.expectEqual(Screen.reasoning_efforts, commit(&state, "default").invalid.screen);
    try std.testing.expectEqual(Screen.confirm, commit(&state, "none").prompt);
}

test "provider setup wizard edit prefills every field and rejects renames" {
    const alloc = std.testing.allocator;
    var registry = try configured_provider.Registry.parse_json(
        alloc,
        "{\"deepseek\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://api.deepseek.com\",\"auth\":{\"type\":\"stored\"},\"model_metadata\":{\"deepseek-flash\":{\"context_window\":64000,\"max_output_tokens\":8192,\"supports_tool_use\":true,\"supports_vision\":false,\"reasoning_efforts\":[\"low\",\"high\"]}}}}",
    );
    defer registry.deinit(alloc);
    const definition = registry.get("deepseek").?;

    var state: State = .{};
    try std.testing.expectEqual(Screen.name, beginEdit(&state, definition, true).prompt);
    try std.testing.expectEqual(Mode.edit, state.mode);
    try std.testing.expect(std.mem.eql(u8, "deepseek", state.nameText()));
    try std.testing.expectEqualStrings("https://api.deepseek.com", state.base_url.slice());
    try std.testing.expectEqual(AuthChoice.stored, state.auth);
    try std.testing.expectEqualStrings("deepseek-flash", state.model.slice());
    try std.testing.expectEqualStrings("64000", state.context_window.slice());
    try std.testing.expectEqualStrings("8192", state.max_output_tokens.slice());
    try std.testing.expectEqual(Tri.yes, state.tool_use);
    try std.testing.expectEqual(Tri.no, state.vision);
    try std.testing.expectEqualStrings("low, high", state.reasoning_efforts.slice());
    try std.testing.expect(state.has_stored_secret);

    try std.testing.expectEqualStrings(
        "Provider names cannot be changed; cancel and add a new connection",
        commit(&state, "other").invalid.message,
    );
    // Every empty answer keeps the prefilled value in edit mode.
    try std.testing.expectEqual(Screen.base_url, commit(&state, "deepseek").prompt);
    try std.testing.expectEqual(Screen.auth, commit(&state, "").prompt);
    try std.testing.expectEqualStrings("https://api.deepseek.com", state.base_url.slice());
    try std.testing.expectEqual(Screen.secret, commit(&state, "").prompt);
    try std.testing.expectEqual(Screen.model, commit(&state, "").prompt);
    try std.testing.expectEqual(Screen.context_window, commit(&state, "").prompt);
    try std.testing.expectEqualStrings("deepseek-flash", state.model.slice());
    try std.testing.expectEqual(Screen.max_output_tokens, commit(&state, "").prompt);
    try std.testing.expectEqualStrings("64000", state.context_window.slice());
    try std.testing.expectEqual(Screen.tool_use, commit(&state, "").prompt);
    try std.testing.expectEqual(Screen.vision, commit(&state, "").prompt);
    try std.testing.expectEqual(Screen.reasoning_efforts, commit(&state, "").prompt);
    try std.testing.expectEqual(Screen.confirm, commit(&state, "").prompt);
    try std.testing.expectEqualStrings("low, high", state.reasoning_efforts.slice());

    const draft = commit(&state, "yes").saved;
    try std.testing.expect(draft.save_api_key);
    try std.testing.expectEqual(@as(?u32, 64000), draft.context_window);
    try std.testing.expect(draft.tool_use);
    try std.testing.expectEqualStrings("low, high", draft.reasoning_efforts_raw.?);
}

test "provider setup wizard edit clears optional values with none" {
    const alloc = std.testing.allocator;
    var registry = try configured_provider.Registry.parse_json(
        alloc,
        "{\"deepseek\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://api.deepseek.com\",\"auth\":{\"type\":\"none\"},\"model_metadata\":{\"deepseek-flash\":{\"context_window\":64000,\"max_output_tokens\":8192,\"reasoning_efforts\":[\"low\"]}}}}",
    );
    defer registry.deinit(alloc);
    var state: State = .{};
    _ = beginEdit(&state, registry.get("deepseek").?, false);
    _ = commit(&state, "");
    _ = commit(&state, "");
    _ = commit(&state, "none");
    _ = commit(&state, "");
    try std.testing.expectEqual(Screen.context_window, state.screen);
    _ = commit(&state, "none");
    _ = commit(&state, "none");
    _ = commit(&state, "");
    _ = commit(&state, "");
    _ = commit(&state, "none");
    const draft = commit(&state, "yes").saved;
    try std.testing.expect(draft.context_window == null);
    try std.testing.expect(draft.max_output_tokens == null);
    try std.testing.expect(draft.reasoning_efforts_raw == null);
    try std.testing.expectEqualStrings("deepseek-flash", draft.model.?);
}

test "provider setup wizard confirm can cancel and revisit keeps answers" {
    var state: State = .{};
    _ = beginAdd(&state);
    _ = commit(&state, "custom");
    _ = commit(&state, "https://example.com/v1");
    _ = commit(&state, "none");
    _ = commit(&state, "model-x");
    _ = commit(&state, "");
    _ = commit(&state, "");
    _ = commit(&state, "");
    _ = commit(&state, "");
    _ = commit(&state, "");
    const rejected = commit(&state, "maybe");
    try std.testing.expectEqual(Screen.confirm, rejected.invalid.screen);
    try std.testing.expectEqualStrings("custom", state.nameText());

    const step = revisit(&state, .base_url, "Base URL was rejected");
    try std.testing.expectEqual(Screen.base_url, step.invalid.screen);
    try std.testing.expectEqualStrings("model-x", state.model.slice());
    try std.testing.expectEqual(Screen.auth, commit(&state, "https://example.com/v1").prompt);

    _ = commit(&state, "none");
    _ = commit(&state, "model-x");
    _ = commit(&state, "");
    _ = commit(&state, "");
    _ = commit(&state, "");
    _ = commit(&state, "");
    _ = commit(&state, "");
    try std.testing.expect(switch (commit(&state, "no")) {
        .cancelled => true,
        else => false,
    });
    try std.testing.expect(!state.active);
}

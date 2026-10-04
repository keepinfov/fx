//! Drives the provider setup wizard: it reads answers out of the composer,
//! funnels them through `provider_admin_state`, writes prompts as one
//! replaceable transcript notice, and commits the final `Draft` through the
//! same `provider_management` path the CLI uses.
//!
//! The wizard is transcript-driven on purpose: the composer keeps every
//! editing, paste, and history affordance for free, and the secret step only
//! needs the render layer to mask the composer.

const std = @import("std");
const provider_admin_state = @import("../config/provider_admin_state.zig");
const provider_management = @import("../config/provider_management.zig");
const provider_presets = @import("../config/provider_presets.zig");
const configured_provider = @import("../config/configured_provider.zig");
const model_provider = @import("../config/model_provider.zig");
const config_runtime = @import("../config/config_runtime.zig");
const provider_secret_store = @import("../auth/provider_secret_store.zig");
const types = @import("../shared/types.zig");
const provider_runtime = @import("provider_runtime.zig");

const Mode = provider_admin_state.Mode;
const Screen = provider_admin_state.Screen;
const Step = provider_admin_state.Step;

/// Live wizard data owned by `App`. The wizard state itself is inert until
/// `wizard.active`; `notice_id` is the pinned prompt notice being replaced in
/// place, and the edit binding lets a saved edit drop the old stored secret.
pub const State = struct {
    wizard: provider_admin_state.State = .{},
    notice_id: ?u32 = null,
    edit_binding: ?[32]u8 = null,
    edit_selected: bool = false,

    pub fn active(self: *const State) bool {
        return self.wizard.active;
    }

    pub fn maskingInput(self: *const State) bool {
        return self.wizard.active and self.wizard.screen == .secret;
    }
};

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn beginAdd(app: *App) !void {
            app.provider_admin.notice_id = null;
            app.provider_admin.edit_binding = null;
            app.provider_admin.edit_selected = false;
            const step = provider_admin_state.beginAdd(&app.provider_admin.wizard);
            try respond(app, step);
        }

        pub fn beginEdit(app: *App, name: []const u8) !void {
            const definition = findDefinition(app, name) orelse {
                try writeResult(app, "That connection is no longer configured.", .warning);
                return;
            };
            const binding = definition.binding_identity();
            const stored = definition.auth == .stored and provider_secret_store.present(binding);
            app.provider_admin.notice_id = null;
            app.provider_admin.edit_binding = binding;
            app.provider_admin.edit_selected = switch (provider_runtime.provider(app)) {
                .configured => |value| if (value.binding) |active| std.mem.eql(u8, &active, &binding) else false,
                else => false,
            };
            const step = provider_admin_state.beginEdit(&app.provider_admin.wizard, definition, stored);
            try respond(app, step);
        }

        /// Enter with the wizard active: the composer content is the answer.
        pub fn submit(app: *App) !void {
            if (!app.provider_admin.wizard.active) return;
            const value = try app.alloc.dupe(u8, app.input_runtime.edit_state.input.items);
            defer app.alloc.free(value);
            _ = app.input_runtime.inputResetState().clearCurrent(app.alloc);
            const step = provider_admin_state.commit(&app.provider_admin.wizard, value);
            try respond(app, step);
        }

        pub fn cancel(app: *App) !void {
            if (!app.provider_admin.wizard.active) return;
            provider_admin_state.cancel(&app.provider_admin.wizard);
            try settleNotice(app, "Provider setup cancelled.", .cancelled);
            app.shell.render_requests.request(.footer);
        }

        /// Removes a configured connection from the manage column and drops its
        /// stored secret. Removing the active connection falls back to Vercel.
        pub fn remove(app: *App, name: []const u8) !void {
            const active_binding: ?[32]u8 = switch (provider_runtime.provider(app)) {
                .configured => |value| value.binding,
                else => null,
            };
            const outcome = provider_management.applyRemove(app.alloc, name) catch |err| {
                try writeResult(app, removeFailureMessage(err), .warning);
                return;
            };
            reloadDefinitions(app);
            if (active_binding) |binding| {
                if (std.mem.eql(u8, &binding, &outcome.binding)) {
                    const fallback = gatewayModel(app);
                    provider_runtime.replaceSelection(app, .gateway, fallback) catch {};
                }
            }
            var buf: [160]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "Removed connection '{s}'.", .{name}) catch "Removed connection.";
            try writeResult(app, text, .neutral);
            app.shell.render_requests.request(.footer);
        }
    };
}

fn respond(app: anytype, step: Step) anyerror!void {
    switch (step) {
        .prompt => try showPrompt(app, null),
        .invalid => |invalid| try showPrompt(app, invalid.message),
        .saved => |draft| try save(app, draft),
        .cancelled => {
            try settleNotice(app, "Provider setup cancelled.", .cancelled);
            app.shell.render_requests.request(.footer);
        },
    }
}

fn showPrompt(app: anytype, invalid: ?[]const u8) !void {
    var buf: [2048]u8 = undefined;
    const text = promptText(&buf, &app.provider_admin.wizard, invalid);
    const tone: types.NoticeTone = if (invalid != null) .warning else .neutral;
    const notice = types.SemanticNotice{ .topic = "provider", .tone = tone, .body = text };
    if (app.provider_admin.notice_id) |id| {
        if (try app.replaceDomainNotice(id, notice)) {
            app.shell.render_requests.request(.footer);
            return;
        }
    }
    app.provider_admin.notice_id = try app.appendReplaceableDomainNotice(notice);
    app.shell.render_requests.request(.footer);
}

fn save(app: anytype, draft_input: provider_management.Draft) !void {
    const wizard = &app.provider_admin.wizard;
    var draft = draft_input;
    draft.select = wizard.mode == .add or app.provider_admin.edit_selected;
    const secret: ?[]const u8 = if (wizard.auth == .stored and wizard.secretText().len != 0)
        wizard.secretText()
    else
        null;
    const old_binding = app.provider_admin.edit_binding;

    var arena_state = std.heap.ArenaAllocator.init(app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (wizard.auth == .stored and secret == null) {
        if (old_binding) |old| {
            const probe = provider_management.composeDefinition(arena, draft) catch |err| {
                return fail(app, err);
            };
            const new_binding = probe.binding_identity();
            if (!std.mem.eql(u8, &old, &new_binding) and !provider_secret_store.present(new_binding)) {
                const step = provider_admin_state.revisit(
                    wizard,
                    .secret,
                    "Connection details changed; enter the stored API key again",
                );
                return respond(app, step);
            }
        }
    }

    const outcome = provider_management.applyAdd(app.alloc, arena, draft, secret) catch |err| {
        return fail(app, err);
    };
    reloadDefinitions(app);
    if (secret != null and old_binding != null and !std.mem.eql(u8, &old_binding.?, &outcome.binding)) {
        provider_secret_store.delete(old_binding.?) catch {};
    }
    if (outcome.selected and outcome.definition.model_metadata.len != 0) {
        const provider = model_provider.parse(outcome.definition.id) orelse .gateway;
        const model = outcome.definition.model_metadata[0].id;
        provider_runtime.replaceSelection(app, provider, model) catch {};
    }
    var buf: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s} connection '{s}'.", .{
        if (outcome.action == .add) "Added" else "Updated",
        outcome.definition.id,
    }) catch "Connection saved.";
    try settleNotice(app, text, .success);
    app.shell.render_requests.request(.footer);
}

fn fail(app: anytype, err: anyerror) !void {
    const step = provider_admin_state.revisit(
        &app.provider_admin.wizard,
        failureScreen(err),
        failureMessage(err),
    );
    try respond(app, step);
}

fn settleNotice(app: anytype, body: []const u8, tone: types.NoticeTone) !void {
    const notice = types.SemanticNotice{ .topic = "provider", .tone = tone, .body = body };
    if (app.provider_admin.notice_id) |id| {
        if (try app.replaceDomainNotice(id, notice)) {
            app.provider_admin.notice_id = null;
            return;
        }
    }
    app.provider_admin.notice_id = null;
    _ = try app.appendDomainNotice(notice);
}

fn writeResult(app: anytype, body: []const u8, tone: types.NoticeTone) !void {
    _ = try app.appendDomainNotice(.{ .topic = "provider", .tone = tone, .body = body });
    app.shell.render_requests.request(.footer);
}

fn reloadDefinitions(app: anytype) void {
    if (comptime @hasField(@TypeOf(app.*), "provider_selection")) {
        const fresh = config_runtime.loadConfiguredProviders(app.alloc) catch return;
        app.provider_selection.definitions.deinit(app.alloc);
        app.provider_selection.definitions = fresh;
    }
}

fn findDefinition(app: anytype, name: []const u8) ?*const configured_provider.Definition {
    if (comptime @hasField(@TypeOf(app.*), "provider_selection")) {
        for (app.provider_selection.definitions.definitions) |*definition| {
            if (std.mem.eql(u8, definition.id, name)) return definition;
        }
    }
    return null;
}

fn gatewayModel(app: anytype) []const u8 {
    if (comptime @hasField(@TypeOf(app.*), "workspace_root")) {
        var settings = config_runtime.loadMergedSettings(app.alloc, app.workspace_root) catch
            return provider_runtime.model(app);
        defer settings.deinit(app.alloc);
        return settings.models.get(.gateway) orelse provider_runtime.model(app);
    }
    return provider_runtime.model(app);
}

fn failureScreen(err: anyerror) Screen {
    return switch (err) {
        error.MissingBaseUrl, error.InvalidBaseUrl, error.InsecureBaseUrl => .base_url,
        error.MissingAuth, error.InvalidEnvironmentName => .env,
        error.MissingModelForSelection, error.InvalidModelId => .model,
        error.InvalidProviderEfforts => .reasoning_efforts,
        error.InvalidSecret, error.KeychainDisabled, error.SecretStoreFailed, error.SecretRollbackFailed => .secret,
        else => .confirm,
    };
}

fn failureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidProviderId => "Provider names may only contain letters, digits, dashes, and underscores",
        error.ReservedProviderId => "That provider name is reserved",
        error.LimitExceeded, error.InvalidDefinition, error.WriteFailed => "The connection details were rejected",
        error.MissingBaseUrl => "A base URL is required for connections without a preset",
        error.InvalidBaseUrl => "The base URL is invalid",
        error.InsecureBaseUrl => "The base URL must use https (or a local address)",
        error.MissingAuth => "An environment variable is required for environment auth",
        error.InvalidEnvironmentName => "Environment variable names must be letters, digits, and underscores",
        error.MissingModelForSelection => "A model is required to select this connection",
        error.InvalidModelId => "The model id is invalid",
        error.InvalidProviderEfforts => "Reasoning efforts must be comma-separated names such as low, high",
        error.InvalidSecret => "The API key must be printable text without spaces",
        error.KeychainDisabled => "Stored keys are disabled here; use environment auth instead",
        error.SecretStoreFailed, error.SecretRollbackFailed => "The API key could not be stored",
        error.SettingsReadFailed => "The saved providers could not be read",
        error.SettingsWriteFailed => "The connection could not be saved",
        error.SelectionFailed => "Saved, but selecting the connection failed; use /provider to select it",
        error.OutOfMemory => "Out of memory while saving the connection",
        else => "The connection could not be saved",
    };
}

fn removeFailureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownProvider => "That connection is no longer configured",
        error.SettingsReadFailed => "The saved providers could not be read",
        error.SettingsWriteFailed => "The connection could not be removed",
        error.SecretDeleteFailed => "Removed the connection, but its stored key could not be deleted",
        error.OutOfMemory => "Out of memory while removing the connection",
        else => "The connection could not be removed",
    };
}

/// Composes the prompt for the current screen, prefixing the validation
/// message when an answer was rejected. Defaults come from the matching
/// provider preset, so Enter alone accepts them.
pub fn promptText(
    buf: []u8,
    state: *const provider_admin_state.State,
    invalid: ?[]const u8,
) []const u8 {
    const preset = provider_presets.find(state.nameText());
    var question_buf: [1024]u8 = undefined;
    const question = buildQuestion(&question_buf, state, preset);
    if (invalid) |message| {
        return std.fmt.bufPrint(buf, "{s}. {s}", .{ message, question }) catch blk: {
            const length = @min(question.len, buf.len);
            @memcpy(buf[0..length], question[0..length]);
            break :blk buf[0..length];
        };
    }
    const length = @min(question.len, buf.len);
    @memcpy(buf[0..length], question[0..length]);
    return buf[0..length];
}

fn buildQuestion(
    buf: []u8,
    state: *const provider_admin_state.State,
    preset: ?*const provider_presets.Preset,
) []const u8 {
    const editing = state.mode == .edit;
    return switch (state.screen) {
        .name => if (editing)
            std.fmt.bufPrint(buf, "Edit connection '{s}': name", .{state.nameText()}) catch "Edit connection: name"
        else
            "Add provider: name",
        .base_url => if (preset) |value|
            std.fmt.bufPrint(buf, "Base URL (default: {s})", .{value.base_url}) catch "Base URL"
        else
            "Base URL (required)",
        .auth => "Auth [none/env/stored] (default: env)",
        .env => if (preset) |value|
            std.fmt.bufPrint(buf, "API key environment variable (default: {s})", .{value.api_key_env}) catch "API key environment variable"
        else
            "API key environment variable (required)",
        .secret => if (editing and state.has_stored_secret)
            "API key (hidden; leave blank to keep the stored key)"
        else
            "API key (hidden)",
        .model => if (preset) |value|
            std.fmt.bufPrint(buf, "Model (default: {s})", .{value.models[0].id}) catch "Model"
        else
            "Model (required)",
        .context_window => "Context window in tokens (optional)",
        .max_output_tokens => "Max output tokens (optional)",
        .tool_use => "Tool use [default/yes/no] (default: default)",
        .vision => "Vision [default/yes/no] (default: default)",
        .reasoning_efforts => "Reasoning efforts, comma separated (optional)",
        .confirm => "Save this connection? [yes/no] (default: yes)",
    };
}

test "provider wizard prompts name the preset defaults" {
    var state: provider_admin_state.State = .{};
    _ = provider_admin_state.beginAdd(&state);
    var buf: [2048]u8 = undefined;
    try std.testing.expectEqualStrings("Add provider: name", promptText(&buf, &state, null));

    _ = provider_admin_state.commit(&state, "deepseek");
    try std.testing.expectEqualStrings(
        "Base URL (default: https://api.deepseek.com)",
        promptText(&buf, &state, null),
    );
    try std.testing.expectEqualStrings(
        "Provider name is required. Base URL (default: https://api.deepseek.com)",
        promptText(&buf, &state, "Provider name is required"),
    );

    _ = provider_admin_state.commit(&state, "");
    _ = provider_admin_state.commit(&state, "env");
    try std.testing.expectEqualStrings(
        "API key environment variable (default: DEEPSEEK_API_KEY)",
        promptText(&buf, &state, null),
    );
    _ = provider_admin_state.commit(&state, "");
    try std.testing.expectEqualStrings(
        "Model (default: deepseek-flash)",
        promptText(&buf, &state, null),
    );
    _ = provider_admin_state.commit(&state, "");
    _ = provider_admin_state.commit(&state, "");
    _ = provider_admin_state.commit(&state, "");
    _ = provider_admin_state.commit(&state, "");
    _ = provider_admin_state.commit(&state, "");
    _ = provider_admin_state.commit(&state, "");
    try std.testing.expectEqualStrings(
        "Save this connection? [yes/no] (default: yes)",
        promptText(&buf, &state, null),
    );
}

test "provider wizard prompt marks the hidden secret and edit mode" {
    var state: provider_admin_state.State = .{};
    _ = provider_admin_state.beginAdd(&state);
    _ = provider_admin_state.commit(&state, "custom");
    _ = provider_admin_state.commit(&state, "https://example.com/v1");
    _ = provider_admin_state.commit(&state, "stored");
    var buf: [2048]u8 = undefined;
    try std.testing.expectEqualStrings("API key (hidden)", promptText(&buf, &state, null));

    state = .{};
    const alloc = std.testing.allocator;
    var registry = try configured_provider.Registry.parse_json(
        alloc,
        "{\"custom\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://example.com/v1\",\"auth\":{\"type\":\"stored\"}}}",
    );
    defer registry.deinit(alloc);
    _ = provider_admin_state.beginEdit(&state, registry.get("custom").?, true);
    try std.testing.expectEqualStrings(
        "Edit connection 'custom': name",
        promptText(&buf, &state, null),
    );
    _ = provider_admin_state.commit(&state, "custom");
    _ = provider_admin_state.commit(&state, "https://example.com/v1");
    _ = provider_admin_state.commit(&state, "stored");
    try std.testing.expectEqualStrings(
        "API key (hidden; leave blank to keep the stored key)",
        promptText(&buf, &state, null),
    );
}

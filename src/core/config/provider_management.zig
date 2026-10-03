const std = @import("std");
const config_runtime = @import("config_runtime.zig");
const configured_provider = @import("configured_provider.zig");
const model_provider = @import("model_provider.zig");
const provider_presets = @import("provider_presets.zig");
const provider_secret_store = @import("../auth/provider_secret_store.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// Provider-owned fields a caller can set from a CLI flag or a TUI wizard.
/// Preset defaults fill anything left null before validation.
pub const Draft = struct {
    name: []const u8 = "",
    base_url: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
    save_api_key: bool = false,
    no_auth: bool = false,
    model: ?[]const u8 = null,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    tool_use: bool = false,
    no_tool_use: bool = false,
    vision: bool = false,
    no_vision: bool = false,
    /// Parsed reasoning effort names. `reasoning_efforts_raw` is the CLI form.
    reasoning_efforts: []const []const u8 = &.{},
    reasoning_efforts_raw: ?[]const u8 = null,
    tool_choice_mode: configured_provider.ToolChoiceMode = .omit,
    select: bool = true,
};

pub const ComposeError = error{
    OutOfMemory,
    WriteFailed,
    MissingBaseUrl,
    MissingAuth,
    MissingModelForSelection,
    InvalidProviderEfforts,
    InvalidProviderId,
    ReservedProviderId,
    LimitExceeded,
    InvalidBaseUrl,
    InsecureBaseUrl,
    InvalidEnvironmentName,
    InvalidModelId,
    InvalidDefinition,
};

pub const AddError = ComposeError || error{
    SettingsReadFailed,
    SettingsWriteFailed,
    SelectionFailed,
    InvalidSecret,
    KeychainDisabled,
    SecretStoreFailed,
    SecretRollbackFailed,
};

pub const AddAction = enum { add, update };

pub const AddOutcome = struct {
    action: AddAction,
    definition: configured_provider.Definition,
    binding: [32]u8,
    selected: bool,
    secret_saved: bool,
};

pub const SummaryError = error{
    SettingsReadFailed,
    SettingsLoadFailed,
    OutOfMemory,
};

pub const RemoveError = error{
    SettingsReadFailed,
    UnknownProvider,
    SettingsWriteFailed,
    SecretDeleteFailed,
    OutOfMemory,
};

pub const RemoveOutcome = struct {
    binding: [32]u8,
    secret_removed: bool,
};

pub const Summary = struct {
    definition: configured_provider.Definition,
    binding: [32]u8,
    selected: bool,
    selected_model: ?[]const u8,
    stored_credential_present: bool,
};

/// Parses the CLI `--reasoning-efforts` value. Empty and `none` mean no
/// declared efforts; duplicates and default efforts are rejected.
pub fn parseEfforts(alloc: Allocator, raw: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "none")) return &.{};
    var items: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, trimmed, ',');
    while (iterator.next()) |part| {
        const effort = std.mem.trim(u8, part, " \t");
        if (effort.len == 0) return error.InvalidProviderEfforts;
        const parsed = types.ReasoningEffort.parse(effort) orelse return error.InvalidProviderEfforts;
        if (parsed.isDefault()) return error.InvalidProviderEfforts;
        for (items.items) |existing| {
            if (std.mem.eql(u8, existing, effort)) return error.InvalidProviderEfforts;
        }
        try items.append(alloc, effort);
    }
    return items.toOwnedSlice(alloc);
}

pub fn validSecret(value: []const u8) bool {
    if (value.len == 0 or value.len > provider_secret_store.max_secret_bytes) return false;
    for (value) |byte| {
        if (byte <= 0x20 or byte >= 0x7f) return false;
    }
    return true;
}

/// Builds and validates one configured-provider definition from a draft.
/// Preset defaults apply to missing base URL, env auth, model, and metadata;
/// explicit draft fields always win. The returned definition borrows `arena`.
pub fn composeDefinition(
    arena: Allocator,
    draft: Draft,
) ComposeError!configured_provider.Definition {
    configured_provider.validate_id(draft.name) catch |err| return switch (err) {
        error.ReservedProviderId => error.ReservedProviderId,
        error.InvalidProviderId => error.InvalidProviderId,
        error.LimitExceeded => error.LimitExceeded,
    };

    const preset: ?*const provider_presets.Preset = provider_presets.find(draft.name);
    const base_url = draft.base_url orelse
        (if (preset) |value| value.base_url else return error.MissingBaseUrl);
    const auth: configured_provider.Auth = if (draft.no_auth)
        .none
    else if (draft.save_api_key)
        .stored
    else
        .{ .bearer = draft.api_key_env orelse
            (if (preset) |value| value.api_key_env else return error.MissingAuth) };

    const model: ?[]const u8 = draft.model orelse
        (if (preset) |value| value.models[0].id else null);
    if (draft.select and model == null) return error.MissingModelForSelection;

    var preset_model: ?*const provider_presets.ModelPreset = null;
    if (preset) |value| {
        if (model) |id| preset_model = value.model(id);
    }
    const efforts: []const []const u8 = if (draft.reasoning_efforts_raw) |raw|
        parseEfforts(arena, raw) catch return error.InvalidProviderEfforts
    else if (draft.reasoning_efforts.len != 0)
        draft.reasoning_efforts
    else if (preset_model) |value|
        value.reasoning_efforts
    else
        &.{};
    const supports_tool_use: ?bool = if (draft.no_tool_use)
        false
    else if (draft.tool_use)
        true
    else if (preset_model) |value|
        value.supports_tool_use
    else
        null;
    const supports_vision: ?bool = if (draft.no_vision)
        false
    else if (draft.vision)
        true
    else if (preset_model) |value|
        value.supports_vision
    else
        null;
    const context_window = draft.context_window orelse
        (if (preset_model) |value| value.context_window else null);
    const max_output_tokens = draft.max_output_tokens orelse
        (if (preset_model) |value| value.max_output_tokens else null);

    const json = try buildConfiguredProviderJson(
        arena,
        draft.name,
        base_url,
        auth,
        draft.tool_choice_mode,
        model,
        context_window,
        max_output_tokens,
        supports_tool_use,
        supports_vision,
        efforts,
    );
    var registry = configured_provider.Registry.parse_json(arena, json) catch |err| return switch (err) {
        error.InvalidBaseUrl => error.InvalidBaseUrl,
        error.InsecureBaseUrl => error.InsecureBaseUrl,
        error.InvalidEnvironmentName => error.InvalidEnvironmentName,
        error.InvalidModelId, error.InvalidModelMetadata => error.InvalidModelId,
        else => error.InvalidDefinition,
    };
    return registry.get(draft.name).?.*;
}

/// Writes the provider definition, stores the secret when one is supplied, and
/// selects the connection when the draft asks for it. `arena` owns the
/// returned definition; `alloc` owns temporary work.
pub fn applyAdd(
    alloc: Allocator,
    arena: Allocator,
    draft: Draft,
    secret: ?[]const u8,
) AddError!AddOutcome {
    const definition = try composeDefinition(arena, draft);
    const binding = definition.binding_identity();

    var action: AddAction = .add;
    {
        var existing = config_runtime.loadConfiguredProviders(alloc) catch
            return error.SettingsReadFailed;
        defer existing.deinit(alloc);
        if (existing.get(definition.id) != null) action = .update;
    }

    var secret_saved = false;
    if (secret) |value| {
        if (!validSecret(value)) return error.InvalidSecret;
        if (provider_secret_store.isDisabled()) return error.KeychainDisabled;
        provider_secret_store.store(alloc, binding, value) catch return error.SecretStoreFailed;
        secret_saved = true;
    }

    var attempt = config_runtime.attemptProviderMutation(alloc, .{ .upsert = definition });
    defer attempt.deinit(alloc);
    switch (attempt) {
        .failure => {
            if (secret_saved) {
                provider_secret_store.delete(binding) catch return error.SecretRollbackFailed;
            }
            return error.SettingsWriteFailed;
        },
        .outcome => {},
    }

    var selected = false;
    if (draft.select) {
        if (definition.model_metadata.len != 0) {
            const id = definition.model_metadata[0].id;
            var bound = model_provider.parse(definition.id).?;
            bound.configured.binding = binding;
            var preference = config_runtime.attemptUserPreferences(alloc, .{
                .provider = bound,
                .model_preference = .{ .provider = bound, .model = id },
            });
            defer preference.deinit(alloc);
            switch (preference) {
                .failure => return error.SelectionFailed,
                .outcome => selected = true,
            }
        }
    }

    return .{
        .action = action,
        .definition = definition,
        .binding = binding,
        .selected = selected,
        .secret_saved = secret_saved,
    };
}

/// Removes one configured provider and its stored secret when it used one.
pub fn applyRemove(alloc: Allocator, name: []const u8) RemoveError!RemoveOutcome {
    var registry = config_runtime.loadConfiguredProviders(alloc) catch
        return error.SettingsReadFailed;
    defer registry.deinit(alloc);
    const definition = registry.get(name) orelse return error.UnknownProvider;
    const binding = definition.binding_identity();
    const stored_auth = switch (definition.auth) {
        .stored => true,
        .none, .bearer => false,
    };

    var attempt = config_runtime.attemptProviderMutation(alloc, .{ .remove = name });
    defer attempt.deinit(alloc);
    switch (attempt) {
        .failure => return error.SettingsWriteFailed,
        .outcome => {},
    }

    var secret_removed = false;
    if (stored_auth) {
        provider_secret_store.delete(binding) catch return error.SecretDeleteFailed;
        secret_removed = true;
    }
    return .{ .binding = binding, .secret_removed = secret_removed };
}

/// Lists configured providers for the current workspace, including selection
/// and stored-credential state. Definitions borrow `arena`.
pub fn summaries(arena: Allocator, alloc: Allocator) SummaryError![]Summary {
    var registry = config_runtime.loadConfiguredProviders(arena) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SettingsReadFailed,
    };
    errdefer registry.deinit(arena);
    const workspace_root = std.process.currentPathAlloc(io_mod.getIo(), alloc) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SettingsReadFailed,
    };
    defer alloc.free(workspace_root);
    var settings = config_runtime.loadMergedSettings(alloc, workspace_root) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SettingsLoadFailed,
    };
    defer settings.deinit(alloc);

    var entries: std.ArrayList(Summary) = .empty;
    for (registry.definitions) |*definition| {
        const binding = definition.binding_identity();
        const selected = if (settings.provider) |selected_provider| blk: {
            if (!std.mem.eql(u8, selected_provider.label(), definition.id)) break :blk false;
            switch (selected_provider) {
                .configured => |configured| {
                    const selected_binding = configured.binding orelse break :blk false;
                    break :blk std.mem.eql(u8, &selected_binding, &binding);
                },
                else => break :blk false,
            }
        } else false;
        const identity = model_provider.parse(definition.id).?;
        try entries.append(arena, .{
            .definition = definition.*,
            .binding = binding,
            .selected = selected,
            .selected_model = if (selected)
                (if (settings.models.get(identity)) |model| try arena.dupe(u8, model) else null)
            else
                null,
            .stored_credential_present = switch (definition.auth) {
                .stored => provider_secret_store.present(binding),
                .none, .bearer => false,
            },
        });
    }
    return entries.toOwnedSlice(arena);
}

fn buildConfiguredProviderJson(
    arena: Allocator,
    name: []const u8,
    base_url: []const u8,
    auth: configured_provider.Auth,
    tool_choice_mode: configured_provider.ToolChoiceMode,
    model: ?[]const u8,
    context_window: ?u32,
    max_output_tokens: ?u32,
    supports_tool_use: ?bool,
    supports_vision: ?bool,
    reasoning_efforts: []const []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeByte('{');
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(":{\"protocol\":\"openai-chat-completions\",\"base_url\":");
    try std.json.Stringify.value(base_url, .{}, writer);
    try writer.writeAll(",\"auth\":");
    switch (auth) {
        .none => try writer.writeAll("{\"type\":\"none\"}"),
        .stored => try writer.writeAll("{\"type\":\"stored\"}"),
        .bearer => |env| {
            try writer.writeAll("{\"type\":\"bearer\",\"env\":");
            try std.json.Stringify.value(env, .{}, writer);
            try writer.writeByte('}');
        },
    }
    if (tool_choice_mode == .send) try writer.writeAll(",\"tool_choice_mode\":\"send\"");
    if (model) |id| {
        try writer.writeAll(",\"model_metadata\":{");
        try std.json.Stringify.value(id, .{}, writer);
        try writer.writeAll(":{");
        var comma = false;
        if (context_window) |value| {
            try writer.print("\"context_window\":{d}", .{value});
            comma = true;
        }
        if (max_output_tokens) |value| {
            if (comma) try writer.writeByte(',');
            try writer.print("\"max_output_tokens\":{d}", .{value});
            comma = true;
        }
        if (supports_tool_use) |value| {
            if (comma) try writer.writeByte(',');
            try writer.print("\"supports_tool_use\":{}", .{value});
            comma = true;
        }
        if (supports_vision) |value| {
            if (comma) try writer.writeByte(',');
            try writer.print("\"supports_vision\":{}", .{value});
            comma = true;
        }
        if (reasoning_efforts.len != 0) {
            if (comma) try writer.writeByte(',');
            try writer.writeAll("\"reasoning_efforts\":[");
            for (reasoning_efforts, 0..) |effort, effort_index| {
                if (effort_index != 0) try writer.writeByte(',');
                try std.json.Stringify.value(effort, .{}, writer);
            }
            try writer.writeByte(']');
        }
        try writer.writeAll("}}");
    }
    try writer.writeAll("}}");
    return out.toOwnedSlice();
}

test "draft composition applies preset defaults and explicit overrides" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const preset = try composeDefinition(arena, .{ .name = "deepseek" });
    try std.testing.expectEqualStrings("https://api.deepseek.com", preset.base_url);
    try std.testing.expectEqualStrings("deepseek-flash", preset.model_metadata[0].id);
    try std.testing.expectEqualStrings("DEEPSEEK_API_KEY", preset.auth.bearer);

    const override = try composeDefinition(arena, .{
        .name = "deepseek",
        .base_url = "https://example.com/v1",
        .api_key_env = "MY_KEY",
        .model = "custom-model",
        .context_window = 4096,
        .no_tool_use = true,
        .no_vision = true,
    });
    try std.testing.expectEqualStrings("https://example.com/v1", override.base_url);
    try std.testing.expectEqualStrings("MY_KEY", override.auth.bearer);
    try std.testing.expectEqualStrings("custom-model", override.model_metadata[0].id);
    try std.testing.expectEqual(@as(?u32, 4096), override.model_metadata[0].context_window);
    try std.testing.expectEqual(@as(?bool, false), override.model_metadata[0].supports_tool_use);
    try std.testing.expectEqual(@as(?bool, false), override.model_metadata[0].supports_vision);

    try std.testing.expectError(
        error.MissingBaseUrl,
        composeDefinition(arena, .{ .name = "unknown-provider" }),
    );
}

test "draft composition requires a model when selecting" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(
        error.MissingModelForSelection,
        composeDefinition(arena, .{
            .name = "custom",
            .base_url = "https://example.com/v1",
            .no_auth = true,
        }),
    );
    const unselected = try composeDefinition(arena, .{
        .name = "custom",
        .base_url = "https://example.com/v1",
        .no_auth = true,
        .select = false,
    });
    try std.testing.expectEqual(@as(usize, 0), unselected.model_metadata.len);
}

test "draft composition validates effort lists and ids" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const efforts = try parseEfforts(arena, "low, high, max");
    try std.testing.expectEqual(@as(usize, 3), efforts.len);
    try std.testing.expectEqualStrings("low", efforts[0]);
    try std.testing.expectError(error.InvalidProviderEfforts, parseEfforts(arena, "low,low"));
    try std.testing.expectError(error.InvalidProviderEfforts, parseEfforts(arena, "default"));

    try std.testing.expectError(
        error.ReservedProviderId,
        composeDefinition(arena, .{
            .name = "gateway",
            .base_url = "https://example.com/v1",
            .no_auth = true,
        }),
    );
}

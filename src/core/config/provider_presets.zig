const std = @import("std");

/// Static defaults for well-known OpenAI-compatible endpoints. Values mirror
/// the provider's published model metadata so `fx provider add <name>` works
/// without hand-tuning capabilities. They are only defaults; explicit flags
/// always win.
pub const ModelPreset = struct {
    id: []const u8,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    supports_tool_use: ?bool = null,
    supports_vision: ?bool = null,
    reasoning_efforts: []const []const u8 = &.{},
};

pub const Preset = struct {
    name: []const u8,
    base_url: []const u8,
    api_key_env: []const u8,
    models: []const ModelPreset,

    pub fn model(self: Preset, id: []const u8) ?*const ModelPreset {
        for (self.models) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }
};

const deepseek_models = [_]ModelPreset{
    .{
        .id = "deepseek-flash",
        .context_window = 1_000_000,
        .max_output_tokens = 393_216,
        .supports_tool_use = true,
        .supports_vision = true,
        .reasoning_efforts = &.{ "low", "high", "max" },
    },
    .{
        .id = "deepseek-v4-pro",
        .context_window = 1_000_000,
        .max_output_tokens = 393_216,
        .supports_tool_use = true,
        .supports_vision = false,
        .reasoning_efforts = &.{ "low", "high", "max" },
    },
};

pub const presets = [_]Preset{
    .{
        .name = "deepseek",
        .base_url = "https://api.deepseek.com",
        .api_key_env = "DEEPSEEK_API_KEY",
        .models = &deepseek_models,
    },
};

pub fn find(name: []const u8) ?*const Preset {
    for (&presets) |*preset| {
        if (std.ascii.eqlIgnoreCase(preset.name, name)) return preset;
    }
    return null;
}

test "deepseek preset names the documented endpoint models and efforts" {
    const preset = find("DeepSeek").?;
    try std.testing.expectEqualStrings("https://api.deepseek.com", preset.base_url);
    try std.testing.expectEqualStrings("DEEPSEEK_API_KEY", preset.api_key_env);
    try std.testing.expectEqualStrings("deepseek-flash", preset.models[0].id);
    try std.testing.expectEqual(@as(?u32, 1_000_000), preset.models[0].context_window);
    try std.testing.expectEqual(@as(?u32, 393_216), preset.models[0].max_output_tokens);
    try std.testing.expectEqual(@as(?bool, true), preset.models[0].supports_tool_use);
    try std.testing.expectEqual(@as(usize, 3), preset.models[0].reasoning_efforts.len);
    try std.testing.expectEqualStrings("max", preset.models[0].reasoning_efforts[2]);
    try std.testing.expect(find("unknown") == null);
}

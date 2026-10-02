const std = @import("std");
const native_keychain = @import("../hosts/native_keychain.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("../auth/secret.zig");

const Allocator = std.mem.Allocator;

/// Stored provider credentials are route-owned secrets. They never enter
/// settings.json; each file is named after the non-secret binding identity of
/// the connection that owns it.
pub const max_secret_bytes: usize = 16 * 1024;

pub const LoadError = Allocator.Error || error{
    StoredKeyUnreadable,
    StoredKeyInsecure,
    ProviderSecretStoreDisabled,
};

pub const WriteError = Allocator.Error || error{
    StoredKeyWriteFailed,
    ProviderSecretStoreDisabled,
};

pub const DeleteError = error{
    StoredKeyWriteFailed,
    ProviderSecretStoreDisabled,
};

/// The disable switch is shared with the platform credential store. Stored
/// provider keys must not bypass a user's explicit request to keep secrets out
/// of fx-managed storage.
pub fn isDisabled() bool {
    return native_keychain.isDisabled();
}

/// Returns the stored secret, or null when none is stored or the store is
/// disabled. Errors stay distinct from absence so callers never send with a
/// credential they could not read.
pub fn load(alloc: Allocator, binding: [32]u8) LoadError!?[]u8 {
    if (isDisabled()) return error.ProviderSecretStoreDisabled;
    const home = io_mod.getenv("HOME") orelse return error.StoredKeyUnreadable;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return error.StoredKeyUnreadable;
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.StoredKeyUnreadable,
    };
    defer fx_dir.close(io_mod.getIo());

    var credentials_dir = fx_dir.openDir(io_mod.getIo(), profile_paths.provider_credentials_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.StoredKeyUnreadable,
    };
    defer credentials_dir.close(io_mod.getIo());

    return loadFromDir(alloc, &credentials_dir, binding);
}

/// Presence is metadata only; secret bytes are never read or copied.
pub fn present(binding: [32]u8) bool {
    if (isDisabled()) return false;
    const home = io_mod.getenv("HOME") orelse return false;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return false;
    defer home_dir.close(io_mod.getIo());
    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return false;
    defer fx_dir.close(io_mod.getIo());
    var credentials_dir = fx_dir.openDir(io_mod.getIo(), profile_paths.provider_credentials_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return false;
    defer credentials_dir.close(io_mod.getIo());
    const file_name = secretFileName(binding);
    const stat = credentials_dir.statFile(io_mod.getIo(), &file_name, .{
        .follow_symlinks = false,
    }) catch return false;
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return false;
    return stat.size != 0;
}

pub fn store(alloc: Allocator, binding: [32]u8, value: []const u8) WriteError!void {
    if (isDisabled()) return error.ProviderSecretStoreDisabled;
    if (value.len == 0 or value.len > max_secret_bytes) return error.StoredKeyWriteFailed;
    const home = io_mod.getenv("HOME") orelse return error.StoredKeyWriteFailed;
    var home_dir = io_mod.VerifiedDir{
        .dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch return error.StoredKeyWriteFailed,
    };
    defer home_dir.close();

    var fx_dir = io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name) catch
        return error.StoredKeyWriteFailed;
    defer fx_dir.close();

    var credentials_dir = io_mod.openOrCreateVerifiedPrivateDir(&fx_dir, profile_paths.provider_credentials_dir_name) catch
        return error.StoredKeyWriteFailed;
    defer credentials_dir.close();

    try storeInDir(alloc, &credentials_dir, binding, value);
}

pub fn delete(binding: [32]u8) DeleteError!void {
    if (isDisabled()) return error.ProviderSecretStoreDisabled;
    const home = io_mod.getenv("HOME") orelse return;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return;
    defer home_dir.close(io_mod.getIo());
    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return;
    defer fx_dir.close(io_mod.getIo());
    var credentials_dir = fx_dir.openDir(io_mod.getIo(), profile_paths.provider_credentials_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return;
    defer credentials_dir.close(io_mod.getIo());
    try deleteFromDir(&credentials_dir, binding);
}

fn secretFileName(binding: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(binding, .lower);
}

fn loadFromDir(alloc: Allocator, dir: *std.Io.Dir, binding: [32]u8) LoadError!?[]u8 {
    const file_name = secretFileName(binding);
    var file = dir.openFile(io_mod.getIo(), &file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.StoredKeyUnreadable,
    };
    defer file.close(io_mod.getIo());

    const stat = file.stat(io_mod.getIo()) catch return error.StoredKeyUnreadable;
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.StoredKeyInsecure;

    const bytes = io_mod.readFileToEnd(alloc, &file, max_secret_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.StoredKeyUnreadable,
    };
    var borrowed = false;
    defer if (!borrowed) secret.zeroAndFree(alloc, bytes);

    const trimmed = std.mem.trim(u8, bytes, "\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed.len == bytes.len) {
        borrowed = true;
        return bytes;
    }
    return try alloc.dupe(u8, trimmed);
}

fn storeInDir(alloc: Allocator, dir: *io_mod.VerifiedDir, binding: [32]u8, value: []const u8) WriteError!void {
    if (value.len == 0 or value.len > max_secret_bytes) return error.StoredKeyWriteFailed;
    const file_name = secretFileName(binding);
    io_mod.durableReplaceVerified(alloc, dir, &file_name, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.StoredKeyWriteFailed,
    };
}

fn deleteFromDir(dir: *std.Io.Dir, binding: [32]u8) DeleteError!void {
    const file_name = secretFileName(binding);
    dir.deleteFile(io_mod.getIo(), &file_name) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return error.StoredKeyWriteFailed,
    };
}

test "provider secret file round-trips byte-identically at mode 0600" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var credentials_dir = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true, .follow_symlinks = false }),
    };
    defer credentials_dir.close();

    const binding = [_]u8{0xab} ** 32;
    const file_name = secretFileName(binding);
    const written = "sk-provider-round-trip-value";
    try storeInDir(std.testing.allocator, &credentials_dir, binding, written);

    const stat = try tmp.dir.statFile(std.testing.io, &file_name, .{});
    try std.testing.expect(stat.permissions.toMode() & 0o777 == 0o600);

    const read_back = (try loadFromDir(std.testing.allocator, &credentials_dir.dir, binding)) orelse
        return error.TestUnexpectedMissingStoredKey;
    defer secret.zeroAndFree(std.testing.allocator, read_back);
    try std.testing.expectEqualStrings(written, read_back);

    try deleteFromDir(&credentials_dir.dir, binding);
    try std.testing.expect((try loadFromDir(std.testing.allocator, &credentials_dir.dir, binding)) == null);
    try deleteFromDir(&credentials_dir.dir, binding);
}

test "provider secret load refuses insecure modes and distinguishes absence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var credentials_dir = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true, .follow_symlinks = false }),
    };
    defer credentials_dir.close();

    const binding = [_]u8{0x01} ** 32;
    const file_name = secretFileName(binding);
    try std.testing.expect((try loadFromDir(std.testing.allocator, &credentials_dir.dir, binding)) == null);

    try storeInDir(std.testing.allocator, &credentials_dir, binding, "insecure-value");
    for ([_]std.posix.mode_t{ 0o640, 0o604, 0o644 }) |mode| {
        var file = try tmp.dir.openFile(std.testing.io, &file_name, .{ .mode = .read_write });
        try file.setPermissions(std.testing.io, std.Io.File.Permissions.fromMode(mode));
        file.close(std.testing.io);
        try std.testing.expectError(
            error.StoredKeyInsecure,
            loadFromDir(std.testing.allocator, &credentials_dir.dir, binding),
        );
    }
}

test "provider secret store rejects empty and oversized values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var credentials_dir = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true, .follow_symlinks = false }),
    };
    defer credentials_dir.close();

    const binding = [_]u8{0x02} ** 32;
    try std.testing.expectError(error.StoredKeyWriteFailed, storeInDir(std.testing.allocator, &credentials_dir, binding, ""));
    const oversized = try std.testing.allocator.alloc(u8, max_secret_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'a');
    try std.testing.expectError(error.StoredKeyWriteFailed, storeInDir(std.testing.allocator, &credentials_dir, binding, oversized));

    const newline_binding = [_]u8{0x03} ** 32;
    try storeInDir(std.testing.allocator, &credentials_dir, newline_binding, "hand-edited-value\n");
    const read_back = (try loadFromDir(std.testing.allocator, &credentials_dir.dir, newline_binding)).?;
    defer secret.zeroAndFree(std.testing.allocator, read_back);
    try std.testing.expectEqualStrings("hand-edited-value", read_back);
}

fn test_allocations(alloc: Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var credentials_dir = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true, .follow_symlinks = false }),
    };
    defer credentials_dir.close();
    const binding = [_]u8{0x04} ** 32;
    try storeInDir(alloc, &credentials_dir, binding, "allocation-failure-value");
    const read_back = (try loadFromDir(alloc, &credentials_dir.dir, binding)).?;
    defer secret.zeroAndFree(alloc, read_back);
}

test "provider secret allocation failures release partial state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_allocations, .{});
}

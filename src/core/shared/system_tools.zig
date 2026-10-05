//! Locating the host's standard utilities portably.
//!
//! The read-only execution engine passes a fixed, root-owned PATH to the
//! children it spawns, and its plans name conventional absolute paths such as
//! `/bin/ls`. A distribution that keeps its userland elsewhere (NixOS) has
//! neither `/usr/bin` nor `/bin`, so both the PATH and the lookup fall back to
//! the zero-configuration system profile when the host provides one.
//!
//! Everything here is read-only. Callers own the returned memory.

const std = @import("std");
const io_mod = @import("io.zig");

/// Appended to the conventional PATH, in order, when the directory exists.
pub const fallback_dirs = [_][]const u8{
    "/run/current-system/sw/bin",
    "/nix/var/nix/profiles/default/bin",
};

/// The PATH used for reviewed read-only commands: the conventional system
/// directories plus whichever system profile this host actually has. The list
/// stays root-owned so a caller cannot redirect a reviewed command to a
/// binary of its own.
pub fn readOnlyPathAlloc(alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "/usr/bin:/bin");
    const io = io_mod.getIo();
    for (fallback_dirs) |dir| {
        std.Io.Dir.accessAbsolute(io, dir, .{}) catch continue;
        try out.append(alloc, ':');
        try out.appendSlice(alloc, dir);
    }
    return out.toOwnedSlice(alloc);
}

/// Looks `name` up on `path`, returning an owned absolute path, or null when
/// no directory holds it. Entries that are not absolute are ignored.
pub fn findInPathAlloc(alloc: std.mem.Allocator, path: []const u8, name: []const u8) !?[]u8 {
    if (name.len == 0 or std.mem.findScalar(u8, name, '/') != null) return null;
    const io = io_mod.getIo();
    var iterator = std.mem.splitScalar(u8, path, ':');
    while (iterator.next()) |dir| {
        if (dir.len == 0 or dir[0] != '/') continue;
        const candidate = try std.fs.path.join(alloc, &.{ dir, name });
        std.Io.Dir.accessAbsolute(io, candidate, .{}) catch {
            alloc.free(candidate);
            continue;
        };
        return candidate;
    }
    return null;
}

/// Looks `name` up on the read-only PATH.
pub fn findStandardAlloc(alloc: std.mem.Allocator, name: []const u8) !?[]u8 {
    const path = try readOnlyPathAlloc(alloc);
    defer alloc.free(path);
    return findInPathAlloc(alloc, path, name);
}

/// Plans name conventional absolute paths such as `/bin/ls`. When the planned
/// path does not exist, the same program is looked up on `path` and the
/// returned argv carries the substitute as argv[0]. The plan itself is never
/// modified; `argv` is returned unchanged when no substitution is needed, and
/// otherwise the result is a fresh slice owned by `alloc` whose first element
/// is owned too. Callers that free should use `freeResolvedArgvAlloc`.
pub fn resolvePlannedArgvAlloc(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    path: []const u8,
) ![]const []const u8 {
    if (argv.len == 0) return argv;
    if (!std.fs.path.isAbsolute(argv[0])) return argv;
    if (std.Io.Dir.accessAbsolute(io_mod.getIo(), argv[0], .{})) |_| return argv else |_| {}

    const resolved = (try findInPathAlloc(alloc, path, std.fs.path.basename(argv[0]))) orelse return argv;
    const replaced = try alloc.alloc([]const u8, argv.len);
    @memcpy(replaced, argv);
    replaced[0] = resolved;
    return replaced;
}

/// Frees a slice returned by `resolvePlannedArgvAlloc` when it was replaced.
pub fn freeResolvedArgvAlloc(
    alloc: std.mem.Allocator,
    original: []const []const u8,
    resolved: []const []const u8,
) void {
    if (resolved.ptr == original.ptr) return;
    alloc.free(resolved[0]);
    alloc.free(resolved);
}

fn directoryExists(path: []const u8) bool {
    if (std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{})) |_| return true else |_| return false;
}

test "the read-only path starts with the conventional directories and adds real profiles" {
    const alloc = std.testing.allocator;
    const path = try readOnlyPathAlloc(alloc);
    defer alloc.free(path);

    try std.testing.expect(std.mem.startsWith(u8, path, "/usr/bin:/bin"));
    for (fallback_dirs) |dir| {
        try std.testing.expectEqual(directoryExists(dir), std.mem.find(u8, path, dir) != null);
    }
}

test "lookup skips relative entries and rejects names with separators" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "tool", .data = "#!/bin/sh\n" });
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);

    const path = try std.fmt.allocPrint(alloc, "relative:{s}", .{dir});
    defer alloc.free(path);

    const found = (try findInPathAlloc(alloc, path, "tool")).?;
    defer alloc.free(found);
    const expected = try std.fs.path.join(alloc, &.{ dir, "tool" });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, found);

    try std.testing.expect((try findInPathAlloc(alloc, path, "missing")) == null);
    try std.testing.expect((try findInPathAlloc(alloc, path, "sub/tool")) == null);
    try std.testing.expect((try findInPathAlloc(alloc, path, "")) == null);
}

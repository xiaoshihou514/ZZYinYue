const std = @import("std");

pub const Paths = struct {
    config_dir: []const u8,
    cache_dir: []const u8,
    data_dir: []const u8,
    state_dir: []const u8,
    config_file: []const u8,
    database_file: []const u8,
    state_file: []const u8,
};

pub const Config = struct {
    music_roots: []const []const u8,
    animations: bool,
    scan_on_startup: bool,
};

pub const Loaded = struct {
    allocator: std.mem.Allocator,
    paths: Paths,
    config: Config,

    pub fn deinit(self: *Loaded) void {
        for (self.config.music_roots) |root| self.allocator.free(root);
        self.allocator.free(self.config.music_roots);

        self.allocator.free(self.paths.config_dir);
        self.allocator.free(self.paths.cache_dir);
        self.allocator.free(self.paths.data_dir);
        self.allocator.free(self.paths.state_dir);
        self.allocator.free(self.paths.config_file);
        self.allocator.free(self.paths.database_file);
        self.allocator.free(self.paths.state_file);

        self.* = undefined;
    }
};

pub fn loadOrCreate(allocator: std.mem.Allocator) !Loaded {
    const paths = try resolvePaths(allocator);
    errdefer freePaths(allocator, paths);

    makeDirIfMissing(paths.config_dir) catch |err| return err;
    makeDirIfMissing(paths.cache_dir) catch |err| return err;
    makeDirIfMissing(paths.data_dir) catch |err| return err;
    makeDirIfMissing(paths.state_dir) catch |err| return err;

    ensureDefaultConfig(paths.config_file) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const file = try std.fs.openFileAbsolute(paths.config_file, .{});
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(source);

    const cfg = try parseConfig(allocator, source);
    return .{
        .allocator = allocator,
        .paths = paths,
        .config = cfg,
    };
}

fn resolvePaths(allocator: std.mem.Allocator) !Paths {
    const home = std.posix.getenv("HOME") orelse return error.MissingHomeDirectory;
    const config_base = std.posix.getenv("XDG_CONFIG_HOME") orelse blk: {
        break :blk try std.fs.path.join(allocator, &.{ home, ".config" });
    };
    defer if (std.posix.getenv("XDG_CONFIG_HOME") == null) allocator.free(config_base);

    const cache_base = std.posix.getenv("XDG_CACHE_HOME") orelse blk: {
        break :blk try std.fs.path.join(allocator, &.{ home, ".cache" });
    };
    defer if (std.posix.getenv("XDG_CACHE_HOME") == null) allocator.free(cache_base);

    const data_base = std.posix.getenv("XDG_DATA_HOME") orelse blk: {
        break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share" });
    };
    defer if (std.posix.getenv("XDG_DATA_HOME") == null) allocator.free(data_base);

    const state_base = std.posix.getenv("XDG_STATE_HOME") orelse blk: {
        break :blk try std.fs.path.join(allocator, &.{ home, ".local", "state" });
    };
    defer if (std.posix.getenv("XDG_STATE_HOME") == null) allocator.free(state_base);

    const app_name = "zzyinyue";
    const config_dir = try std.fs.path.join(allocator, &.{ config_base, app_name });
    const cache_dir = try std.fs.path.join(allocator, &.{ cache_base, app_name });
    const data_dir = try std.fs.path.join(allocator, &.{ data_base, app_name });
    const state_dir = try std.fs.path.join(allocator, &.{ state_base, app_name });

    return .{
        .config_dir = config_dir,
        .cache_dir = cache_dir,
        .data_dir = data_dir,
        .state_dir = state_dir,
        .config_file = try std.fs.path.join(allocator, &.{ config_dir, "config.toml" }),
        .database_file = try std.fs.path.join(allocator, &.{ data_dir, "library.sqlite3" }),
        .state_file = try std.fs.path.join(allocator, &.{ state_dir, "session.json" }),
    };
}

fn freePaths(allocator: std.mem.Allocator, paths: Paths) void {
    allocator.free(paths.config_dir);
    allocator.free(paths.cache_dir);
    allocator.free(paths.data_dir);
    allocator.free(paths.state_dir);
    allocator.free(paths.config_file);
    allocator.free(paths.database_file);
    allocator.free(paths.state_file);
}

fn makeDirIfMissing(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
}

fn ensureDefaultConfig(config_file: []const u8) !void {
    const home = std.posix.getenv("HOME") orelse return error.MissingHomeDirectory;
    const music_root = try std.fs.path.join(std.heap.page_allocator, &.{ home, "Music" });
    defer std.heap.page_allocator.free(music_root);

    const default_contents = try std.fmt.allocPrint(
        std.heap.page_allocator,
        \\# ZZYinYue configuration
        \\music_roots = ["{s}"]
        \\animations = true
        \\scan_on_startup = true
        \\
    ,
        .{music_root},
    );
    defer std.heap.page_allocator.free(default_contents);

    const file = try std.fs.createFileAbsolute(config_file, .{ .exclusive = true });
    defer file.close();
    try file.writeAll(default_contents);
}

fn parseConfig(allocator: std.mem.Allocator, source: []const u8) !Config {
    var music_roots = std.ArrayList([]const u8).empty;
    errdefer {
        for (music_roots.items) |root| allocator.free(root);
        music_roots.deinit(allocator);
    }

    var animations = true;
    var scan_on_startup = true;

    var lines = std.mem.tokenizeAny(u8, source, "\r\n");
    while (lines.next()) |line_raw| {
        const line = trimComment(std.mem.trim(u8, line_raw, " \t"));
        if (line.len == 0) continue;

        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfigLine;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t");
        const value = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");

        if (std.mem.eql(u8, key, "music_roots")) {
            for (music_roots.items) |root| allocator.free(root);
            music_roots.clearRetainingCapacity();

            var parsed = try parseStringArray(allocator, value);
            defer parsed.deinit(allocator);
            try music_roots.appendSlice(allocator, parsed.items);
            parsed.clearAndFree(allocator);
        } else if (std.mem.eql(u8, key, "animations")) {
            animations = try parseBool(value);
        } else if (std.mem.eql(u8, key, "scan_on_startup")) {
            scan_on_startup = try parseBool(value);
        }
    }

    if (music_roots.items.len == 0) return error.MissingMusicRoots;

    return .{
        .music_roots = try music_roots.toOwnedSlice(allocator),
        .animations = animations,
        .scan_on_startup = scan_on_startup,
    };
}

fn trimComment(line: []const u8) []const u8 {
    var in_string = false;
    for (line, 0..) |char, idx| {
        if (char == '"') in_string = !in_string;
        if (!in_string and char == '#') return std.mem.trimRight(u8, line[0..idx], " \t");
    }
    return line;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidBoolean;
}

fn parseString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') {
        return error.InvalidString;
    }
    return allocator.dupe(u8, value[1 .. value.len - 1]);
}

fn parseStringArray(allocator: std.mem.Allocator, value: []const u8) !std.ArrayList([]const u8) {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') {
        return error.InvalidArray;
    }

    var result = std.ArrayList([]const u8).empty;
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit(allocator);
    }

    var inner = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    while (inner.len > 0) {
        const comma_idx = findArraySeparator(inner) orelse inner.len;
        const part = std.mem.trim(u8, inner[0..comma_idx], " \t");
        try result.append(allocator, try parseString(allocator, part));
        if (comma_idx == inner.len) break;
        inner = std.mem.trim(u8, inner[comma_idx + 1 ..], " \t");
    }

    return result;
}

fn findArraySeparator(value: []const u8) ?usize {
    var in_string = false;
    for (value, 0..) |char, idx| {
        if (char == '"') in_string = !in_string;
        if (!in_string and char == ',') return idx;
    }
    return null;
}

test "parseConfig parses expected fields" {
    const allocator = std.testing.allocator;
    const loaded = try parseConfig(
        allocator,
        \\music_roots = ["/music", "/extra"]
        \\animations = false
        \\scan_on_startup = true
    );
    defer {
        for (loaded.music_roots) |root| allocator.free(root);
        allocator.free(loaded.music_roots);
    }

    try std.testing.expectEqual(@as(usize, 2), loaded.music_roots.len);
    try std.testing.expect(!loaded.animations);
    try std.testing.expect(loaded.scan_on_startup);
}

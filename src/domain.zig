const std = @import("std");

pub const PlayMode = enum {
    single_loop,
    playlist_loop,
    playlist_shuffle,

    pub fn next(self: PlayMode) PlayMode {
        return switch (self) {
            .single_loop => .playlist_loop,
            .playlist_loop => .playlist_shuffle,
            .playlist_shuffle => .single_loop,
        };
    }

    pub fn label(self: PlayMode) []const u8 {
        return switch (self) {
            .single_loop => "single",
            .playlist_loop => "loop",
            .playlist_shuffle => "shuffle",
        };
    }
};

pub const PlaylistKind = enum {
    folder,
    artist,
    album,

    pub fn label(self: PlaylistKind) []const u8 {
        return switch (self) {
            .folder => "Folder",
            .artist => "Artist",
            .album => "Album",
        };
    }
};

pub const Track = struct {
    path: []const u8,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    folder: []const u8,
    search_blob: []const u8,
    duration_seconds: f64,
    modified_unix: i64,

    pub fn displayName(self: Track) []const u8 {
        if (self.title.len > 0) return self.title;
        return std.fs.path.basename(self.path);
    }
};

pub const Playlist = struct {
    name: []const u8,
    search_name: []const u8,
    kind: PlaylistKind,
    track_indices: []usize,
};

pub const Library = struct {
    arena: std.heap.ArenaAllocator,
    tracks: []Track,
    playlists: []Playlist,

    pub fn initEmpty(backing_allocator: std.mem.Allocator) Library {
        const arena = std.heap.ArenaAllocator.init(backing_allocator);
        return .{
            .arena = arena,
            .tracks = &.{},
            .playlists = &.{},
        };
    }

    pub fn allocator(self: *Library) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *Library) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn normalizeOwned(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var previous_space = true;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (!previous_space) {
                try out.append(allocator, ' ');
                previous_space = true;
            }
            continue;
        }

        previous_space = false;
        try out.append(allocator, std.ascii.toLower(byte));
    }

    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }

    return out.toOwnedSlice(allocator);
}

pub fn containsNormalized(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.mem.indexOf(u8, haystack, needle) != null;
}

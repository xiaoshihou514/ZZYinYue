//! Persists the scanned library and lightweight playback session state in SQLite.
const std = @import("std");
const domain = @import("domain.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

/// Stores only cross-session playback state, not transient UI navigation.
pub const SessionState = struct {
    play_mode: domain.PlayMode = .playlist_loop,
    current_track_path: []const u8 = "",
    current_position_seconds: f64 = 0.0,
};

/// Thin SQLite wrapper for the cached library and app state tables.
pub const Database = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
        var db_handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        const rc = c.sqlite3_open_v2(path.ptr, &db_handle, flags, null);
        if (rc != c.SQLITE_OK or db_handle == null) return error.OpenDatabaseFailed;

        var db = Database{
            .db = db_handle.?,
            .allocator = allocator,
        };
        errdefer db.close();

        try db.exec(
            \\PRAGMA journal_mode = WAL;
            \\PRAGMA foreign_keys = ON;
            \\CREATE TABLE IF NOT EXISTS tracks (
            \\  path TEXT PRIMARY KEY,
            \\  title TEXT NOT NULL,
            \\  artist TEXT NOT NULL,
            \\  album TEXT NOT NULL,
            \\  folder TEXT NOT NULL,
            \\  search_blob TEXT NOT NULL,
            \\  duration_seconds REAL NOT NULL,
            \\  modified_unix INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS playlists (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  name TEXT NOT NULL,
            \\  search_name TEXT NOT NULL,
            \\  kind TEXT NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS playlist_tracks (
            \\  playlist_id INTEGER NOT NULL,
            \\  track_path TEXT NOT NULL,
            \\  position INTEGER NOT NULL,
            \\  PRIMARY KEY (playlist_id, position),
            \\  FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
            \\  FOREIGN KEY (track_path) REFERENCES tracks(path) ON DELETE CASCADE
            \\);
            \\CREATE TABLE IF NOT EXISTS app_state (
            \\  key TEXT PRIMARY KEY,
            \\  value TEXT NOT NULL
            \\);
        );
        return db;
    }

    pub fn close(self: *Database) void {
        _ = c.sqlite3_close(self.db);
        self.* = undefined;
    }

    pub fn exec(self: *Database, sql: []const u8) !void {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql_z.ptr, null, null, &err_msg);
        defer if (err_msg != null) c.sqlite3_free(err_msg);
        if (rc != c.SQLITE_OK) return error.SqlExecutionFailed;
    }

    pub fn saveLibrary(self: *Database, library: *const domain.Library) !void {
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        try self.exec(
            \\DELETE FROM playlist_tracks;
            \\DELETE FROM playlists;
            \\DELETE FROM tracks;
        );

        const insert_track = try self.prepare(
            \\INSERT INTO tracks (
            \\  path, title, artist, album, folder, search_blob, duration_seconds, modified_unix
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
        );
        defer _ = c.sqlite3_finalize(insert_track);

        for (library.tracks) |track| {
            try bindText(insert_track, 1, track.path);
            try bindText(insert_track, 2, track.title);
            try bindText(insert_track, 3, track.artist);
            try bindText(insert_track, 4, track.album);
            try bindText(insert_track, 5, track.folder);
            try bindText(insert_track, 6, track.search_blob);
            try bindDouble(insert_track, 7, track.duration_seconds);
            try bindInt64(insert_track, 8, track.modified_unix);
            try stepDone(insert_track);
            _ = c.sqlite3_reset(insert_track);
            _ = c.sqlite3_clear_bindings(insert_track);
        }

        const insert_playlist = try self.prepare(
            \\INSERT INTO playlists (name, search_name, kind) VALUES (?1, ?2, ?3);
        );
        defer _ = c.sqlite3_finalize(insert_playlist);

        const insert_playlist_track = try self.prepare(
            \\INSERT INTO playlist_tracks (playlist_id, track_path, position) VALUES (?1, ?2, ?3);
        );
        defer _ = c.sqlite3_finalize(insert_playlist_track);

        for (library.playlists) |playlist| {
            try bindText(insert_playlist, 1, playlist.name);
            try bindText(insert_playlist, 2, playlist.search_name);
            try bindText(insert_playlist, 3, @tagName(playlist.kind));
            try stepDone(insert_playlist);
            _ = c.sqlite3_reset(insert_playlist);
            _ = c.sqlite3_clear_bindings(insert_playlist);

            const playlist_id = c.sqlite3_last_insert_rowid(self.db);
            for (playlist.track_indices, 0..) |track_index, position| {
                try bindInt64(insert_playlist_track, 1, playlist_id);
                try bindText(insert_playlist_track, 2, library.tracks[track_index].path);
                try bindInt64(insert_playlist_track, 3, @intCast(position));
                try stepDone(insert_playlist_track);
                _ = c.sqlite3_reset(insert_playlist_track);
                _ = c.sqlite3_clear_bindings(insert_playlist_track);
            }
        }

        try self.exec("COMMIT;");
    }

    pub fn loadLibrary(self: *Database, allocator: std.mem.Allocator) !domain.Library {
        var library = domain.Library.initEmpty(allocator);
        errdefer library.deinit();
        const arena = library.allocator();

        const track_stmt = try self.prepare(
            \\SELECT path, title, artist, album, folder, search_blob, duration_seconds, modified_unix
            \\FROM tracks
            \\ORDER BY search_blob ASC;
        );
        defer _ = c.sqlite3_finalize(track_stmt);

        var tracks = std.ArrayList(domain.Track).empty;
        defer tracks.deinit(arena);
        var track_map = std.StringHashMap(usize).init(arena);
        defer track_map.deinit();

        while (try stepRow(track_stmt)) {
            const track = domain.Track{
                .path = try dupColumnText(arena, track_stmt, 0),
                .title = try dupColumnText(arena, track_stmt, 1),
                .artist = try dupColumnText(arena, track_stmt, 2),
                .album = try dupColumnText(arena, track_stmt, 3),
                .folder = try dupColumnText(arena, track_stmt, 4),
                .search_blob = try dupColumnText(arena, track_stmt, 5),
                .duration_seconds = c.sqlite3_column_double(track_stmt, 6),
                .modified_unix = c.sqlite3_column_int64(track_stmt, 7),
            };
            try tracks.append(arena, track);
            try track_map.put(track.path, tracks.items.len - 1);
        }
        library.tracks = try tracks.toOwnedSlice(arena);

        const playlist_stmt = try self.prepare(
            \\SELECT id, name, search_name, kind
            \\FROM playlists
            \\ORDER BY kind ASC, search_name ASC;
        );
        defer _ = c.sqlite3_finalize(playlist_stmt);

        const membership_stmt = try self.prepare(
            \\SELECT track_path
            \\FROM playlist_tracks
            \\WHERE playlist_id = ?1
            \\ORDER BY position ASC;
        );
        defer _ = c.sqlite3_finalize(membership_stmt);

        var playlists = std.ArrayList(domain.Playlist).empty;
        defer playlists.deinit(arena);

        while (try stepRow(playlist_stmt)) {
            const playlist_id = c.sqlite3_column_int64(playlist_stmt, 0);
            const kind_name = columnText(playlist_stmt, 3);
            const kind = std.meta.stringToEnum(domain.PlaylistKind, kind_name) orelse .folder;

            try bindInt64(membership_stmt, 1, playlist_id);

            var indices = std.ArrayList(usize).empty;
            defer indices.deinit(arena);
            while (try stepRow(membership_stmt)) {
                const path = columnText(membership_stmt, 0);
                if (track_map.get(path)) |track_index| {
                    try indices.append(arena, track_index);
                }
            }
            _ = c.sqlite3_reset(membership_stmt);
            _ = c.sqlite3_clear_bindings(membership_stmt);

            try playlists.append(arena, .{
                .name = try dupColumnText(arena, playlist_stmt, 1),
                .search_name = try dupColumnText(arena, playlist_stmt, 2),
                .kind = kind,
                .track_indices = try indices.toOwnedSlice(arena),
            });
        }

        library.playlists = try playlists.toOwnedSlice(arena);
        return library;
    }

    pub fn saveSessionState(self: *Database, state: SessionState) !void {
        const statement = try self.prepare(
            \\INSERT INTO app_state (key, value) VALUES (?1, ?2)
            \\ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        );
        defer _ = c.sqlite3_finalize(statement);

        const items = [_]struct { key: []const u8, value: []const u8 }{
            .{ .key = "play_mode", .value = state.play_mode.label() },
            .{ .key = "current_track_path", .value = state.current_track_path },
        };

        for (items) |item| {
            try bindText(statement, 1, item.key);
            try bindText(statement, 2, item.value);
            try stepDone(statement);
            _ = c.sqlite3_reset(statement);
            _ = c.sqlite3_clear_bindings(statement);
        }

        const position = try std.fmt.allocPrint(self.allocator, "{d}", .{state.current_position_seconds});
        defer self.allocator.free(position);
        try bindText(statement, 1, "current_position_seconds");
        try bindText(statement, 2, position);
        try stepDone(statement);

        try self.exec("DELETE FROM app_state WHERE key = 'selected_playlist_name';");
    }

    pub fn loadSessionState(self: *Database, allocator: std.mem.Allocator) !SessionState {
        const stmt = try self.prepare("SELECT key, value FROM app_state;");
        defer _ = c.sqlite3_finalize(stmt);

        var state = SessionState{
            .current_track_path = try allocator.dupe(u8, ""),
        };
        errdefer {
            allocator.free(state.current_track_path);
        }

        while (try stepRow(stmt)) {
            const key = columnText(stmt, 0);
            const value = columnText(stmt, 1);
            if (std.mem.eql(u8, key, "play_mode")) {
                if (std.mem.eql(u8, value, "single")) state.play_mode = .single_loop;
                if (std.mem.eql(u8, value, "loop")) state.play_mode = .playlist_loop;
                if (std.mem.eql(u8, value, "shuffle")) state.play_mode = .playlist_shuffle;
            } else if (std.mem.eql(u8, key, "current_track_path")) {
                allocator.free(state.current_track_path);
                state.current_track_path = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "current_position_seconds")) {
                state.current_position_seconds = std.fmt.parseFloat(f64, value) catch 0.0;
            }
        }

        return state;
    }

    fn prepare(self: *Database, sql: []const u8) !*c.sqlite3_stmt {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK or stmt == null) {
            return error.PrepareFailed;
        }
        return stmt.?;
    }
};

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) {
        return error.BindFailed;
    }
}

fn bindInt64(stmt: *c.sqlite3_stmt, index: c_int, value: i64) !void {
    if (c.sqlite3_bind_int64(stmt, index, value) != c.SQLITE_OK) {
        return error.BindFailed;
    }
}

fn bindDouble(stmt: *c.sqlite3_stmt, index: c_int, value: f64) !void {
    if (c.sqlite3_bind_double(stmt, index, value) != c.SQLITE_OK) {
        return error.BindFailed;
    }
}

fn stepDone(stmt: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
}

fn stepRow(stmt: *c.sqlite3_stmt) !bool {
    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_ROW) return true;
    if (rc == c.SQLITE_DONE) return false;
    return error.StepFailed;
}

fn columnText(stmt: *c.sqlite3_stmt, index: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, index);
    if (ptr == null) return "";
    return std.mem.span(ptr);
}

fn dupColumnText(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, index: c_int) ![]const u8 {
    return allocator.dupe(u8, columnText(stmt, index));
}

test "session state ignores legacy playlist selection" {
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.close();

    try db.exec(
        \\INSERT INTO app_state (key, value) VALUES ('selected_playlist_name', '旧列表');
        \\INSERT INTO app_state (key, value) VALUES ('play_mode', 'shuffle');
        \\INSERT INTO app_state (key, value) VALUES ('current_track_path', '/tmp/demo.flac');
        \\INSERT INTO app_state (key, value) VALUES ('current_position_seconds', '12.5');
    );

    const loaded = try db.loadSessionState(std.testing.allocator);
    defer std.testing.allocator.free(loaded.current_track_path);

    try std.testing.expectEqual(domain.PlayMode.playlist_shuffle, loaded.play_mode);
    try std.testing.expectEqualStrings("/tmp/demo.flac", loaded.current_track_path);
    try std.testing.expectEqual(@as(f64, 12.5), loaded.current_position_seconds);

    try db.saveSessionState(.{
        .play_mode = .single_loop,
        .current_track_path = "/tmp/other.flac",
        .current_position_seconds = 3.25,
    });

    const reloaded = try db.loadSessionState(std.testing.allocator);
    defer std.testing.allocator.free(reloaded.current_track_path);

    try std.testing.expectEqual(domain.PlayMode.single_loop, reloaded.play_mode);
    try std.testing.expectEqualStrings("/tmp/other.flac", reloaded.current_track_path);
    try std.testing.expectEqual(@as(f64, 3.25), reloaded.current_position_seconds);
}

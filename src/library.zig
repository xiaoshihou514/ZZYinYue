const std = @import("std");
const domain = @import("domain.zig");
const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/dict.h");
    @cInclude("libavutil/avutil.h");
});

pub const ScanSummary = struct {
    library: domain.Library,
    scanned_files: usize,
    metadata_failures: usize,
};

pub const ScanProgress = struct {
    context: *anyopaque,
    on_file: *const fn (ctx: *anyopaque, path: []const u8) void,
    should_cancel: *const fn (ctx: *anyopaque) bool,
};

const PlaylistBucket = struct {
    kind: domain.PlaylistKind,
    indices: std.ArrayList(usize),
};

const TrackDraft = struct {
    path: []const u8,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    folder: []const u8,
    search_blob: []const u8,
    duration_seconds: f64,
    modified_unix: i64,

    fn deinit(self: *TrackDraft, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.title);
        allocator.free(self.artist);
        allocator.free(self.album);
        allocator.free(self.folder);
        allocator.free(self.search_blob);
        self.* = undefined;
    }
};

pub fn scan(
    allocator: std.mem.Allocator,
    music_roots: []const []const u8,
    progress: ?*ScanProgress,
) !ScanSummary {
    var library = domain.Library.initEmpty(allocator);
    errdefer library.deinit();

    var paths = std.ArrayList([]u8).empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    for (music_roots) |root| {
        try collectAudioPaths(allocator, &paths, root, progress);
    }

    const probe_result = try probeTracksParallel(paths.items, progress);
    var drafts = probe_result.tracks;
    defer {
        for (drafts.items) |*draft| draft.deinit(std.heap.page_allocator);
        drafts.deinit(std.heap.page_allocator);
    }

    const arena = library.allocator();
    var tracks = std.ArrayList(domain.Track).empty;
    defer tracks.deinit(arena);

    for (drafts.items) |draft| {
        try tracks.append(arena, .{
            .path = try arena.dupe(u8, draft.path),
            .title = try arena.dupe(u8, draft.title),
            .artist = try arena.dupe(u8, draft.artist),
            .album = try arena.dupe(u8, draft.album),
            .folder = try arena.dupe(u8, draft.folder),
            .search_blob = try arena.dupe(u8, draft.search_blob),
            .duration_seconds = draft.duration_seconds,
            .modified_unix = draft.modified_unix,
        });
    }

    std.mem.sort(domain.Track, tracks.items, {}, sortTracks);

    library.tracks = try tracks.toOwnedSlice(arena);
    library.playlists = try buildPlaylists(arena, library.tracks);

    return .{
        .library = library,
        .scanned_files = library.tracks.len,
        .metadata_failures = probe_result.metadata_failures,
    };
}

fn probeTracksParallel(
    paths: []const []u8,
    progress: ?*ScanProgress,
) !struct {
    tracks: std.ArrayList(TrackDraft),
    metadata_failures: usize,
} {
    const allocator = std.heap.page_allocator;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const worker_count = @max(@as(usize, 1), cpu_count);

    const workers = try allocator.alloc(WorkerContext, worker_count);
    defer allocator.free(workers);

    var shared = SharedQueue{
        .paths = paths,
        .progress = progress,
    };

    for (workers, 0..) |*worker, idx| {
        worker.* = .{
            .id = idx,
            .shared = &shared,
            .tracks = std.ArrayList(TrackDraft).empty,
        };
    }

    var threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    for (workers, 0..) |*worker, idx| {
        threads[idx] = try std.Thread.spawn(.{}, workerMain, .{worker});
    }
    for (threads) |thread| thread.join();

    if (shared.first_error) |err| return err;
    if (isCancelled(&shared)) return error.ScanCancelled;

    var merged = std.ArrayList(TrackDraft).empty;
    errdefer {
        for (merged.items) |*draft| draft.deinit(allocator);
        merged.deinit(allocator);
    }

    const total_count = blk: {
        var total: usize = 0;
        for (workers) |worker| total += worker.tracks.items.len;
        break :blk total;
    };
    try merged.ensureTotalCapacity(allocator, total_count);

    for (workers) |*worker| {
        for (worker.tracks.items) |draft| {
            try merged.append(allocator, draft);
        }
        worker.tracks.clearRetainingCapacity();
        worker.tracks.deinit(allocator);
    }
    return .{
        .tracks = merged,
        .metadata_failures = shared.metadata_failures,
    };
}

const SharedQueue = struct {
    mutex: std.Thread.Mutex = .{},
    paths: []const []u8,
    progress: ?*ScanProgress,
    next_index: usize = 0,
    metadata_failures: usize = 0,
    first_error: ?anyerror = null,
};

const WorkerContext = struct {
    id: usize,
    shared: *SharedQueue,
    tracks: std.ArrayList(TrackDraft),
};

fn workerMain(ctx: *WorkerContext) void {
    const allocator = std.heap.page_allocator;

    while (true) {
        const work = nextPath(ctx.shared) orelse return;
        const draft = probeTrackDraft(allocator, work.path) catch blk: {
            ctx.shared.mutex.lock();
            ctx.shared.metadata_failures += 1;
            ctx.shared.mutex.unlock();

            break :blk fallbackTrackDraft(allocator, work.path) catch |err| {
                ctx.shared.mutex.lock();
                if (ctx.shared.first_error == null) ctx.shared.first_error = err;
                ctx.shared.mutex.unlock();
                return;
            };
        };

        if (isCancelled(ctx.shared)) {
            var draft_mut = draft;
            draft_mut.deinit(allocator);
            return;
        }

        ctx.tracks.append(allocator, draft) catch |err| {
            var draft_mut = draft;
            draft_mut.deinit(allocator);
            ctx.shared.mutex.lock();
            if (ctx.shared.first_error == null) ctx.shared.first_error = err;
            ctx.shared.mutex.unlock();
            return;
        };

        if (ctx.shared.progress) |callback| {
            callback.on_file(callback.context, work.path);
        }
    }
}

fn nextPath(shared: *SharedQueue) ?struct { path: []const u8 } {
    shared.mutex.lock();
    defer shared.mutex.unlock();
    if (shared.first_error != null) return null;
    if (isCancelled(shared)) return null;
    if (shared.next_index >= shared.paths.len) return null;
    const index = shared.next_index;
    shared.next_index += 1;
    return .{ .path = shared.paths[index] };
}

fn collectAudioPaths(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList([]u8),
    absolute_path: []const u8,
    progress: ?*const ScanProgress,
) !void {
    var dir = try std.fs.openDirAbsolute(absolute_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (progressCancelled(progress)) return error.ScanCancelled;
        if (entry.kind != .file) continue;
        if (!isAudioFile(entry.basename)) continue;

        const full_path = try std.fs.path.join(allocator, &.{ absolute_path, entry.path });
        try paths.append(allocator, full_path);
    }
}

fn probeTrackDraft(allocator: std.mem.Allocator, path: []const u8) !TrackDraft {
    const stat = try statAbsolute(path);
    const metadata = try readMetadata(allocator, path);
    defer metadata.deinit(allocator);

    const title = if (metadata.title.len > 0)
        try allocator.dupe(u8, metadata.title)
    else
        try defaultTitle(allocator, path);
    const artist = try allocator.dupe(u8, metadata.artist);
    const album = try allocator.dupe(u8, metadata.album);

    const folder = try allocator.dupe(u8, folderName(path));
    const search_blob = try buildSearchBlob(allocator, title, artist, album, folder, path);

    return .{
        .path = try allocator.dupe(u8, path),
        .title = title,
        .artist = artist,
        .album = album,
        .folder = folder,
        .search_blob = search_blob,
        .duration_seconds = metadata.duration_seconds,
        .modified_unix = @intCast(stat.mtime),
    };
}

fn fallbackTrackDraft(allocator: std.mem.Allocator, path: []const u8) !TrackDraft {
    const stat = try statAbsolute(path);
    const title = try defaultTitle(allocator, path);
    const folder = try allocator.dupe(u8, folderName(path));
    return .{
        .path = try allocator.dupe(u8, path),
        .title = title,
        .artist = try allocator.dupe(u8, ""),
        .album = try allocator.dupe(u8, ""),
        .folder = folder,
        .search_blob = try buildSearchBlob(allocator, title, "", "", folder, path),
        .duration_seconds = 0.0,
        .modified_unix = @intCast(stat.mtime),
    };
}

fn defaultTitle(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const basename = std.fs.path.basename(path);
    const ext = std.fs.path.extension(basename);
    if (ext.len > 0 and basename.len > ext.len) {
        return allocator.dupe(u8, basename[0 .. basename.len - ext.len]);
    }
    return allocator.dupe(u8, basename);
}

fn statAbsolute(path: []const u8) !std.fs.File.Stat {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.stat();
}

fn folderName(path: []const u8) []const u8 {
    const maybe_dir = std.fs.path.dirname(path) orelse return "";
    return std.fs.path.basename(maybe_dir);
}

fn buildSearchBlob(
    allocator: std.mem.Allocator,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    folder: []const u8,
    path: []const u8,
) ![]const u8 {
    const raw = try std.fmt.allocPrint(allocator, "{s} {s} {s} {s} {s}", .{
        title,
        artist,
        album,
        folder,
        std.fs.path.basename(path),
    });
    defer allocator.free(raw);
    return domain.normalizeOwned(allocator, raw);
}

fn isAudioFile(name: []const u8) bool {
    return matchesExt(name, ".mp3") or
        matchesExt(name, ".flac") or
        matchesExt(name, ".ogg") or
        matchesExt(name, ".opus") or
        matchesExt(name, ".m4a") or
        matchesExt(name, ".aac") or
        matchesExt(name, ".wav") or
        matchesExt(name, ".mp4");
}

fn matchesExt(name: []const u8, ext: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ext);
}

fn isCancelled(shared: *const SharedQueue) bool {
    if (shared.progress) |progress| {
        return progress.should_cancel(progress.context);
    }
    return false;
}

fn progressCancelled(progress: ?*const ScanProgress) bool {
    if (progress) |callback| return callback.should_cancel(callback.context);
    return false;
}

fn sortTracks(_: void, lhs: domain.Track, rhs: domain.Track) bool {
    return std.mem.lessThan(u8, lhs.search_blob, rhs.search_blob);
}

fn buildPlaylists(allocator: std.mem.Allocator, tracks: []const domain.Track) ![]domain.Playlist {
    var buckets = std.StringArrayHashMap(PlaylistBucket).init(allocator);
    defer {
        var it = buckets.iterator();
        while (it.next()) |entry| entry.value_ptr.indices.deinit(allocator);
        buckets.deinit();
    }

    for (tracks, 0..) |track, idx| {
        try addPlaylistTrack(allocator, &buckets, track.folder, .folder, idx);
        if (track.artist.len > 0) try addPlaylistTrack(allocator, &buckets, track.artist, .artist, idx);
        if (track.album.len > 0) try addPlaylistTrack(allocator, &buckets, track.album, .album, idx);
    }

    var playlists = std.ArrayList(domain.Playlist).empty;
    defer playlists.deinit(allocator);

    var it = buckets.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const bucket = entry.value_ptr;
        const name = try allocator.dupe(u8, key);
        const search_name = try domain.normalizeOwned(allocator, key);
        try playlists.append(allocator, .{
            .name = name,
            .search_name = search_name,
            .kind = bucket.kind,
            .track_indices = try bucket.indices.toOwnedSlice(allocator),
        });
    }

    std.mem.sort(domain.Playlist, playlists.items, {}, sortPlaylists);
    return playlists.toOwnedSlice(allocator);
}

fn addPlaylistTrack(
    allocator: std.mem.Allocator,
    buckets: *std.StringArrayHashMap(PlaylistBucket),
    name: []const u8,
    kind: domain.PlaylistKind,
    index: usize,
) !void {
    const entry = try buckets.getOrPut(name);
    if (!entry.found_existing) {
        entry.key_ptr.* = try allocator.dupe(u8, name);
        entry.value_ptr.* = .{
            .kind = kind,
            .indices = std.ArrayList(usize).empty,
        };
    }
    try entry.value_ptr.indices.append(allocator, index);
}

fn sortPlaylists(_: void, lhs: domain.Playlist, rhs: domain.Playlist) bool {
    const kind_order_l = @intFromEnum(lhs.kind);
    const kind_order_r = @intFromEnum(rhs.kind);
    if (kind_order_l != kind_order_r) return kind_order_l < kind_order_r;
    return std.mem.lessThan(u8, lhs.search_name, rhs.search_name);
}

const Metadata = struct {
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    duration_seconds: f64,

    fn deinit(self: Metadata, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.artist);
        allocator.free(self.album);
    }
};

fn readMetadata(allocator: std.mem.Allocator, path: []const u8) !Metadata {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var format_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(&format_ctx, path_z.ptr, null, null) < 0) return error.FfprobeFailed;
    defer c.avformat_close_input(&format_ctx);

    const ctx = format_ctx orelse return error.FfprobeFailed;
    if (c.avformat_find_stream_info(ctx, null) < 0) return error.FfprobeFailed;

    const title = try dupMetadataValue(allocator, ctx.metadata, "title");
    const artist = try dupMetadataValue(allocator, ctx.metadata, "artist");
    const album = try dupMetadataValue(allocator, ctx.metadata, "album");

    var duration_seconds: f64 = 0.0;
    if (ctx.duration > 0) {
        duration_seconds = @as(f64, @floatFromInt(ctx.duration)) / @as(f64, c.AV_TIME_BASE);
    }

    return .{
        .title = title,
        .artist = artist,
        .album = album,
        .duration_seconds = duration_seconds,
    };
}

fn dupMetadataValue(allocator: std.mem.Allocator, dict: ?*c.AVDictionary, key: [:0]const u8) ![]const u8 {
    if (dict == null) return allocator.dupe(u8, "");
    const entry = c.av_dict_get(dict, key.ptr, null, 0);
    if (entry == null or entry.*.value == null) return allocator.dupe(u8, "");
    return allocator.dupe(u8, std.mem.span(entry.*.value));
}

test "buildPlaylists creates folder and metadata playlists" {
    var lib = domain.Library.initEmpty(std.testing.allocator);
    defer lib.deinit();

    const arena = lib.allocator();
    lib.tracks = try arena.alloc(domain.Track, 2);
    lib.tracks[0] = .{
        .path = try arena.dupe(u8, "/music/A/a.mp3"),
        .title = try arena.dupe(u8, "Song A"),
        .artist = try arena.dupe(u8, "Artist X"),
        .album = try arena.dupe(u8, "Album X"),
        .folder = try arena.dupe(u8, "A"),
        .search_blob = try arena.dupe(u8, "song a artist x album x a"),
        .duration_seconds = 10,
        .modified_unix = 1,
    };
    lib.tracks[1] = .{
        .path = try arena.dupe(u8, "/music/B/b.mp3"),
        .title = try arena.dupe(u8, "Song B"),
        .artist = try arena.dupe(u8, "Artist X"),
        .album = try arena.dupe(u8, "Album Y"),
        .folder = try arena.dupe(u8, "B"),
        .search_blob = try arena.dupe(u8, "song b artist x album y b"),
        .duration_seconds = 10,
        .modified_unix = 1,
    };

    const playlists = try buildPlaylists(arena, lib.tracks);
    try std.testing.expect(playlists.len >= 5);
}

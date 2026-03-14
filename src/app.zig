const std = @import("std");
const vaxis = @import("vaxis");

const config = @import("config.zig");
const domain = @import("domain.zig");
const library_mod = @import("library.zig");
const playback = @import("playback.zig");
const storage = @import("storage.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    tick,
    scan_complete,
    scan_failed,
};

const EventLoop = vaxis.Loop(Event);

const FocusPane = enum {
    queue,
    browser,
};

const RelatedViewKind = enum {
    artist,
    folder,
};

const RightPaneMode = enum {
    songs,
    artist,
    playlists,
    help,

    fn label(self: RightPaneMode) []const u8 {
        return switch (self) {
            .songs => "歌曲",
            .artist => "关联",
            .playlists => "播放列表",
            .help => "帮助",
        };
    }

    fn toggleBrowse(self: RightPaneMode) RightPaneMode {
        return switch (self) {
            .songs => .playlists,
            .playlists => .songs,
            .artist => .songs,
            .help => .songs,
        };
    }
};

const SortMode = enum {
    alphabetical,
    modified_time,

    fn label(self: SortMode) []const u8 {
        return switch (self) {
            .alphabetical => "alpha",
            .modified_time => "mtime",
        };
    }

    fn next(self: SortMode) SortMode {
        return switch (self) {
            .alphabetical => .modified_time,
            .modified_time => .alphabetical,
        };
    }
};

const FilteredPlaylist = struct {
    name: []const u8,
    kind_label: []const u8,
    track_indices: []const usize,
};

pub fn run(allocator: std.mem.Allocator) !void {
    var model = try Model.init(allocator);
    defer model.deinit();

    try model.run();
}

const Model = struct {
    allocator: std.mem.Allocator,
    loaded_config: config.Loaded,
    database: storage.Database,
    library: domain.Library,
    playback: playback.Controller,
    session_state: storage.SessionState,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    loop: EventLoop,
    buffer: [1024]u8,
    timer_thread: ?std.Thread = null,
    scanner_thread: ?std.Thread = null,
    quitting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    dirty: bool = true,
    selected_playlist: usize = 0,
    selected_track: usize = 0,
    song_view_selected_track: usize = 0,
    song_view_selected_track_path: []const u8,
    selected_queue: usize = 0,
    playlist_scroll: usize = 0,
    track_scroll: usize = 0,
    song_view_track_scroll: usize = 0,
    queue_scroll: usize = 0,
    focus: FocusPane = .browser,
    search_mode: bool = false,
    right_pane_mode: RightPaneMode = .songs,
    sort_mode: SortMode = .modified_time,
    sort_reverse: bool = false,
    search_query: std.ArrayList(u8),
    normalized_query: []const u8,
    artist_view_name: []const u8,
    related_view_kind: RelatedViewKind = .artist,
    spinner_frame: usize = 0,
    status_message: std.ArrayList(u8),
    scan_state: ScanState = .idle,
    scan_shared: ScanShared = .{},
    winsize_ready: bool = false,

    const ScanState = enum {
        idle,
        scanning,
        applied,
        failed,
    };

    const ScanShared = struct {
        mutex: std.Thread.Mutex = .{},
        scanned_files: usize = 0,
        metadata_failures: usize = 0,
        pending_result: ?*library_mod.ScanSummary = null,
        error_message: ?[]u8 = null,
    };

    fn init(allocator: std.mem.Allocator) !*Model {
        const loaded_config = try config.loadOrCreate(allocator);
        errdefer {
            var cfg = loaded_config;
            cfg.deinit();
        }

        var database = try storage.Database.open(allocator, loaded_config.paths.database_file);
        errdefer database.close();

        var library = database.loadLibrary(allocator) catch domain.Library.initEmpty(allocator);
        errdefer library.deinit();

        var player = try playback.Controller.init(allocator);
        errdefer player.deinit();

        const session_state = database.loadSessionState(allocator) catch storage.SessionState{
            .current_track_path = try allocator.dupe(u8, ""),
        };

        player.setPlayMode(session_state.play_mode);

        const self = try allocator.create(Model);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .loaded_config = loaded_config,
            .database = database,
            .library = library,
            .playback = player,
            .session_state = session_state,
            .tty = undefined,
            .vx = try vaxis.init(allocator, .{
                .kitty_keyboard_flags = .{
                    .report_events = true,
                },
            }),
            .loop = undefined,
            .buffer = undefined,
            .search_query = std.ArrayList(u8).empty,
            .normalized_query = try allocator.dupe(u8, ""),
            .artist_view_name = try allocator.dupe(u8, ""),
            .song_view_selected_track_path = try allocator.dupe(u8, ""),
            .status_message = std.ArrayList(u8).empty,
        };
        errdefer self.vx.deinit(allocator, self.tty.writer());

        self.tty = try vaxis.Tty.init(&self.buffer);
        self.loop = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };

        try self.rebuildSearchQuery();
        try self.reconcileVisibleState();
        if (self.library.tracks.len > 0) {
            try self.setStatusFmt("已加载缓存曲库（{d} 首）", .{self.library.tracks.len});
        } else {
            try self.setStatus("就绪");
        }
        return self;
    }

    fn deinit(self: *Model) void {
        self.quitting.store(true, .release);
        if (self.timer_thread) |thread| thread.join();
        if (self.scanner_thread) |thread| thread.join();

        self.persistSession() catch {};

        self.status_message.deinit(self.allocator);
        self.allocator.free(self.normalized_query);
        self.allocator.free(self.artist_view_name);
        self.allocator.free(self.song_view_selected_track_path);
        self.search_query.deinit(self.allocator);

        self.allocator.free(self.session_state.current_track_path);

        self.playback.deinit();
        self.library.deinit();
        self.database.close();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.loaded_config.deinit();

        if (self.scan_shared.pending_result) |result| {
            result.library.deinit();
            self.allocator.destroy(result);
        }
        if (self.scan_shared.error_message) |message| self.allocator.free(message);

        self.allocator.destroy(self);
    }

    fn run(self: *Model) !void {
        try self.loop.start();
        defer self.loop.stop();

        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.queryTerminal(self.tty.writer(), std.time.ns_per_s);
        try self.vx.setMouseMode(self.tty.writer(), false);

        if (!self.vx.state.in_band_resize) {
            try self.loop.init();
        }

        self.timer_thread = try std.Thread.spawn(.{}, timerMain, .{self});

        if (self.loaded_config.config.scan_on_startup and self.library.tracks.len == 0) {
            try self.startScan();
        }

        while (!self.quitting.load(.acquire)) {
            const event = self.loop.nextEvent();
            try self.handleEvent(event);
            if (self.dirty and self.winsize_ready) try self.render();
        }
    }

    fn timerMain(self: *Model) void {
        while (!self.quitting.load(.acquire)) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            if (self.quitting.load(.acquire)) break;
            _ = self.loop.tryPostEvent(.tick);
        }
    }

    fn handleEvent(self: *Model, event: Event) !void {
        switch (event) {
            .winsize => |ws| {
                try self.vx.resize(self.allocator, self.tty.writer(), ws);
                self.winsize_ready = true;
                self.dirty = true;
            },
            .key_press => |key| try self.handleKey(key),
            .tick => try self.handleTick(),
            .scan_complete => try self.applyScanResult(),
            .scan_failed => try self.applyScanFailure(),
            .focus_in, .focus_out => self.dirty = true,
        }
    }

    fn handleTick(self: *Model) !void {
        self.spinner_frame +%= 1;
        try self.playback.poll();
        if (self.playback.takeLastError()) |message| {
            defer self.allocator.free(message);
            try self.setStatus(message);
            self.dirty = true;
        }
        if (self.playback.currentQueueIndex()) |idx| self.selected_queue = idx;
        if (self.scan_state == .scanning or self.playback.is_playing) self.dirty = true;
    }

    fn handleKey(self: *Model, key: vaxis.Key) !void {
        if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
            self.quitting.store(true, .release);
            return;
        }

        if (self.search_mode) {
            try self.handleSearchKey(key);
            return;
        }

        if (isEscapeKey(key)) {
            try self.handleEscapeKey();
            return;
        }

        if (key.matches('?', .{})) {
            self.right_pane_mode = if (self.right_pane_mode == .help) .songs else .help;
            self.dirty = true;
            return;
        }

        if (key.matches('/', .{})) {
            if (self.right_pane_mode == .help) return;
            self.search_mode = true;
            try self.setStatus("开始编辑搜索");
            self.dirty = true;
            return;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            self.focus = if (self.focus == .queue) .browser else .queue;
            self.dirty = true;
            return;
        }
        if (key.matches('t', .{})) {
            self.right_pane_mode = self.right_pane_mode.toggleBrowse();
            self.dirty = true;
            return;
        }
        if (key.matches('a', .{})) {
            try self.toggleArtistView();
            return;
        }
        if (key.matches('r', .{})) {
            try self.startScan();
            return;
        }
        if (key.matches('m', .{})) {
            const mode = self.playback.cyclePlayMode();
            try self.setStatus(playModeChineseLabel(mode));
            self.dirty = true;
            return;
        }
        if (key.matches('s', .{})) {
            self.sort_mode = self.sort_mode.next();
            try self.setStatusFmt("排序：{s}", .{sortModeChineseLabel(self.sort_mode)});
            self.track_scroll = 0;
            self.dirty = true;
            return;
        }
        if (key.matches('v', .{})) {
            self.sort_reverse = !self.sort_reverse;
            try self.setStatusFmt("倒序：{s}", .{if (self.sort_reverse) "开" else "关"});
            self.track_scroll = 0;
            self.dirty = true;
            return;
        }
        if (key.matches(' ', .{})) {
            try self.playback.togglePause();
            self.dirty = true;
            return;
        }
        if (key.matches('n', .{})) {
            try self.playback.next();
            self.dirty = true;
            return;
        }
        if (key.matches('p', .{})) {
            try self.playback.previous();
            self.dirty = true;
            return;
        }
        if (key.matches('d', .{ .ctrl = true })) {
            try self.pageDown();
            self.dirty = true;
            return;
        }
        if (key.matches('u', .{ .ctrl = true })) {
            try self.pageUp();
            self.dirty = true;
            return;
        }
        if (self.focus == .queue) {
            if (key.matchesAny(&.{ 'j', vaxis.Key.down }, .{})) self.moveQueueSelection(1);
            if (key.matchesAny(&.{ 'k', vaxis.Key.up }, .{})) self.moveQueueSelection(-1);
            if (key.matches(vaxis.Key.enter, .{})) try self.playSelectedQueueItem();
        } else {
            if (self.right_pane_mode == .playlists) {
                if (key.matchesAny(&.{ 'j', vaxis.Key.down }, .{})) self.movePlaylistSelection(1);
                if (key.matchesAny(&.{ 'k', vaxis.Key.up }, .{})) self.movePlaylistSelection(-1);
                if (key.matches(vaxis.Key.enter, .{})) {
                    self.right_pane_mode = .songs;
                    self.selected_track = 0;
                    self.track_scroll = 0;
                }
            } else if (self.right_pane_mode == .songs or self.right_pane_mode == .artist) {
                if (key.matchesAny(&.{ 'j', vaxis.Key.down }, .{})) try self.moveTrackSelection(1);
                if (key.matchesAny(&.{ 'k', vaxis.Key.up }, .{})) try self.moveTrackSelection(-1);
                if (key.matches(vaxis.Key.enter, .{})) try self.playSelectedTrack();
            }
        }
        self.dirty = true;
    }

    fn handleSearchKey(self: *Model, key: vaxis.Key) !void {
        if (isEscapeKey(key) or key.matches(vaxis.Key.enter, .{})) {
            self.search_mode = false;
            try self.rebuildSearchQuery();
            try self.setStatus("已应用搜索");
            self.dirty = true;
            return;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            self.right_pane_mode = self.right_pane_mode.toggleBrowse();
            try self.rebuildSearchQuery();
            try self.setStatusFmt("搜索目标：{s}", .{self.right_pane_mode.label()});
            self.dirty = true;
            return;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            popLastUtf8Codepoint(&self.search_query);
            try self.rebuildSearchQuery();
            self.dirty = true;
            return;
        }
        if (key.matches('l', .{ .ctrl = true })) {
            self.search_query.clearRetainingCapacity();
            try self.rebuildSearchQuery();
            self.dirty = true;
            return;
        }
        if (key.text) |text| {
            if (text.len > 0 and text[0] >= 32) {
                try self.search_query.appendSlice(self.allocator, text);
                try self.rebuildSearchQuery();
                self.dirty = true;
            }
        }
    }

    fn handleEscapeKey(self: *Model) !void {
        if (self.right_pane_mode == .help) {
            self.right_pane_mode = .songs;
            self.focus = .browser;
            try self.setStatus("已退出帮助页");
            self.dirty = true;
            return;
        }
        if (self.right_pane_mode == .artist) {
            try self.clearArtistView();
            self.right_pane_mode = .songs;
            self.focus = .browser;
            try self.restoreSongViewPosition();
            try self.setStatus("已返回歌曲视图");
            self.dirty = true;
            return;
        }
        if (self.right_pane_mode == .playlists) {
            self.right_pane_mode = .songs;
            self.focus = .browser;
            try self.setStatus("已返回歌曲视图");
            self.dirty = true;
            return;
        }
        if (self.focus == .queue) {
            self.focus = .browser;
            self.dirty = true;
        }
    }

    fn movePlaylistSelection(self: *Model, delta: isize) void {
        const count = self.filteredPlaylistsCount();
        if (count == 0) {
            self.selected_playlist = 0;
            return;
        }
        self.selected_playlist = moveIndex(self.selected_playlist, count, delta);
        self.selected_track = 0;
        self.track_scroll = 0;
    }

    fn moveQueueSelection(self: *Model, delta: isize) void {
        const items = self.playback.queueItems();
        if (items.len == 0) {
            self.selected_queue = 0;
            return;
        }
        self.selected_queue = moveIndex(self.selected_queue, items.len, delta);
    }

    fn moveTrackSelection(self: *Model, delta: isize) !void {
        const visible = try self.visibleTracks();
        defer self.allocator.free(visible);
        if (visible.len == 0) {
            self.selected_track = 0;
            return;
        }
        self.selected_track = moveIndex(self.selected_track, visible.len, delta);
    }

    fn playSelectedQueueItem(self: *Model) !void {
        const items = self.playback.queueItems();
        if (items.len == 0) return;
        try self.playback.playQueueIndex(self.selected_queue);
        try self.setStatus("开始播放队列曲目");
        self.dirty = true;
    }

    fn playSelectedTrack(self: *Model) !void {
        const visible = try self.visibleTracks();
        defer self.allocator.free(visible);
        if (visible.len == 0) return;

        try self.playback.setQueueFromTracks(visible, self.selected_track);
        self.selected_queue = self.selected_track;
        self.queue_scroll = 0;
        try self.setStatus("开始播放");
        self.dirty = true;
    }

    fn toggleArtistView(self: *Model) !void {
        if (self.focus != .browser or self.right_pane_mode == .help or self.right_pane_mode == .playlists) return;
        if (self.right_pane_mode == .artist) {
            try self.clearArtistView();
            self.right_pane_mode = .songs;
            try self.restoreSongViewPosition();
            try self.setStatus("已返回歌曲视图");
            self.dirty = true;
            return;
        }

        const visible = try self.visibleTracks();
        defer self.allocator.free(visible);
        if (visible.len == 0) return;

        const selected = visible[@min(self.selected_track, visible.len - 1)];
        try self.captureSongViewPosition(selected.path);
        if (selected.artist.len > 0) {
            try self.setArtistView(selected.artist);
            self.related_view_kind = .artist;
            try self.setStatusFmt("关联视图：作者 {s}", .{selected.artist});
        } else {
            const folder_path = std.fs.path.dirname(selected.path) orelse "";
            if (folder_path.len == 0) {
                try self.setStatus("当前歌曲没有可用的目录范围");
                self.dirty = true;
                return;
            }
            try self.setArtistView(folder_path);
            self.related_view_kind = .folder;
            try self.setStatusFmt("关联视图：目录 {s}", .{std.fs.path.basename(folder_path)});
        }
        self.right_pane_mode = .artist;
        self.selected_track = 0;
        self.track_scroll = 0;
        self.dirty = true;
    }

    fn startScan(self: *Model) !void {
        if (self.scan_state == .scanning) return;
        if (self.scanner_thread) |thread| {
            thread.join();
            self.scanner_thread = null;
        }
        self.scan_state = .scanning;
        self.scan_shared.scanned_files = 0;
        self.scan_shared.metadata_failures = 0;
        try self.setStatus(if (self.library.tracks.len == 0) "正在扫描音乐库" else "正在增量重载曲库");
        self.dirty = true;
        self.scanner_thread = try std.Thread.spawn(.{}, scanMain, .{self});
    }

    fn scanMain(self: *Model) void {
        const result = blk: {
            var progress = library_mod.ScanProgress{
                .context = self,
                .on_file = scanProgressCallback,
                .should_cancel = scanShouldCancel,
            };
            break :blk if (self.library.tracks.len == 0)
                library_mod.scan(self.allocator, self.loaded_config.config.music_roots, &progress)
            else
                library_mod.refreshIncremental(self.allocator, &self.library, self.loaded_config.config.music_roots, &progress);
        };

        if (result) |scan| {
            const boxed = self.allocator.create(library_mod.ScanSummary) catch return;
            boxed.* = scan;

            self.scan_shared.mutex.lock();
            defer self.scan_shared.mutex.unlock();
            self.scan_shared.pending_result = boxed;
            self.scan_shared.metadata_failures = scan.metadata_failures;
            _ = self.loop.tryPostEvent(.scan_complete);
        } else |err| switch (err) {
            error.ScanCancelled => return,
            else => {
            const message = std.fmt.allocPrint(self.allocator, "扫描失败：{}", .{err}) catch return;
            self.scan_shared.mutex.lock();
            defer self.scan_shared.mutex.unlock();
            self.scan_shared.error_message = message;
            _ = self.loop.tryPostEvent(.scan_failed);
            },
        }
    }

    fn scanProgressCallback(ctx: *anyopaque, _: []const u8) void {
        const self: *Model = @ptrCast(@alignCast(ctx));
        self.scan_shared.mutex.lock();
        self.scan_shared.scanned_files += 1;
        self.scan_shared.mutex.unlock();
    }

    fn scanShouldCancel(ctx: *anyopaque) bool {
        const self: *Model = @ptrCast(@alignCast(ctx));
        return self.quitting.load(.acquire);
    }

    fn applyScanResult(self: *Model) !void {
        if (self.scanner_thread) |thread| {
            thread.join();
            self.scanner_thread = null;
        }

        self.scan_shared.mutex.lock();
        const result = self.scan_shared.pending_result orelse {
            self.scan_shared.mutex.unlock();
            return;
        };
        self.scan_shared.pending_result = null;
        const metadata_failures = self.scan_shared.metadata_failures;
        self.scan_shared.mutex.unlock();

        const was_empty = self.library.tracks.len == 0;
        const selected_playlist_name = try self.currentPlaylistName();
        defer self.allocator.free(selected_playlist_name);
        self.database.saveLibrary(&result.library) catch {};
        self.library.deinit();
        self.library = result.library;
        self.allocator.destroy(result);

        self.scan_state = .applied;
        self.selected_playlist = self.findPlaylistByName(selected_playlist_name) orelse 0;
        self.selected_track = 0;
        self.playlist_scroll = 0;
        self.track_scroll = 0;
        try self.reconcileVisibleState();
        if (metadata_failures > 0) {
            if (was_empty) {
                try self.setStatusFmt("扫描完成（{d} 首使用回退元数据）", .{metadata_failures});
            } else {
                try self.setStatusFmt("重载完成（{d} 首使用回退元数据）", .{metadata_failures});
            }
        } else {
            try self.setStatus(if (was_empty) "扫描完成" else "重载完成");
        }
        self.dirty = true;
    }

    fn applyScanFailure(self: *Model) !void {
        if (self.scanner_thread) |thread| {
            thread.join();
            self.scanner_thread = null;
        }

        self.scan_shared.mutex.lock();
        const message = self.scan_shared.error_message orelse "扫描失败";
        self.scan_shared.error_message = null;
        self.scan_shared.mutex.unlock();

        defer if (message.ptr != "扫描失败".ptr) self.allocator.free(message);
        self.scan_state = .failed;
        try self.setStatus(message);
        self.dirty = true;
    }

    fn render(self: *Model) !void {
        var frame_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer frame_arena.deinit();
        const frame_alloc = frame_arena.allocator();

        const root = self.vx.window();
        root.clear();
        root.hideCursor();

        const screen_width = self.vx.screen.width;
        const screen_height = self.vx.screen.height;

        if (screen_height < 8 or screen_width < 50) {
            _ = root.print(&.{seg("终端窗口太小", styleSelected())}, .{
                .row_offset = 1,
                .col_offset = 2,
                .wrap = .none,
            });
            try self.vx.render(self.tty.writer());
            self.dirty = false;
            return;
        }

        try self.drawHeader(frame_alloc, root, screen_width);

        const header_h: u16 = 3;
        const footer_h: u16 = 1;
        const body_y = header_h;
        const body_h = screen_height - header_h - footer_h;
        const queue_w = @max(screen_width / 3, 28);
        const browser_w = screen_width - queue_w;

        const queue_outer = root.child(.{
            .y_off = body_y,
            .width = queue_w,
            .height = body_h,
            .border = .{
                .where = .all,
                .style = paneBorderStyle(self.focus == .queue),
            },
        });
        const browser_outer = root.child(.{
            .x_off = @intCast(queue_w),
            .y_off = body_y,
            .width = browser_w,
            .height = body_h,
            .border = .{
                .where = .all,
                .style = paneBorderStyle(self.focus == .browser),
            },
        });

        try self.drawQueue(frame_alloc, queue_outer);
        switch (self.right_pane_mode) {
            .songs => try self.drawTracks(frame_alloc, browser_outer),
            .artist => try self.drawTracks(frame_alloc, browser_outer),
            .playlists => try self.drawPlaylists(frame_alloc, browser_outer),
            .help => try self.drawHelpPage(frame_alloc, browser_outer),
        }
        try self.drawPaneTitleBoxes(frame_alloc, root, body_y, queue_w, browser_w);
        try self.drawFooter(frame_alloc, root, screen_width, screen_height);

        try self.vx.render(self.tty.writer());
        self.dirty = false;
    }

    fn drawHeader(self: *Model, frame_alloc: std.mem.Allocator, root: vaxis.Window, width: u16) !void {
        const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
        self.scan_shared.mutex.lock();
        const scanned_files = self.scan_shared.scanned_files;
        self.scan_shared.mutex.unlock();
        const scan_label = switch (self.scan_state) {
            .idle, .applied => "空闲",
            .scanning => spinner[self.spinner_frame % spinner.len],
            .failed => "错误",
        };
        const visible_files = if (self.scan_state == .scanning) scanned_files else self.library.tracks.len;
        const title = try std.fmt.allocPrint(frame_alloc, "自在音乐 {s} 已加载{d}文件", .{
            scan_label,
            visible_files,
        });
        _ = root.print(&.{seg(title, .{ .bold = true })}, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });

        const search_prefix = "搜索：";
        const search_target = if (self.right_pane_mode == .help) "帮助页" else self.right_pane_mode.label();
        const search_raw = try std.fmt.allocPrint(frame_alloc, "{s}[{s}] {s}", .{
            search_prefix,
            search_target,
            self.search_query.items,
        });
        const search_line = try clipText(frame_alloc, search_raw, width);
        _ = root.print(&.{seg(search_line, if (self.search_mode) styleSelected() else styleMuted())}, .{
            .row_offset = 1,
            .col_offset = 0,
            .wrap = .none,
        });

    }

    fn drawQueue(self: *Model, frame_alloc: std.mem.Allocator, win: vaxis.Window) !void {
        const items = self.playback.queueItems();
        const rows = contentRows(win);
        const current_idx = self.playback.currentQueueIndex();
        if (items.len == 0) {
            self.selected_queue = 0;
            const empty = try clipText(frame_alloc, "队列为空", contentWidth(win));
            _ = win.print(&.{seg(empty, styleMuted())}, .{ .row_offset = 1, .col_offset = 0, .wrap = .none });
            return;
        }

        self.selected_queue = @min(self.selected_queue, items.len - 1);
        self.queue_scroll = keepSelectionVisible(self.queue_scroll, self.selected_queue, items.len, rows);

        for (0..rows) |row| {
            const idx = self.queue_scroll + row;
            if (idx >= items.len) break;
            const selected = idx == self.selected_queue and self.focus == .queue;
            if (selected) try paintRowBackground(frame_alloc, win, @intCast(row + 1), styleSelected());
            const label = trackNameByPath(self, items[idx]);
            const marker = if (current_idx != null and idx == current_idx.?) "▶ " else "  ";
            const raw = try std.fmt.allocPrint(frame_alloc, "{s}{s}", .{ marker, label });
            const clipped = try clipText(frame_alloc, raw, contentWidth(win));
            _ = win.print(&.{seg(clipped, if (selected) styleSelected() else .{})}, .{
                .row_offset = @intCast(row + 1),
                .col_offset = 0,
                .wrap = .none,
            });
        }
    }

    fn drawPlaylists(self: *Model, frame_alloc: std.mem.Allocator, win: vaxis.Window) !void {
        const playlists = try self.filteredPlaylists();
        defer self.allocator.free(playlists);

        const rows = contentRows(win);
        self.playlist_scroll = keepSelectionVisible(
            self.playlist_scroll,
            self.selected_playlist,
            playlists.len,
            rows,
        );

        for (0..rows) |row| {
            const idx = self.playlist_scroll + row;
            if (idx >= playlists.len) break;
            const playlist = playlists[idx];
            const selected = idx == self.selected_playlist and self.focus == .browser and self.right_pane_mode == .playlists;
            if (selected) try paintRowBackground(frame_alloc, win, @intCast(row + 1), styleSelected());
            const raw_line = try std.fmt.allocPrint(frame_alloc, "{s} [{s}]", .{
                playlist.name,
                playlist.kind_label,
            });
            const clipped = try clipText(frame_alloc, raw_line, contentWidth(win));
            _ = win.print(&.{seg(clipped, if (selected) styleSelected() else .{})}, .{
                .row_offset = @intCast(row + 1),
                .col_offset = 0,
                .wrap = .none,
            });
        }
    }

    fn drawTracks(self: *Model, frame_alloc: std.mem.Allocator, win: vaxis.Window) !void {
        const tracks = try self.visibleTracks();
        defer self.allocator.free(tracks);

        const rows = contentRows(win);
        const detail_rows: usize = if (rows >= 6) 2 else 0;
        const separator_rows: usize = if (detail_rows > 0) 1 else 0;
        const list_rows = rows -| detail_rows -| separator_rows;
        self.track_scroll = keepSelectionVisible(
            self.track_scroll,
            self.selected_track,
            tracks.len,
            list_rows,
        );

        for (0..list_rows) |row| {
            const idx = self.track_scroll + row;
            if (idx >= tracks.len) break;
            const track = tracks[idx];
            const selected = idx == self.selected_track and self.focus == .browser and (self.right_pane_mode == .songs or self.right_pane_mode == .artist);
            if (selected) try paintRowBackground(frame_alloc, win, @intCast(row + 1), styleSelected());
            const line = try formatTrackLine(frame_alloc, track, contentWidth(win), true);
            _ = win.print(&.{seg(line.left, if (selected) styleSelected() else .{})}, .{
                .row_offset = @intCast(row + 1),
                .col_offset = 0,
                .wrap = .none,
            });
            if (line.right.len > 0) {
                const col = durationColumn(win, line.right);
                _ = win.print(&.{seg(line.right, if (selected) styleSelected() else styleMuted())}, .{
                    .row_offset = @intCast(row + 1),
                    .col_offset = col,
                    .wrap = .none,
                });
            }
        }

        if (detail_rows > 0) try self.drawSelectedTrackDetails(frame_alloc, win, tracks, list_rows);
    }

    fn drawFooter(self: *Model, frame_alloc: std.mem.Allocator, root: vaxis.Window, width: u16, height: u16) !void {
        const current_path = self.playback.currentPath();
        const state_icon = if (!self.playback.is_playing and current_path.len == 0)
            "[]"
        else if (self.playback.paused)
            "[暂停]"
        else
            "[播放]";

        const song_name = self.currentTrackDisplayName();
        const line1_raw = try std.fmt.allocPrint(frame_alloc, "{s} {s}  模式:{s}  {s}", .{
            state_icon,
            song_name,
            playModeChineseLabel(self.playback.play_mode),
            try self.progressText(frame_alloc),
        });
        const line1 = try clipText(frame_alloc, line1_raw, width);
        _ = root.print(&.{seg(line1, styleFooter(self.playback.paused))}, .{
            .row_offset = height - 1,
            .col_offset = 0,
            .wrap = .none,
        });
    }

    fn drawHelpPage(_: *Model, frame_alloc: std.mem.Allocator, win: vaxis.Window) !void {
        _ = win.print(&.{seg("q 退出    Tab 切换焦点    Enter 确认/播放    空格 暂停", .{})}, .{
            .row_offset = 1,
            .col_offset = 0,
            .wrap = .none,
        });
        _ = win.print(&.{seg("j/k 移动    n/p 下一首/上一首    m 播放模式    r 重扫", .{})}, .{
            .row_offset = 2,
            .col_offset = 0,
            .wrap = .none,
        });
        _ = win.print(&.{seg("/ 编辑搜索（帮助页禁用）    s 切换排序    v 倒序    t 切换歌曲/列表", .{})}, .{
            .row_offset = 3,
            .col_offset = 0,
            .wrap = .none,
        });
        _ = win.print(&.{seg("a 关联歌曲/返回    ? 进入/离开帮助页", .{})}, .{
            .row_offset = 4,
            .col_offset = 0,
            .wrap = .none,
        });
        _ = win.print(&.{seg("Ctrl-D/Ctrl-U 翻页    Esc 返回/结束搜索    Ctrl-L 清空搜索", .{})}, .{
            .row_offset = 5,
            .col_offset = 0,
            .wrap = .none,
        });
        _ = win.print(&.{seg("左侧：播放队列    右侧：歌曲 / 播放列表 / 帮助", styleMuted())}, .{
            .row_offset = 7,
            .col_offset = 0,
            .wrap = .none,
        });
        const note = try clipText(frame_alloc, "搜索框固定在顶部；高亮覆盖整行；退格按 UTF-8 字符删除。", contentWidth(win));
        _ = win.print(&.{seg(note, styleMuted())}, .{
            .row_offset = 8,
            .col_offset = 0,
            .wrap = .none,
        });
    }

    fn filteredPlaylists(self: *Model) ![]FilteredPlaylist {
        var playlists = std.ArrayList(FilteredPlaylist).empty;
        errdefer playlists.deinit(self.allocator);

        if (self.shouldIncludePlaylist("全部歌曲")) {
            try playlists.append(self.allocator, .{
                .name = "全部歌曲",
                .kind_label = "全部",
                .track_indices = &.{},
            });
        }

        for (self.library.playlists) |playlist| {
            if (!self.shouldIncludePlaylist(playlist.search_name)) continue;
            try playlists.append(self.allocator, .{
                .name = playlist.name,
                .kind_label = playlist.kind.label(),
                .track_indices = playlist.track_indices,
            });
        }

        if (playlists.items.len == 0 and self.right_pane_mode != .playlists) {
            try playlists.append(self.allocator, .{
                .name = "全部歌曲",
                .kind_label = "全部",
                .track_indices = &.{},
            });
        }

        if (playlists.items.len == 0) {
            self.selected_playlist = 0;
        } else {
            self.selected_playlist = @min(self.selected_playlist, playlists.items.len - 1);
        }
        return playlists.toOwnedSlice(self.allocator);
    }

    fn filteredPlaylistsCount(self: *Model) usize {
        const filtered = self.filteredPlaylists() catch return 1;
        defer self.allocator.free(filtered);
        return filtered.len;
    }

    fn visibleTracks(self: *Model) ![]domain.Track {
        if (self.right_pane_mode == .artist) {
            var artist_tracks = std.ArrayList(domain.Track).empty;
            errdefer artist_tracks.deinit(self.allocator);

            for (self.library.tracks) |track| {
                if (!self.trackMatchesArtistView(track)) continue;
                if (!self.shouldIncludeTrack(track)) continue;
                try artist_tracks.append(self.allocator, track);
            }

            self.sortTracks(artist_tracks.items);
            if (artist_tracks.items.len == 0) {
                self.selected_track = 0;
            } else {
                self.selected_track = @min(self.selected_track, artist_tracks.items.len - 1);
            }
            return artist_tracks.toOwnedSlice(self.allocator);
        }

        const playlists = try self.filteredPlaylists();
        defer self.allocator.free(playlists);
        if (playlists.len == 0) return self.allocator.alloc(domain.Track, 0);

        const selection = @min(self.selected_playlist, playlists.len - 1);
        const playlist = playlists[selection];

        var visible = std.ArrayList(domain.Track).empty;
        errdefer visible.deinit(self.allocator);

        if (std.mem.eql(u8, playlist.kind_label, "全部")) {
            for (self.library.tracks) |track| {
                if (self.shouldIncludeTrack(track)) {
                    try visible.append(self.allocator, track);
                }
            }
        } else {
            for (playlist.track_indices) |track_index| {
                const track = self.library.tracks[track_index];
                if (self.shouldIncludeTrack(track)) {
                    try visible.append(self.allocator, track);
                }
            }
        }

        self.sortTracks(visible.items);

        if (visible.items.len == 0) {
            self.selected_track = 0;
        } else {
            self.selected_track = @min(self.selected_track, visible.items.len - 1);
        }
        return visible.toOwnedSlice(self.allocator);
    }

    fn shouldIncludePlaylist(self: *Model, normalized_name: []const u8) bool {
        if (self.right_pane_mode != .playlists) return true;
        return domain.containsNormalized(normalized_name, self.normalized_query);
    }

    fn shouldIncludeTrack(self: *Model, track: domain.Track) bool {
        if (self.right_pane_mode != .songs and self.right_pane_mode != .artist) return true;
        return domain.containsNormalized(track.search_blob, self.normalized_query);
    }

    fn trackMatchesArtistView(self: *Model, track: domain.Track) bool {
        if (self.artist_view_name.len == 0) return false;
        return switch (self.related_view_kind) {
            .artist => std.mem.eql(u8, track.artist, self.artist_view_name) or
                std.ascii.eqlIgnoreCase(track.artist, self.artist_view_name),
            .folder => blk: {
                const folder_path = std.fs.path.dirname(track.path) orelse "";
                break :blk std.mem.eql(u8, folder_path, self.artist_view_name);
            },
        };
    }

    fn sortTracks(self: *Model, tracks: []domain.Track) void {
        const context = TrackSortContext{
            .mode = self.sort_mode,
            .reverse = self.sort_reverse,
        };
        std.mem.sort(domain.Track, tracks, context, TrackSortContext.lessThan);
    }

    fn currentTrackDisplayName(self: *Model) []const u8 {
        const path = self.playback.currentPath();
        if (path.len == 0) return "未在播放";

        for (self.library.tracks) |track| {
            if (std.mem.eql(u8, track.path, path)) return track.displayName();
        }
        return std.fs.path.basename(path);
    }

    fn progressText(self: *Model, frame_alloc: std.mem.Allocator) ![]const u8 {
        const current = formatDuration(frame_alloc, self.playback.current_position_seconds) catch "00:00";
        const total = formatDuration(frame_alloc, self.playback.current_duration_seconds) catch "--:--";

        if (self.playback.current_duration_seconds <= 0.0) {
            return std.fmt.allocPrint(frame_alloc, "{s}/{s}", .{ current, total });
        }

        const ratio = std.math.clamp(
            self.playback.current_position_seconds / self.playback.current_duration_seconds,
            0.0,
            1.0,
        );
        const bar_width: usize = 16;
        const filled = @min(bar_width, @as(usize, @intFromFloat(@round(ratio * @as(f64, @floatFromInt(bar_width))))));
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(frame_alloc);
        try buffer.append(frame_alloc, '[');
        for (0..bar_width) |idx| {
            try buffer.append(frame_alloc, if (idx < filled) '#' else '-');
        }
        try buffer.append(frame_alloc, ']');
        const bar = try buffer.toOwnedSlice(frame_alloc);
        return std.fmt.allocPrint(frame_alloc, "{s} {s}/{s}", .{ bar, current, total });
    }

    fn findPlaylistByName(self: *Model, name: []const u8) ?usize {
        const playlists = self.filteredPlaylists() catch return null;
        defer self.allocator.free(playlists);
        if (name.len == 0) return if (playlists.len > 0) 0 else null;
        for (playlists, 0..) |playlist, idx| {
            if (std.mem.eql(u8, playlist.name, name)) return idx;
        }
        return if (playlists.len > 0) 0 else null;
    }

    fn rebuildSearchQuery(self: *Model) !void {
        self.allocator.free(self.normalized_query);
        self.normalized_query = try domain.normalizeOwned(self.allocator, self.search_query.items);
        self.selected_playlist = 0;
        self.selected_track = 0;
        self.playlist_scroll = 0;
        self.track_scroll = 0;
    }

    fn reconcileVisibleState(self: *Model) !void {
        const initial_tracks = try self.visibleTracks();
        defer self.allocator.free(initial_tracks);
        if (initial_tracks.len > 0 or self.library.tracks.len == 0) return;

        if (self.right_pane_mode == .artist) {
            try self.clearArtistView();
            self.right_pane_mode = .songs;
            try self.restoreSongViewPosition();
            const artist_fallback = try self.visibleTracks();
            defer self.allocator.free(artist_fallback);
            if (artist_fallback.len > 0) return;
        }

        self.selected_playlist = 0;
        self.selected_track = 0;
        self.playlist_scroll = 0;
        self.track_scroll = 0;

        const fallback_tracks = try self.visibleTracks();
        defer self.allocator.free(fallback_tracks);
        if (fallback_tracks.len > 0) return;

        if (self.right_pane_mode == .playlists) {
            self.right_pane_mode = .songs;
            self.selected_playlist = 0;
            self.selected_track = 0;
            self.playlist_scroll = 0;
            self.track_scroll = 0;
        }

        const songs_scope_tracks = try self.visibleTracks();
        defer self.allocator.free(songs_scope_tracks);
        if (songs_scope_tracks.len > 0) return;

        self.search_query.clearRetainingCapacity();
        self.allocator.free(self.normalized_query);
        self.normalized_query = try self.allocator.dupe(u8, "");
        self.selected_playlist = 0;
        self.selected_track = 0;
        self.playlist_scroll = 0;
        self.track_scroll = 0;
    }

    fn persistSession(self: *Model) !void {
        self.allocator.free(self.session_state.current_track_path);

        self.session_state = .{
            .play_mode = self.playback.play_mode,
            .current_track_path = try self.allocator.dupe(u8, self.playback.currentPath()),
            .current_position_seconds = self.playback.current_position_seconds,
        };
        try self.database.saveSessionState(self.session_state);
    }

    fn setStatus(self: *Model, message: []const u8) !void {
        self.status_message.clearRetainingCapacity();
        try self.status_message.appendSlice(self.allocator, message);
    }

    fn setStatusFmt(self: *Model, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(message);
        try self.setStatus(message);
    }

    fn setArtistView(self: *Model, artist: []const u8) !void {
        self.allocator.free(self.artist_view_name);
        self.artist_view_name = try self.allocator.dupe(u8, artist);
    }

    fn clearArtistView(self: *Model) !void {
        self.allocator.free(self.artist_view_name);
        self.artist_view_name = try self.allocator.dupe(u8, "");
        self.related_view_kind = .artist;
    }

    fn clearSearchQuery(self: *Model) !void {
        self.search_query.clearRetainingCapacity();
        try self.rebuildSearchQuery();
    }

    fn currentPlaylistName(self: *Model) ![]u8 {
        const playlists = try self.filteredPlaylists();
        defer self.allocator.free(playlists);
        if (playlists.len == 0) return self.allocator.dupe(u8, "");
        return self.allocator.dupe(u8, playlists[@min(self.selected_playlist, playlists.len - 1)].name);
    }

    fn drawPaneTitleBoxes(
        self: *Model,
        frame_alloc: std.mem.Allocator,
        root: vaxis.Window,
        body_y: u16,
        queue_w: u16,
        browser_w: u16,
    ) !void {
        const queue_title = try std.fmt.allocPrint(frame_alloc, "播放队列 [{d}]", .{self.playback.queueItems().len});
        try drawPaneTitleBox(frame_alloc, root, 2, body_y -| 1, queue_w -| 4, queue_title, self.focus == .queue);

        const browser_title = try self.browserPaneTitle(frame_alloc);
        try drawPaneTitleBox(
            frame_alloc,
            root,
            queue_w + 2,
            body_y -| 1,
            browser_w -| 4,
            browser_title,
            self.focus == .browser,
        );
    }

    fn browserPaneTitle(self: *Model, frame_alloc: std.mem.Allocator) ![]const u8 {
        return switch (self.right_pane_mode) {
            .songs => blk: {
                const visible = try self.visibleTracks();
                defer self.allocator.free(visible);
                break :blk std.fmt.allocPrint(frame_alloc, "歌曲 [{s}{s} | {d}]", .{
                    sortModeChineseLabel(self.sort_mode),
                    if (self.sort_reverse) " 倒序" else " 正序",
                    visible.len,
                });
            },
            .artist => blk: {
                const visible = try self.visibleTracks();
                defer self.allocator.free(visible);
                const scope_name = switch (self.related_view_kind) {
                    .artist => fallbackText(self.artist_view_name, "未知"),
                    .folder => fallbackText(std.fs.path.basename(self.artist_view_name), "当前目录"),
                };
                const scope_kind = switch (self.related_view_kind) {
                    .artist => "作者",
                    .folder => "目录",
                };
                break :blk std.fmt.allocPrint(frame_alloc, "关联：{s} {s} [{d}]", .{
                    scope_kind,
                    scope_name,
                    visible.len,
                });
            },
            .playlists => std.fmt.allocPrint(frame_alloc, "播放列表 [{d}]", .{self.filteredPlaylistsCount()}),
            .help => frame_alloc.dupe(u8, "按键帮助"),
        };
    }

    fn captureSongViewPosition(self: *Model, selected_path: []const u8) !void {
        self.song_view_selected_track = self.selected_track;
        self.song_view_track_scroll = self.track_scroll;
        self.allocator.free(self.song_view_selected_track_path);
        self.song_view_selected_track_path = try self.allocator.dupe(u8, selected_path);
    }

    fn restoreSongViewPosition(self: *Model) !void {
        self.selected_track = self.song_view_selected_track;
        self.track_scroll = self.song_view_track_scroll;
        if (self.song_view_selected_track_path.len == 0) return;

        const visible = try self.visibleTracks();
        defer self.allocator.free(visible);
        for (visible, 0..) |track, idx| {
            if (std.mem.eql(u8, track.path, self.song_view_selected_track_path)) {
                self.selected_track = idx;
                break;
            }
        }
    }

    fn pageDown(self: *Model) !void {
        const rows = self.pageStep();
        if (rows == 0) return;
        if (self.focus == .queue) {
            pageSelection(&self.queue_scroll, &self.selected_queue, self.playback.queueItems().len, rows, true);
            return;
        }
        if (self.right_pane_mode == .playlists) {
            pageSelection(&self.playlist_scroll, &self.selected_playlist, self.filteredPlaylistsCount(), rows, true);
            self.selected_track = 0;
            self.track_scroll = 0;
            return;
        }
        if (self.right_pane_mode == .songs or self.right_pane_mode == .artist) {
            const tracks = try self.visibleTracks();
            defer self.allocator.free(tracks);
            pageSelection(&self.track_scroll, &self.selected_track, tracks.len, rows, true);
        }
    }

    fn pageUp(self: *Model) !void {
        const rows = self.pageStep();
        if (rows == 0) return;
        if (self.focus == .queue) {
            pageSelection(&self.queue_scroll, &self.selected_queue, self.playback.queueItems().len, rows, false);
            return;
        }
        if (self.right_pane_mode == .playlists) {
            pageSelection(&self.playlist_scroll, &self.selected_playlist, self.filteredPlaylistsCount(), rows, false);
            self.selected_track = 0;
            self.track_scroll = 0;
            return;
        }
        if (self.right_pane_mode == .songs or self.right_pane_mode == .artist) {
            const tracks = try self.visibleTracks();
            defer self.allocator.free(tracks);
            pageSelection(&self.track_scroll, &self.selected_track, tracks.len, rows, false);
        }
    }

    fn pageStep(self: *const Model) usize {
        if (self.vx.screen.height <= 6) return 1;
        const header_h: usize = 3;
        const footer_h: usize = 1;
        const body_h = self.vx.screen.height -| header_h -| footer_h;
        const content_rows = body_h -| 1;
        if (self.focus == .queue or self.right_pane_mode == .playlists) return @max(@as(usize, 1), content_rows);
        const detail_rows: usize = if (content_rows >= 6) 2 else 0;
        const separator_rows: usize = if (detail_rows > 0) 1 else 0;
        return @max(@as(usize, 1), content_rows -| detail_rows -| separator_rows);
    }

    fn drawSelectedTrackDetails(
        self: *Model,
        frame_alloc: std.mem.Allocator,
        win: vaxis.Window,
        tracks: []const domain.Track,
        list_rows: usize,
    ) !void {
        if (tracks.len == 0) return;

        const selected = tracks[@min(self.selected_track, tracks.len - 1)];
        const separator_row: u16 = @intCast(list_rows + 1);
        const detail_row: u16 = separator_row + 1;
        const label_style: vaxis.Style = if (self.focus == .browser) .{ .bold = true } else styleMuted();
        const value_width = contentWidth(win);

        const separator = try clipText(frame_alloc, "──────────", value_width);
        _ = win.print(&.{seg(separator, styleMuted())}, .{
            .row_offset = separator_row,
            .col_offset = 0,
            .wrap = .none,
        });

        const artist_line = try std.fmt.allocPrint(frame_alloc, "作者：{s}", .{fallbackText(selected.artist, "未知")});
        _ = win.print(&.{seg(try clipText(frame_alloc, artist_line, value_width), label_style)}, .{
            .row_offset = detail_row,
            .col_offset = 0,
            .wrap = .none,
        });

        const album_line = try std.fmt.allocPrint(frame_alloc, "专辑：{s}", .{fallbackText(selected.album, "未知")});
        _ = win.print(&.{seg(try clipText(frame_alloc, album_line, value_width), styleMuted())}, .{
            .row_offset = detail_row + 1,
            .col_offset = 0,
            .wrap = .none,
        });
    }
};

const TrackSortContext = struct {
    mode: SortMode,
    reverse: bool,

    fn lessThan(ctx: TrackSortContext, lhs: domain.Track, rhs: domain.Track) bool {
        const order = switch (ctx.mode) {
            .alphabetical => compareTrackAlphabetical(lhs, rhs),
            .modified_time => compareTrackModifiedTime(lhs, rhs),
        };
        return switch (order) {
            .lt => !ctx.reverse,
            .gt => ctx.reverse,
            .eq => false,
        };
    }
};

fn compareTrackAlphabetical(lhs: domain.Track, rhs: domain.Track) std.math.Order {
    const lhs_name = lhs.displayName();
    const rhs_name = rhs.displayName();
    const order = std.ascii.orderIgnoreCase(lhs_name, rhs_name);
    if (order != .eq) return order;
    return std.mem.order(u8, lhs.path, rhs.path);
}

fn compareTrackModifiedTime(lhs: domain.Track, rhs: domain.Track) std.math.Order {
    if (lhs.modified_unix > rhs.modified_unix) return .lt;
    if (lhs.modified_unix < rhs.modified_unix) return .gt;
    return compareTrackAlphabetical(lhs, rhs);
}

fn moveIndex(current: usize, count: usize, delta: isize) usize {
    if (count == 0) return 0;
    const current_i: isize = @intCast(current);
    const count_i: isize = @intCast(count);
    var next = current_i + delta;
    if (next < 0) next = 0;
    if (next >= count_i) next = count_i - 1;
    return @intCast(next);
}

fn keepSelectionVisible(scroll: usize, selection: usize, total: usize, rows: usize) usize {
    if (rows == 0 or total == 0) return 0;
    var next = scroll;
    if (selection < next) next = selection;
    if (selection >= next + rows) next = selection - rows + 1;
    if (next + rows > total) next = total -| rows;
    return next;
}

fn pageSelection(scroll: *usize, selection: *usize, total: usize, rows: usize, down: bool) void {
    if (rows == 0 or total == 0) {
        scroll.* = 0;
        selection.* = 0;
        return;
    }

    const current_selection = @min(selection.*, total - 1);
    const visible_scroll = keepSelectionVisible(scroll.*, current_selection, total, rows);
    const relative_row = @min(current_selection - visible_scroll, rows - 1);
    const max_scroll = total -| rows;
    const next_scroll = if (down)
        @min(visible_scroll + rows, max_scroll)
    else
        visible_scroll -| rows;

    scroll.* = next_scroll;
    selection.* = next_scroll + @min(relative_row, total - 1 - next_scroll);
}

fn isEscapeKey(key: vaxis.Key) bool {
    return key.matches(vaxis.Key.escape, .{}) or key.matches('[', .{ .ctrl = true });
}

fn contentRows(win: vaxis.Window) usize {
    return if (win.height > 1) win.height - 1 else 0;
}

fn contentWidth(win: vaxis.Window) usize {
    return if (win.width > 1) win.width - 1 else 1;
}

const FormattedTrackLine = struct {
    left: []const u8,
    right: []const u8,
};

fn formatTrackLine(allocator: std.mem.Allocator, track: domain.Track, max_chars: usize, include_duration: bool) !FormattedTrackLine {
    const title = track.displayName();
    const raw = try std.fmt.allocPrint(allocator, "{s}", .{title});

    if (!include_duration) {
        return .{
            .left = try clipText(allocator, raw, max_chars),
            .right = "",
        };
    }

    const duration = if (track.duration_seconds > 0.0)
        try formatDuration(allocator, track.duration_seconds)
    else
        "--:--";
    const duration_len = duration.len;
    const available = max_chars -| (duration_len + 1);
    return .{
        .left = try clipText(allocator, raw, available),
        .right = duration,
    };
}

fn clipText(allocator: std.mem.Allocator, text: []const u8, max_chars: usize) ![]const u8 {
    if (max_chars == 0 or text.len == 0) return "";

    var char_count: usize = 0;
    var byte_index: usize = 0;
    while (byte_index < text.len and char_count < max_chars) {
        const advance = std.unicode.utf8ByteSequenceLength(text[byte_index]) catch 1;
        byte_index = @min(text.len, byte_index + advance);
        char_count += 1;
    }
    if (byte_index >= text.len) return text;

    if (max_chars <= 3) return allocator.dupe(u8, text[0..byte_index]);

    var clipped_count: usize = 0;
    var clipped_index: usize = 0;
    while (clipped_index < text.len and clipped_count < max_chars - 3) {
        const advance = std.unicode.utf8ByteSequenceLength(text[clipped_index]) catch 1;
        clipped_index = @min(text.len, clipped_index + advance);
        clipped_count += 1;
    }
    return std.fmt.allocPrint(allocator, "{s}...", .{text[0..clipped_index]});
}

fn formatDuration(allocator: std.mem.Allocator, seconds_in: f64) ![]const u8 {
    const seconds = if (seconds_in < 0) 0 else @as(u64, @intFromFloat(seconds_in));
    if (seconds >= 3600) {
        const hours = seconds / 3600;
        const minutes = (seconds % 3600) / 60;
        const rem_seconds = seconds % 60;
        return std.fmt.allocPrint(allocator, "{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, rem_seconds });
    }
    const minutes = seconds / 60;
    const rem = seconds % 60;
    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}", .{ minutes, rem });
}

fn seg(text: []const u8, style: vaxis.Style) vaxis.Segment {
    return .{ .text = text, .style = style };
}

fn styleSelected() vaxis.Style {
    return .{
        .fg = .{ .index = 0 },
        .bg = .{ .index = 12 },
        .bold = true,
    };
}

fn styleMuted() vaxis.Style {
    return .{
        .fg = .{ .index = 8 },
    };
}

fn styleFooter(paused: bool) vaxis.Style {
    if (paused) {
        return .{
            .fg = .{ .index = 15 },
            .bg = .{ .index = 4 },
            .bold = true,
        };
    }
    return .{
        .fg = .{ .index = 15 },
        .bold = true,
    };
}

fn paneTitleStyle(_: bool) vaxis.Style {
    return .{ .bold = true };
}

fn paneBorderStyle(active: bool) vaxis.Style {
    if (active) {
        return .{
            .fg = .{ .index = 12 },
            .bold = true,
        };
    }
    return styleMuted();
}

fn drawPaneTitleBox(
    frame_alloc: std.mem.Allocator,
    root: vaxis.Window,
    x: u16,
    y: u16,
    max_width: u16,
    title: []const u8,
    active: bool,
) !void {
    if (max_width <= 4) return;
    const inner_width = @as(usize, @intCast(max_width - 4));
    const clipped = try clipText(frame_alloc, title, inner_width);
    const tab = try std.fmt.allocPrint(frame_alloc, "▊ {s}", .{clipped});
    _ = root.print(&.{seg(tab, paneBorderStyle(active))}, .{
        .row_offset = y,
        .col_offset = x,
        .wrap = .none,
    });
}

fn fallbackText(value: []const u8, fallback: []const u8) []const u8 {
    return if (value.len > 0) value else fallback;
}

fn popLastUtf8Codepoint(buffer: *std.ArrayList(u8)) void {
    if (buffer.items.len == 0) return;
    var idx = buffer.items.len - 1;
    while (idx > 0 and (buffer.items[idx] & 0b1100_0000) == 0b1000_0000) : (idx -= 1) {}
    buffer.shrinkRetainingCapacity(idx);
}

fn paintRowBackground(allocator: std.mem.Allocator, win: vaxis.Window, row: u16, style: vaxis.Style) !void {
    const width = contentWidth(win);
    if (width == 0) return;
    const blanks = try allocator.alloc(u8, width);
    @memset(blanks, ' ');
    _ = win.print(&.{seg(blanks, style)}, .{
        .row_offset = row,
        .col_offset = 0,
        .wrap = .none,
    });
}

fn centeredColumn(width: u16, text: []const u8) u16 {
    const len: u16 = @intCast(@min(text.len, width));
    return (width - len) / 2;
}

fn durationColumn(win: vaxis.Window, duration: []const u8) u16 {
    const width = contentWidth(win);
    const duration_width: usize = @min(duration.len, width);
    return @intCast(width - duration_width);
}

fn trackNameByPath(self: *const Model, path: []const u8) []const u8 {
    for (self.library.tracks) |track| {
        if (std.mem.eql(u8, track.path, path)) return track.displayName();
    }
    return std.fs.path.basename(path);
}

fn playModeChineseLabel(mode: domain.PlayMode) []const u8 {
    return switch (mode) {
        .single_loop => "单曲循环",
        .playlist_loop => "列表循环",
        .playlist_shuffle => "列表随机",
    };
}

fn sortModeChineseLabel(mode: SortMode) []const u8 {
    return switch (mode) {
        .alphabetical => "字母",
        .modified_time => "修改时间",
    };
}

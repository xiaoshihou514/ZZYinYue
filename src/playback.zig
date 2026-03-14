const std = @import("std");
const domain = @import("domain.zig");

const c = @cImport({
    @cInclude("mpv/client.h");
});

pub const Controller = struct {
    allocator: std.mem.Allocator,
    handle: *c.mpv_handle,
    queue: std.ArrayList([]const u8),
    current_index: ?usize = null,
    paused: bool = false,
    is_playing: bool = false,
    current_position_seconds: f64 = 0.0,
    current_duration_seconds: f64 = 0.0,
    play_mode: domain.PlayMode = .playlist_loop,
    status_message: []const u8 = "",
    last_error: ?[]const u8 = null,
    prng: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator) !Controller {
        const handle = c.mpv_create() orelse return error.MpvCreateFailed;
        errdefer c.mpv_terminate_destroy(handle);

        try check(c.mpv_set_option_string(handle, "terminal", "no"));
        try check(c.mpv_set_option_string(handle, "video", "no"));
        try check(c.mpv_set_option_string(handle, "audio-display", "no"));
        try check(c.mpv_set_option_string(handle, "keep-open", "no"));
        try check(c.mpv_initialize(handle));

        return .{
            .allocator = allocator,
            .handle = handle,
            .queue = std.ArrayList([]const u8).empty,
            .prng = std.Random.DefaultPrng.init(@intCast(std.time.microTimestamp())),
        };
    }

    pub fn deinit(self: *Controller) void {
        self.clearError();
        self.clearQueue();
        self.queue.deinit(self.allocator);
        c.mpv_terminate_destroy(self.handle);
        self.* = undefined;
    }

    pub fn setPlayMode(self: *Controller, mode: domain.PlayMode) void {
        self.play_mode = mode;
    }

    pub fn cyclePlayMode(self: *Controller) domain.PlayMode {
        self.play_mode = self.play_mode.next();
        return self.play_mode;
    }

    pub fn setQueueFromTracks(self: *Controller, tracks: []const domain.Track, start_index: usize) !void {
        self.clearQueue();
        for (tracks) |track| {
            try self.queue.append(self.allocator, try self.allocator.dupe(u8, track.path));
        }
        if (self.queue.items.len == 0) return;
        self.current_index = @min(start_index, self.queue.items.len - 1);
        try self.loadCurrent();
    }

    pub fn takeLastError(self: *Controller) ?[]const u8 {
        const message = self.last_error;
        self.last_error = null;
        return message;
    }

    pub fn queueItems(self: *const Controller) []const []const u8 {
        return self.queue.items;
    }

    pub fn currentQueueIndex(self: *const Controller) ?usize {
        return self.current_index;
    }

    pub fn playQueueIndex(self: *Controller, index: usize) !void {
        if (self.queue.items.len == 0) return;
        self.current_index = @min(index, self.queue.items.len - 1);
        try self.loadCurrent();
    }

    pub fn togglePause(self: *Controller) !void {
        var args = [_]?[*:0]const u8{ "cycle", "pause", null };
        try check(c.mpv_command(self.handle, @ptrCast(&args)));
        self.paused = !self.paused;
    }

    pub fn next(self: *Controller) !void {
        if (self.queue.items.len == 0) return;
        if (self.current_index == null) {
            self.current_index = 0;
            return try self.loadCurrent();
        }
        const current = self.current_index.?;
        const next_index = if (current + 1 >= self.queue.items.len) 0 else current + 1;
        self.current_index = next_index;
        try self.loadCurrent();
    }

    pub fn previous(self: *Controller) !void {
        if (self.queue.items.len == 0) return;
        if (self.current_index == null or self.current_index.? == 0) {
            self.current_index = self.queue.items.len - 1;
        } else {
            self.current_index.? -= 1;
        }
        try self.loadCurrent();
    }

    pub fn poll(self: *Controller) !void {
        while (true) {
            const event = c.mpv_wait_event(self.handle, 0);
            if (event == null or event.*.event_id == c.MPV_EVENT_NONE) break;
            switch (event.*.event_id) {
                c.MPV_EVENT_END_FILE => try self.handleEndFile(event),
                c.MPV_EVENT_FILE_LOADED => self.is_playing = true,
                c.MPV_EVENT_SHUTDOWN => self.is_playing = false,
                else => {},
            }
        }

        self.current_position_seconds = getDouble(self.handle, "time-pos") catch self.current_position_seconds;
        self.current_duration_seconds = getDouble(self.handle, "duration") catch self.current_duration_seconds;
        self.paused = getFlag(self.handle, "pause") catch self.paused;
    }

    pub fn currentPath(self: *const Controller) []const u8 {
        if (self.current_index) |index| return self.queue.items[index];
        return "";
    }

    fn handleEndFile(self: *Controller, event: *c.mpv_event) !void {
        const payload_ptr: ?*c.mpv_event_end_file = @ptrCast(@alignCast(event.*.data));
        if (payload_ptr == null) return;
        const payload = payload_ptr.?;
        switch (payload.reason) {
            c.MPV_END_FILE_REASON_EOF => try self.advanceAfterEnd(),
            c.MPV_END_FILE_REASON_ERROR => {
                self.is_playing = false;
                self.current_position_seconds = 0.0;
                self.current_duration_seconds = 0.0;
                try self.setErrorForCurrentTrack(payload.@"error");
            },
            else => {},
        }
    }

    fn advanceAfterEnd(self: *Controller) !void {
        self.is_playing = false;
        self.current_position_seconds = 0.0;
        switch (self.play_mode) {
            .single_loop => try self.loadCurrent(),
            .playlist_loop => try self.next(),
            .playlist_shuffle => {
                if (self.queue.items.len == 0) return;
                const index = if (self.queue.items.len == 1) 0 else self.prng.random().uintLessThan(usize, self.queue.items.len);
                self.current_index = index;
                try self.loadCurrent();
            },
        }
    }

    fn loadCurrent(self: *Controller) !void {
        const index = self.current_index orelse return;
        const path = self.queue.items[index];
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);
        self.clearError();

        var args = [_]?[*:0]const u8{ "loadfile", path_z.ptr, "replace", null };
        try check(c.mpv_command(self.handle, @ptrCast(&args)));

        var unpause_args = [_]?[*:0]const u8{ "set", "pause", "no", null };
        try check(c.mpv_command(self.handle, @ptrCast(&unpause_args)));
        self.is_playing = true;
        self.paused = false;
        self.current_position_seconds = 0.0;
        self.current_duration_seconds = 0.0;
    }

    fn clearError(self: *Controller) void {
        if (self.last_error) |message| self.allocator.free(message);
        self.last_error = null;
    }

    fn setErrorForCurrentTrack(self: *Controller, code: c_int) !void {
        self.clearError();
        const path = self.currentPath();
        self.last_error = try std.fmt.allocPrint(self.allocator, "播放失败：{s} ({s})", .{
            std.fs.path.basename(path),
            c.mpv_error_string(code),
        });
    }

    fn clearQueue(self: *Controller) void {
        for (self.queue.items) |path| self.allocator.free(path);
        self.queue.clearRetainingCapacity();
        self.current_index = null;
    }
};

fn check(code: c_int) !void {
    if (code < 0) return error.MpvFailure;
}

fn getDouble(handle: *c.mpv_handle, property: [:0]const u8) !f64 {
    var value: f64 = 0.0;
    try check(c.mpv_get_property(handle, property.ptr, c.MPV_FORMAT_DOUBLE, &value));
    return value;
}

fn getFlag(handle: *c.mpv_handle, property: [:0]const u8) !bool {
    var value: c_int = 0;
    try check(c.mpv_get_property(handle, property.ptr, c.MPV_FORMAT_FLAG, &value));
    return value != 0;
}

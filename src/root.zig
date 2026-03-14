pub const app = @import("app.zig");
pub const config = @import("config.zig");
pub const domain = @import("domain.zig");
pub const library = @import("library.zig");
pub const playback = @import("playback.zig");
pub const storage = @import("storage.zig");

test {
    _ = app;
    _ = config;
    _ = domain;
    _ = library;
    _ = playback;
    _ = storage;
}

//! Entry point that boots the app with a general-purpose allocator.
const std = @import("std");
const app = @import("ZZYinYue").app;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("memory leak detected");
    }

    try app.run(gpa.allocator());
}

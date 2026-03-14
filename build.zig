//! Builds ZZYinYue and generates the `ui_strings` module directly from JSON.
const std = @import("std");

const UiStringsBuildError = error{
    InvalidTopLevelObject,
    NonStringArrayItem,
    UnsupportedValueType,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const strings_mod = createUiStringsModule(b, target, optimize);

    const lib_mod = b.addModule("ZZYinYue", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addImport("vaxis", vaxis_dep.module("vaxis"));
    lib_mod.addImport("ui_strings", strings_mod);
    lib_mod.linkSystemLibrary("sqlite3", .{});
    lib_mod.linkSystemLibrary("mpv", .{});
    lib_mod.linkSystemLibrary("avformat", .{});
    lib_mod.linkSystemLibrary("avcodec", .{});
    lib_mod.linkSystemLibrary("avutil", .{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("ZZYinYue", lib_mod);
    exe_mod.addImport("vaxis", vaxis_dep.module("vaxis"));
    exe_mod.addImport("ui_strings", strings_mod);
    exe_mod.linkSystemLibrary("sqlite3", .{});
    exe_mod.linkSystemLibrary("mpv", .{});
    exe_mod.linkSystemLibrary("avformat", .{});
    exe_mod.linkSystemLibrary("avcodec", .{});
    exe_mod.linkSystemLibrary("avutil", .{});

    const exe = b.addExecutable(.{
        .name = "zzyinyue",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const lib_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_tests_mod.addImport("vaxis", vaxis_dep.module("vaxis"));
    lib_tests_mod.addImport("ui_strings", strings_mod);
    lib_tests_mod.linkSystemLibrary("sqlite3", .{});
    lib_tests_mod.linkSystemLibrary("mpv", .{});
    lib_tests_mod.linkSystemLibrary("avformat", .{});
    lib_tests_mod.linkSystemLibrary("avcodec", .{});
    lib_tests_mod.linkSystemLibrary("avutil", .{});

    const lib_tests = b.addTest(.{
        .root_module = lib_tests_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
}

fn createUiStringsModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const generated_source = generateUiStringsSource(b.allocator) catch |err| {
        std.debug.panic("failed to generate ui_strings module: {s}", .{@errorName(err)});
    };

    const generated_files = b.addWriteFiles();
    const generated_strings = generated_files.add("ui_strings.zig", generated_source);
    return b.createModule(.{
        .root_source_file = generated_strings,
        .target = target,
        .optimize = optimize,
    });
}

fn generateUiStringsSource(allocator: std.mem.Allocator) anyerror![]u8 {
    const json_source = try std.fs.cwd().readFileAlloc(allocator, "ui_strings.json", 1024 * 1024);
    defer allocator.free(json_source);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_source, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "// Generated from ui_strings.json. Do not edit by hand.\n\n");
    try out.appendSlice(allocator, "pub const Strings = struct {\n");
    switch (parsed.value) {
        .object => |object| try emitObjectEntries(allocator, &out, object, 4),
        else => return UiStringsBuildError.InvalidTopLevelObject,
    }
    try out.appendSlice(allocator, "};\n\npub const strings = Strings{};\n");

    return out.toOwnedSlice(allocator);
}

fn emitObjectEntries(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    object: anytype,
    indent: usize,
) anyerror!void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        try emitConst(allocator, out, entry.key_ptr.*, entry.value_ptr.*, indent);
    }
}

fn emitConst(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    value: std.json.Value,
    indent: usize,
) anyerror!void {
    try appendIndent(allocator, out, indent);
    try out.appendSlice(allocator, "pub const ");
    try appendIdentifier(allocator, out, name);

    switch (value) {
        .string => |text| {
            try out.appendSlice(allocator, " = ");
            try appendZigStringLiteral(allocator, out, text);
            try out.appendSlice(allocator, ";\n");
        },
        .array => |items| {
            try out.appendSlice(allocator, " = [_][]const u8{\n");
            for (items.items) |item| {
                const text = switch (item) {
                    .string => |string_value| string_value,
                    else => return UiStringsBuildError.NonStringArrayItem,
                };
                try appendIndent(allocator, out, indent + 4);
                try appendZigStringLiteral(allocator, out, text);
                try out.appendSlice(allocator, ",\n");
            }
            try appendIndent(allocator, out, indent);
            try out.appendSlice(allocator, "};\n");
        },
        .object => |child| {
            try out.appendSlice(allocator, " = struct {\n");
            try emitObjectEntries(allocator, out, child, indent + 4);
            try appendIndent(allocator, out, indent);
            try out.appendSlice(allocator, "};\n");
        },
        else => return UiStringsBuildError.UnsupportedValueType,
    }
}

fn appendIndent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), indent: usize) anyerror!void {
    var remaining = indent;
    while (remaining > 0) : (remaining -= 1) {
        try out.append(allocator, ' ');
    }
}

fn appendIdentifier(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) anyerror!void {
    if (needsQuotedIdentifier(name)) {
        try out.appendSlice(allocator, "@\"");
        try out.appendSlice(allocator, name);
        try out.append(allocator, '"');
        return;
    }
    try out.appendSlice(allocator, name);
}

fn appendZigStringLiteral(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) anyerror!void {
    try out.append(allocator, '"');
    for (text) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (byte < 32) {
                    var escaped: [4]u8 = undefined;
                    const slice = try std.fmt.bufPrint(&escaped, "\\x{X:0>2}", .{byte});
                    try out.appendSlice(allocator, slice);
                } else {
                    try out.append(allocator, byte);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

fn needsQuotedIdentifier(name: []const u8) bool {
    if (name.len == 0) return true;
    if (!isIdentifierStart(name[0])) return true;
    for (name[1..]) |byte| {
        if (!isIdentifierContinue(byte)) return true;
    }
    return isZigKeyword(name);
}

fn isIdentifierStart(byte: u8) bool {
    return byte == '_' or std.ascii.isAlphabetic(byte);
}

fn isIdentifierContinue(byte: u8) bool {
    return byte == '_' or std.ascii.isAlphanumeric(byte);
}

fn isZigKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "align",       "allowzero",   "and",         "anyframe",   "anytype",
        "asm",         "async",       "await",       "break",      "callconv",
        "catch",       "comptime",    "const",       "continue",   "defer",
        "else",        "enum",        "errdefer",    "error",      "export",
        "extern",      "false",       "fn",          "for",        "if",
        "inline",      "linksection", "noalias",     "noinline",   "nosuspend",
        "null",        "opaque",      "or",          "orelse",     "packed",
        "pub",         "resume",      "return",      "struct",     "suspend",
        "switch",      "test",        "threadlocal", "true",       "try",
        "union",       "unreachable", "usingnamespace",             "var",
        "volatile",    "while",
    };

    for (keywords) |keyword| {
        if (std.mem.eql(u8, keyword, name)) return true;
    }
    return false;
}

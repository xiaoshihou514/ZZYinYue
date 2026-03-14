const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const lib_mod = b.addModule("ZZYinYue", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addImport("vaxis", vaxis_dep.module("vaxis"));
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

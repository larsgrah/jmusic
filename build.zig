const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "jmusic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // GTK4 via pkg-config
    exe.root_module.linkSystemLibrary("gtk4", .{ .preferred_link_mode = .dynamic });

    // miniaudio
    exe.root_module.addCSourceFile(.{
        .file = b.path("deps/miniaudio_impl.c"),
        .flags = &.{ "-std=c99", "-fno-sanitize=undefined" },
    });
    exe.root_module.addIncludePath(b.path("deps"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run jmusic");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.linkSystemLibrary("gtk4", .{ .preferred_link_mode = .dynamic });
    tests.root_module.addCSourceFile(.{
        .file = b.path("deps/miniaudio_impl.c"),
        .flags = &.{ "-std=c99", "-fno-sanitize=undefined" },
    });
    tests.root_module.addIncludePath(b.path("deps"));

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

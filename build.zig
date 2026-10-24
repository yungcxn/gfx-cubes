const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;

    const raylib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    raylib_mod.addIncludePath(b.path("raylib/src"));
    raylib_mod.addIncludePath(b.path("raylib/src/external/glfw/include"));

    const common_flags = [_][]const u8{
        "-std=gnu99",
        "-fno-sanitize=undefined",
        "-DPLATFORM_DESKTOP_GLFW",
        "-DGRAPHICS_API_OPENGL_33",
    };
    const flags: []const []const u8 = switch (os) {
        .linux => &(common_flags ++ [_][]const u8{ "-D_GNU_SOURCE", "-D_GLFW_X11" }),
        .macos => &(common_flags ++ [_][]const u8{"-DGL_SILENCE_DEPRECATION"}),
        else => &common_flags,
    };

    const c_files = [_][]const u8{
        "rcore.c",     "rshapes.c",
        "rtextures.c", "rtext.c",
        "rmodels.c",   "raudio.c",
    };
    raylib_mod.addCSourceFiles(.{
        .root = b.path("raylib/src"),
        .files = &c_files,
        .flags = flags,
    });

    raylib_mod.addCSourceFiles(.{
        .root = b.path("raylib/src"),
        .files = &.{"rglfw.c"},
        .flags = if (os == .macos)
            &(common_flags ++ [_][]const u8{ "-DGL_SILENCE_DEPRECATION", "-x", "objective-c" })
        else
            flags,
    });

    const raylib = b.addLibrary(.{
        .name = "raylib",
        .linkage = .static,
        .root_module = raylib_mod,
    });

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(b.path("raylib/src"));

    const exe = b.addExecutable(.{
        .name = "gfx-cubes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c", .module = translate_c.createModule() },
            },
        }),
    });
    exe.root_module.linkLibrary(raylib);

    switch (os) {
        .linux => {
            exe.root_module.linkSystemLibrary("GL", .{});
            exe.root_module.linkSystemLibrary("X11", .{});
        },
        .macos => {
            inline for (.{ "Foundation", "CoreServices", "CoreGraphics", "AppKit", "IOKit", "OpenGL" }) |fw| {
                exe.root_module.linkFramework(fw, .{});
            }
        },
        .windows => {
            exe.root_module.linkSystemLibrary("opengl32", .{});
            exe.root_module.linkSystemLibrary("gdi32", .{});
            exe.root_module.linkSystemLibrary("winmm", .{});
        },
        else => {},
    }

    exe.use_llvm = true;
    exe.use_lld = true;

    const i = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "../" } } });
    b.getInstallStep().dependOn(&i.step);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the application.");
    run_step.dependOn(&run_exe.step);

    { // https://zigtools.org/zls/guides/build-on-save/
        const exe_check = b.addExecutable(.{
            .name = "gfx-cubes",
            .root_module = exe.root_module,
        });
        const check = b.step("check", "Check if gfx-cubes compiles.");
        check.dependOn(&exe_check.step);
    }
}

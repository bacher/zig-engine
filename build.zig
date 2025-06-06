const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zig_engine",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Deps start

    const zglfw = b.dependency("zglfw", .{
        .target = target,
    });
    exe.root_module.addImport("zglfw", zglfw.module("root"));
    exe.linkLibrary(zglfw.artifact("glfw"));

    @import("zgpu").addLibraryPathsTo(exe);
    const zgpu = b.dependency("zgpu", .{
        .target = target,
    });
    exe.root_module.addImport("zgpu", zgpu.module("root"));
    exe.linkLibrary(zgpu.artifact("zdawn"));

    const zgui = b.dependency("zgui", .{
        .target = target,
        .backend = .glfw_wgpu,
    });
    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));

    const zmath = b.dependency("zmath", .{
        .target = target,
    });
    exe.root_module.addImport("zmath", zmath.module("root"));

    const zstbi = b.dependency("zstbi", .{
        .target = target,
    });
    exe.root_module.addImport("zstbi", zstbi.module("root"));

    const gltf_loader = b.dependency("gltf_loader", .{
        .target = target,
    });
    gltf_loader.module("root").addImport("zstbi", zstbi.module("root"));
    exe.root_module.addImport("gltf_loader", gltf_loader.module("root"));

    // Local modules

    const debug_module = b.addModule("debug", .{
        .root_source_file = b.path("src/modules/debug/debug.zig"),
    });
    debug_module.addImport("zmath", zmath.module("root"));
    exe.root_module.addImport("debug", debug_module);

    // Deps end

    const exe_options = b.addOptions();
    exe.root_module.addOptions("build_options", exe_options);
    const content_path_name = "content";
    exe_options.addOption([]const u8, "content_dir", content_path_name);

    const install_content_step = b.addInstallDirectory(.{
        .source_dir = b.path(content_path_name),
        .install_dir = .{ .custom = "" },
        .install_subdir = b.pathJoin(&.{ "bin", content_path_name }),
    });
    exe.step.dependOn(&install_content_step.step);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.root_module.addImport("zmath", zmath.module("root"));

    const loader_utils_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/loader_utils/utils.zig"),
        .target = target,
        .optimize = optimize,
    });
    loader_utils_unit_tests.root_module.addImport("zmath", zmath.module("root"));
    loader_utils_unit_tests.root_module.addImport("debug", debug_module);

    const space_tree_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/engine/space_tree.zig"),
        .target = target,
        .optimize = optimize,
    });
    space_tree_unit_tests.root_module.addImport("zmath", zmath.module("root"));

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const run_loader_utils_unit_tests = b.addRunArtifact(loader_utils_unit_tests);
    const run_space_tree_unit_tests = b.addRunArtifact(space_tree_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_loader_utils_unit_tests.step);
    test_step.dependOn(&run_space_tree_unit_tests.step);
}

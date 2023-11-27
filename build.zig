const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void
{
	// Standard target options allows the person running `zig build` to choose
	// what target to build for. Here we do not override the defaults, which
	// means any target is allowed, and the default is native. Other options
	// for restricting supported target set are available.
	const target = b.standardTargetOptions(.{});

	// Standard optimization options allow the person running `zig build` to select
	// between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
	// set a preferred release mode, allowing the user to decide how to optimize.
	const optimize = b.standardOptimizeOption(.{});


	// zig dependencies

	const vkzig_dep = b.dependency("vulkan_zig_generated", .{
		// .target = target,
		// .optimize = optimize,
	});
	const vkzig_mod = vkzig_dep.module("vulkan-zig-generated");

	const mach_sysaudio_dep = b.dependency("mach_sysaudio", .{
		.target = target,
		.optimize = optimize,
	});
	const mach_sysaudio_mod = mach_sysaudio_dep.module("mach-sysaudio");


	// main executable

	const exe = b.addExecutable(.{
		.name = "wavepic",
		// In this case the main source file is merely a path, however, in more
		// complicated build scripts, this could be a generated file.
		.root_source_file = .{ .path = "src/main.zig" },
		.target = target,
		.optimize = optimize,
	});

	exe.setVerboseCC(true);
	exe.setVerboseLink(true);


	// link C libs

	dynLinkCDeps(exe);
	exe.linkLibC();

	// add zig dependencies

	exe.addModule("vulkan", vkzig_mod);

	exe.addModule("mach-sysaudio", mach_sysaudio_mod);
	@import("mach_sysaudio").link(mach_sysaudio_dep.builder, exe);


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

	// This creates a build step. It will be visible in the `zig build --help` menu,
	// and can be selected like this: `zig build run`
	// This will evaluate the `run` step rather than the default, which is "install".
	const run_step = b.step("run", "Run the app");
	run_step.dependOn(&run_cmd.step);

	// Creates a step for unit testing. This only builds the test executable
	// but does not run it.
	const unit_tests = b.addTest(.{
		.root_source_file = .{ .path = "src/tests.zig" },
		.target = target,
		.optimize = .Debug,
	});

	dynLinkCDeps(unit_tests);
	unit_tests.linkLibC();

	unit_tests.addModule("vulkan", vkzig_mod);
	
	unit_tests.addModule("mach-sysaudio", mach_sysaudio_mod);
	@import("mach_sysaudio").link(mach_sysaudio_dep.builder, unit_tests);


	const run_unit_tests = b.addRunArtifact(unit_tests);

	// const failure_handler_check = std.Build.Step.Run.StdIo.Check {
	// 	.expect_stderr_match = "[file_io] (warn): FileMap: handleFailure invoked.\n",
	// };
	// run_unit_tests.addCheck(failure_handler_check);
	// run_unit_tests.stdio.check.append(failure_handler_check) catch unreachable;


	// Similar to creating the run step earlier, this exposes a `test` step to
	// the `zig build --help` menu, providing a way for the user to request
	// running the unit tests.
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_unit_tests.step);


	// Advanced tests
	const playback_test = b.addExecutable(.{
		.name = "playback_test",
		.root_source_file = .{ .path = "src/playback_test.zig" },
		.target = target,
		.optimize = optimize,
	});

	playback_test.setVerboseCC(true);
	playback_test.setVerboseLink(true);


	// link C libs

	dynLinkCDeps(playback_test);
	playback_test.linkLibC();

	// add zig dependencies

	playback_test.addModule("vulkan", vkzig_mod);

	playback_test.addModule("mach-sysaudio", mach_sysaudio_mod);
	@import("mach_sysaudio").link(mach_sysaudio_dep.builder, playback_test);

	const run_playback_test = b.addInstallArtifact(playback_test, .{});

	const playback_test_step = b.step("playback_test", "Run playback test");
	playback_test_step.dependOn(&run_playback_test.step);
}

fn dynLinkCDeps(exe: *std.Build.Step.Compile) void
{
	const lib_path = std.os.getenv("DYLD_LIBRARY_PATH");
	if (lib_path) |p|
		exe.addLibraryPath(.{ .path = p});

	const fallback_lib_path = std.os.getenv("DYLD_FALLBACK_LIBRARY_PATH");
	if (fallback_lib_path) |p|
		exe.addLibraryPath(.{ .path = p});

	const fallback_framework_path = std.os.getenv("DYLD_FALLBACK_FRAMEWORK_PATH");
	if (fallback_framework_path) |p|
		exe.addLibraryPath(.{ .path = p});

	exe.linkSystemLibrary2("lz4", .{ .needed = true });

	const c = @import("src/c.zig");
	comptime if (c.LZ4_VERSION_NUMBER < 10904) @compileError("liblz4 >= 1.9.4 needed");
}

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


	// dependencies

	const ffmpeg_dep = b.dependency("ffmpeg", .{
		.target = target,
		.optimize = optimize,
	});

	const vkzig_dep = b.dependency("vulkan_zig", .{
		.registry = @as([]const u8, b.pathFromRoot("./vk.xml")),
	});


	// main executable

	const exe = b.addExecutable(.{
		.name = "wavepic",
		// In this case the main source file is merely a path, however, in more
		// complicated build scripts, this could be a generated file.
		.root_source_file = .{ .path = "src/main.zig" },
		.target = target,
		.optimize = optimize,
	});


	// link C libs

	exe.linkLibrary(ffmpeg_dep.artifact("ffmpeg"));
	exe.linkLibC();

	// exe.addIncludePath(.{ .path = "." });

	exe.setVerboseCC(true);
	exe.setVerboseLink(true);

	// Vulkan bindings

	const vkzig_bindings = vkzig_dep.module("vulkan-zig");
	exe.addModule("vulkan-zig", vkzig_bindings);

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

	// link to already installed ffmpeg libs instead
	// of fetching it separately as a dependency to
	// speed up compilation for testing
	// add later as compilation option?
	// ***
	dynLinkFFmpeg(unit_tests);
	// ***

	// unit_tests.linkLibrary(ffmpeg_dep.artifact("ffmpeg"));
	unit_tests.linkLibC();

	const run_unit_tests = b.addRunArtifact(unit_tests);

	// Similar to creating the run step earlier, this exposes a `test` step to
	// the `zig build --help` menu, providing a way for the user to request
	// running the unit tests.
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_unit_tests.step);
}

// add as option to main compile step later
fn dynLinkFFmpeg(exe: *std.Build.Step.Compile) void
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

	exe.linkSystemLibrary2("avcodec", .{ .needed = true });
	exe.linkSystemLibrary2("avformat", .{ .needed = true });
	exe.linkSystemLibrary2("avutil", .{ .needed = true });
	exe.linkSystemLibrary2("swresample", .{ .needed = true });

	// TODO: check versions of libav
}

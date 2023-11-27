const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const log = std.log.scoped(.playback_test);

const file_io = @import("file_io.zig");
const FileMap = file_io.FileMap;

const playback = @import("playback.zig");

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer assert(gpa.deinit() == .ok);

	const allocator = gpa.allocator();

	try playback.initPlayback(allocator);
	defer playback.deinitPlayback();

	const source = [_]u8{ 0, 1, 2, 3, 4, 5 };

	const player = playback.initPlayer(.{ .slc = &source }, .{}) catch |err| {
		if (err == playback.InitPlayerError.NoDevice) {
			log.warn("Default playback device cannot be accessed from test environment.\n", .{});
			return error.SkipZigTest;
		} else return err;
	};
	defer playback.deinitPlayer(player);

	try player.start();
}

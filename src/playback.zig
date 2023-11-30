//! Call `initPlayback` in main

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const log = std.log.scoped(.sysaudio);

const sysaudio = @import("mach-sysaudio");
const Context = sysaudio.Context;
const Device = sysaudio.Device;
const Player = sysaudio.Player;
const WriteFn = sysaudio.WriteFn;

const file_io = @import("file_io.zig");
const FileMap = file_io.FileMap;


var ctx_allocator: Allocator = undefined;
var ctx: ?Context = null;
pub var players: std.SinglyLinkedList(PlayerContext) = .{}; // Nodes allocated by ctx


pub fn initPlayback(allocator: Allocator) Context.InitError!void {
	@setCold(true);

	ctx_allocator = allocator;
	errdefer ctx_allocator = undefined;

	const context = try Context.init(null, ctx_allocator, .{
		// .deviceChangeFn = deviceChange, // Ignored by most backends?
	});
	ctx = context;
}

pub fn deinitPlayback() void {
	@setCold(true);

	assert(ctx != null);

	var node = players.first;
	while (node != null) {
		node.?.data.player.deinit();
		const next_node = node.?.next;
		players.remove(node.?);
		ctx_allocator.destroy(node.?);
		node = next_node;
	}

	ctx.?.deinit();
	ctx = null;
}

fn deviceChange(_: ?*anyopaque) void {
	const device = while (true) {
		ctx.?.refresh() catch {};
		if(ctx.?.defaultDevice(.playback)) |d| break d;
	};

	var node = players.first;
	while (node != null) : (node = node.?.next) {
		const format = switch (node.?.data.player) {
			inline else => |p| p.format,
		};
		const sample_rate = switch (node.?.data.player) {
			inline else => |p| p.sample_rate,
		};

		node.?.data.player.deinit();

		const stream_options = sysaudio.StreamOptions {
			.format = format,
			.sample_rate = sample_rate,
			.media_role = .music,
			.user_data = &node.data,
		};

		node.?.data.player = ctx.createPlayer(device, basicWriteCallback, stream_options) catch {
			players.remove(node.?);
			ctx_allocator.destroy(node.?);
			log.warn("A player could not be reinitialized after a device change.", .{});
		};
	}
}


pub const PlayerSource = union(enum) {
	map: *FileMap,
	slc: []const u8,
};

const PlayerContext =  struct {
	player: Player = undefined,

	src: PlayerSource,
	pos: usize = 0,
};

pub const PlayerOptions = struct {
	format: sysaudio.Format = .f32,
	sample_rate: u24 = sysaudio.default_sample_rate,
};

pub const InitPlayerError = Context.CreateStreamError || Context.RefreshError || error { NoDevice };
/// Do not call `deinit` on the returned player manually, use `playback.deinitPlayer` for proper cleanup.
pub fn initPlayer(source: PlayerSource, options: PlayerOptions) InitPlayerError!*Player {
	assert(ctx != null);

	try ctx.?.refresh();

	const node = try ctx_allocator.create(@TypeOf(players).Node);
	errdefer ctx_allocator.destroy(node);
	node.*.data = PlayerContext { .src = source };

	const stream_options = sysaudio.StreamOptions {
		.format = options.format,
		.sample_rate = options.sample_rate,
		.media_role = .music,
		.user_data = &node.data,
	};
	const device = ctx.?.defaultDevice(.playback) orelse return InitPlayerError.NoDevice;

	node.data.player = try ctx.?.createPlayer(device, basicWriteCallback, stream_options);

	players.prepend(node);

	return &node.*.data.player;
}

pub fn deinitPlayer(player: *Player) void {
	var node = players.first;
	while (node != null) : (node = node.?.next) {
		if (&node.?.data.player != player) continue;

		node.?.data.player.deinit();
		players.remove(node.?);
		ctx_allocator.destroy(node.?);
		return;
	} else log.warn("Player to deinit not found in 'players' list.\n", .{});
}


pub fn basicWriteCallback(user_data: ?*anyopaque, output: []u8) void {
	const player_ctx: *PlayerContext = @alignCast(@ptrCast(user_data orelse @panic("user data missing")));
	assert(@TypeOf(player_ctx.*) == PlayerContext);

	const format = player_ctx.player.format();
	const frame_size = format.frameSize(@intCast(player_ctx.player.channels().len));

	var i: usize = 0;
	while (i < output.len) : (i += frame_size) {
		sysaudio.convertTo(
			u8,

		);
	}
}


test "Player" {
	const allocator = testing.allocator;

	try initPlayback(allocator);
	defer deinitPlayback();

	const source = [_]u8{ 0, 1, 2, 3, 4, 5 };

	const player = initPlayer(.{ .slc = &source }, .{}) catch |err| {
		if (err == InitPlayerError.NoDevice) {
			log.warn("Default playback device cannot be accessed from test environment.\n", .{});
			return error.SkipZigTest;
		} else return err;
	};
	defer deinitPlayer(player);

	try player.start();
}

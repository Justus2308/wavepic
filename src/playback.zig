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

pub const WriteFn = sysaudio.WriteFn;


var ctx: ?Context = null;
var players: std.SinglyLinkedList(sysaudio.Player) = .{}; // Nodes allocated by ctx


pub fn initPlayback(allocator: Allocator) Context.InitError!void {
	ctx = try Context.init(null, allocator, .{
		.deviceChangeFn = deviceChange,
	});
}

pub fn deinitPlayback() void {
	if (ctx == null) @panic("Call initPlayback first!");

	var node = players.first;
	while (node != null) {
		node.data.deinit();
		const next_node = node.?.next;
		ctx.?.allocator.destroy(node);
		node = next_node;
	}

	ctx.?.deinit();
}

fn deviceChange(_: *anyopaque) void {
	@panic("Device change during runtime not implemented yet!");
}


pub const AddPlayerError = Context.CreateStreamError || error { NoDevice };
/// Do not call `deinit` on the returned player manually, use `playback.deinitPlayer` for proper cleanup.
pub fn initPlayer(writeFn: WriteFn, options: sysaudio.StreamOptions) AddPlayerError!*Player {
	if (ctx == null) @panic("Call initPlayback first!");

	const device = ctx.?.defaultDevice(.playback) orelse return AddPlayerError.NoDevice;
	const player = try ctx.?.createPlayer(device, writeFn, options);
	errdefer player.deinit();

	const node = try ctx.?.allocator.create(@TypeOf(players).Node);
	node.*.data = player;

	players.prepend(node);

	return &node.*.data;
}

pub fn deinitPlayer(player: *Player) void {
	var node = players.first;
	while (node != null) : (node = node.?.next) {
		if (&node.?.data != player) continue;

		node.data.deinit();
		players.remove(node);
		ctx.?.allocator.destroy(node);
		return;
	} else log.warn("{s} player to deinit not found in 'players' list.\n", .{ @tagName(player.format) });
}

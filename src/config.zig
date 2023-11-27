const std = @import("std");
const os = std.os;
const Atomic = std.atomic.Atomic; // Change to .Value as soon as mach-sysaudio is on master
const rlim_t = std.os.rlim_t;

const assert = std.debug.assert;

const sysaudio = @import("mach-sysaudio");


const max_undo_steps_default = 64;
var max_undo_steps = Atomic(u32).init(max_undo_steps_default);

const max_memory_default = 0; // 0: unlimited
var max_memory = Atomic(rlim_t).init(max_memory_default);

pub const LimitError = os.SetrlimitError || os.GetrlimitError;
pub fn setMaxMemory(limit: rlim_t) LimitError!void {
	max_memory.fence(.Acquire);

	const old_limit = try os.getrlimit(.DATA);
	const cur_limit = if (limit == 0) os.RLIM.INFINITY else @min(limit, old_limit.max);
	const new_limit = os.rlimit { .cur = cur_limit, .max = old_limit.max };

	try os.setrlimit(.DATA, new_limit);

	max_memory.store(limit, .Release);
}



// AUDIO

const playback = @import("playback.zig");

const playback_volume_default: f32 = 1.0;
var playback_volume = Atomic(f32).init(playback_volume_default);

pub fn setPlaybackVolume(volume: f32) void {
	playback_volume.store(volume, .Acquire);

	var node = playback.players.first;
	while (node != null) : (node = node.?.next) {
		const plr_vol = try node.data.volume();
		try node.data.setVolume(plr_vol * volume);
	}
	playback_volume.fence(.Release);
}

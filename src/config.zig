const std = @import("std");
const Atomic = std.atomic.Atomic;
const rlim_t = std.os.rlim_t;

const max_undo_steps_default = 64;
var max_undo_steps = Atomic(u32).init(max_undo_steps_default);

const max_memory_default = 0; // 0: unlimited
var max_memory = Atomic(rlim_t).init(max_memory_default);

pub const LimitError = std.os.SetrlimitError || std.os.GetrlimitError;
pub fn setMaxMemory(limit: rlim_t) LimitError!void
{
	const old_limit = try std.os.getrlimit(.DATA);
	const cur_limit = if (limit == 0) old_limit.max else limit;
	const new_limit = std.os.rlimit { .cur = cur_limit, .max = old_limit.max };

	try std.os.setrlimit(.DATA, new_limit);

	max_memory.store(limit, .Unordered);
}

const std = @import("std");
const os = std.os;
const Atomic = std.atomic.Atomic;
const rlim_t = std.os.rlim_t;

const assert = std.debug.assert;

const max_undo_steps_default = 64;
var max_undo_steps = Atomic(u32).init(max_undo_steps_default);

const max_memory_default = 0; // 0: unlimited
var max_memory = Atomic(rlim_t).init(max_memory_default);

pub const LimitError = os.SetrlimitError || os.GetrlimitError;
pub fn setMaxMemory(limit: rlim_t) LimitError!void
{
	const old_limit = try os.getrlimit(.DATA);
	const cur_limit = if (limit == 0) os.RLIM.INFINITY else @min(limit, old_limit.max);
	const new_limit = os.rlimit { .cur = cur_limit, .max = old_limit.max };

	try os.setrlimit(.DATA, new_limit);

	max_memory.store(limit, .Unordered);
}

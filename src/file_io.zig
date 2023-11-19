pub const cache = @import("file_io/cache.zig");
pub const diff = @import("file_io/diff.zig");
pub const FileMapper = @import("file_io/FileMapper.zig");

const std = @import("std");
const os = std.os;
const testing = std.testing;

const assert = std.debug.assert;

const SigHandlerState = struct {
	fallback_handler: union(enum) {
		handler: os.Sigaction.handler_fn,
		sigaction: os.Sigaction.sigaction_fn,
		none,
	} = .{ .none = {} },
	handler_installed: bool = false,
};

// GLOBALS
var sigbus_handler_state = SigHandlerState {};


pub fn installSigbusHandler() void {
	if (@cmpxchgStrong(bool, &sigbus_handler_state.handler_installed, false, true, .SeqCst, .SeqCst) != null) return;

	const new_action = os.Sigaction {
		.handler = .{ .sigaction = &sigbusHandler, },
		.mask = 0,
		.flags = os.SA.SIGINFO,
	};
	var old_action: os.Sigaction = undefined;

	os.sigaction(os.SIG.BUS, &new_action, &old_action) catch unreachable;

	sigbus_handler_state.fallback_handler = blk: {
		if (old_action.flags & os.SA.SIGINFO == 0) {
			if (old_action.handler.handler) |handler| break :blk .{ .handler = handler }
			else break :blk .{ .none = {} };
		} else {
			if (old_action.handler.sigaction) |action| break :blk .{ .sigaction = action }
			else unreachable;
		}
	};
}
fn sigbusHandler(
	sig: c_int,
	siginfo: *const os.siginfo_t,
	ptr: ?*const anyopaque
) callconv(.C) void {
	assert(sig == os.SIG.BUS);

	const error_addr: *anyopaque = siginfo.addr;
	_ = error_addr;
	// TODO: check if addr in mapped memory

	switch (sigbus_handler_state.fallback_handler) {
		.handler => |handler| handler(sig),
		.sigaction => |action| action(sig, siginfo, ptr),
		.none => @panic("Unhandled SIGBUS caught"),
	}
}


test "Recieve and handle SIGBUS" {
	const handler_tags = @typeInfo(@TypeOf(sigbus_handler_state.fallback_handler)).Union.tag_type.?;

	try testing.expect(sigbus_handler_state.fallback_handler == handler_tags.none);

	var old_action: os.Sigaction = undefined;
	try os.sigaction(os.SIG.BUS, null, &old_action);
	const old_tag: handler_tags = blk: {
		if (old_action.flags & os.SA.SIGINFO == 0) {
			if (old_action.handler.handler != null) break :blk .handler
			else break :blk .none;
		} else {
			if (old_action.handler.sigaction != null) break :blk .sigaction
			else unreachable;
		}
	}; 

	installSigbusHandler();
	try testing.expect(sigbus_handler_state.fallback_handler == old_tag);

	installSigbusHandler();
	installSigbusHandler();
	try testing.expect(sigbus_handler_state.fallback_handler == old_tag);

	const pid = @import("util.zig").getPID();
	try os.kill(pid, os.SIG.BUS);

	// TODO?: reinstall old handler
}

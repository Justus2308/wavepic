const builtin = @import("builtin");
const target_os = builtin.os.tag;

const std = @import("std");
const os = std.os;
const testing = std.testing;

const assert = std.debug.assert;

const Sigaction = os.Sigaction;

const file_io = @import("../file_io.zig");
const FileMap = file_io.FileMap;

const windows = @import("../windows.zig");


const Context = switch (target_os) {
	.windows => *anyopaque,
	else => union(enum) {
		handler: Sigaction.handler_fn,
		sigaction: Sigaction.sigaction_fn,
		none,
	},
};

const State = struct {
	context: Context = if (target_os == .windows) null else .{ .none = {} },
	handler_installed: bool = false,
};

var state = State {};


pub fn installFailureHandler() void {
	if (@cmpxchgStrong(bool, &state.handler_installed, false, true, .SeqCst, .SeqCst) != null) return;

	switch (target_os) {
		.windows => {
			state.context = windows.kernel32.AddVectoredExceptionHandler(1, &windowsExceptionInPageVEH);
		},
		else => {
			const new_action = Sigaction {
				.handler = .{ .sigaction = &sigbusHandler, },
				.mask = 0,
				.flags = os.SA.SIGINFO,
			};
			var old_action: Sigaction = undefined;

			os.sigaction(os.SIG.BUS, &new_action, &old_action) catch unreachable;

			state.context = blk: {
				if (old_action.flags & os.SA.SIGINFO == 0) {
					if (old_action.handler.handler) |handler| break :blk .{ .handler = handler }
					else break :blk .{ .none = {} };
				} else {
					if (old_action.handler.sigaction) |action| break :blk .{ .sigaction = action }
					else unreachable;
				}
			};
		}
	}
}


const WINAPI = windows.WINAPI;
const EXCEPTION_POINTERS = windows.EXCEPTION_POINTERS;
const EXCEPTION_IN_PAGE_ERROR = windows.EXCEPTION_IN_PAGE_ERROR;
const EXCEPTION_CONTINUE_SEARCH = windows.EXCEPTION_CONTINUE_SEARCH;
const EXCEPTION_CONTINUE_EXECUTION = windows.EXCEPTION_CONTINUE_EXECUTION;
fn windowsExceptionInPageVEH(ExceptionInfo: *EXCEPTION_POINTERS) callconv(WINAPI) c_long {
	if (ExceptionInfo.ExceptionRecord.ExceptionCode != EXCEPTION_IN_PAGE_ERROR) return EXCEPTION_CONTINUE_SEARCH;

	const error_addr: *anyopaque = ExceptionInfo.ExceptionAddress;

	if (file_io.checkIfMapped(error_addr)) |map| {
		map.handleFailure();
		return EXCEPTION_CONTINUE_EXECUTION;
	}

	return EXCEPTION_CONTINUE_SEARCH;
}

fn sigbusHandler(
	sig: c_int,
	siginfo: *const os.siginfo_t,
	ptr: ?*const anyopaque
) callconv(.C) void {
	assert(sig == os.SIG.BUS);

	const error_addr: *anyopaque = siginfo.addr;

	if (file_io.checkIfMapped(error_addr)) |map| {
		map.handleFailure();
		return;
	}

	// Use fallback handler
	switch (state.context) {
		.handler => |handler| handler(sig),
		.sigaction => |action| action(sig, siginfo, ptr),
		.none => @panic("Unhandled SIGBUS caught."),
	}
}


test "Handle SIGBUS from mapped memory" {
	if (target_os == .windows) return error.SkipZigTest;

	const allocator = testing.allocator;

	const kill_addr = @intFromPtr(&os.kill);
	const aligned_kill_addr = kill_addr & (~(@as(usize, std.mem.page_size) - 1));

	var map = FileMap {
		.slc = @alignCast(@as([*]u8, @ptrFromInt(aligned_kill_addr))[0..0xFFFFFFFF]),
		.windows_map_handle = {},
	};

	try file_io.addMapping(allocator, &map);
	defer file_io.removeMapping(allocator, &map);

	installFailureHandler();

	const pid = @import("../util.zig").getPID();
	try os.kill(pid, os.SIG.BUS);

	var buf: [1]u8 = undefined;

	const err = map.read(&buf, 0);
	try testing.expectError(FileMap.Error.IO, err);
}

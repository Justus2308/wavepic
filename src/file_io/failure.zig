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


test "Recieve and handle SIGBUS from mapping" {
	if (target_os == .windows) return error.SkipZigTest;

	const context_tags = @typeInfo(@TypeOf(state.context)).Union.tag_type.?;

	var old_action = if (state.context != context_tags.none) blk: {
		const old_action = switch (state.context) {
			.handler => |handler| Sigaction { .handler = .{ .handler = handler }, .mask = 0, .flags = 0 },
			.sigaction => |sigaction| Sigaction { .handler = .{ .sigaction = sigaction }, .mask = 0, .flags = os.SA.SIGINFO },
			else => unreachable,
		};

		try os.sigaction(os.SIG.BUS, &old_action, null);

		state.context = .{ .none = {} };
		state.handler_installed = false;

		break :blk old_action;
	} else blk: {
		var old_action: Sigaction = undefined;
		try os.sigaction(os.SIG.BUS, null, &old_action);
		
		break :blk old_action;
	};

	const old_tag: context_tags = blk: {
		if (old_action.flags & os.SA.SIGINFO == 0) {
			if (old_action.handler.handler != null) break :blk .handler
			else break :blk .none;
		} else {
			if (old_action.handler.sigaction != null) break :blk .sigaction
			else unreachable;
		}
	};


	installFailureHandler();
	try testing.expect(state.context == old_tag);
	const current_state = state;

	installFailureHandler();
	installFailureHandler();
	try testing.expect(state.context == old_tag);
	try testing.expectEqualDeep(current_state, state);

	const fs = std.fs;

	const cwd = fs.cwd();
	var file = try cwd.openFile("./test_in/mp3_test_in.mp3", .{});

	var map = try FileMap.init(file.handle);
	defer map.deinit();

	const allocator = testing.allocator;

	try file_io.addMapping(allocator, map);
	defer file_io.removeMapping(allocator, &map);

	const start_addr = @intFromPtr(map.slc.ptr);
	const end_addr = start_addr + map.size;
	std.log.warn("Range: {x} - {x}", .{ start_addr, end_addr });

	// Try to write to read-only map to cause SIGBUS
	map.slc[15] = 'A';

	// const pid = @import("../util.zig").getPID();
	// try os.kill(pid, os.SIG.BUS);

	// TODO?: reinstall old handler for further testing
}

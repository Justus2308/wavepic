const builtin = @import("builtin");
const target_os = builtin.os.tag;

const std = @import("std");
const os = std.os;
const testing = std.testing;

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Sigaction = os.Sigaction;

const file_io = @import("../file_io.zig");
const FileMap = file_io.FileMap;

const log = file_io.log;

const windows = @import("../windows.zig");


/// This needs to be static otherwise the signal/exception handler can't access it
var map_list = std.SinglyLinkedList(*FileMap) {};

/// Do not call manually, use `FileMap.init()`.
pub fn addMapping(map: *FileMap) Allocator.Error!void {
	const node = try map.allocator.create(@TypeOf(map_list).Node);
	node.*.data = map;

	map_list.prepend(node);
}

/// Do not call manually, use `FileMap.deinit()`.
pub fn removeMapping(map: *FileMap) void {
	var node = map_list.first;
	const rem = while (node != null) : (node = node.?.next) {
		if (node.?.data == map) break node;
	} else {
		log.warn("Could not find mapping to remove for FileMap at 0x{x}.\n", .{ @intFromPtr(map) });
		return;
	};

	map_list.remove(rem.?);
	map.allocator.destroy(rem.?);
}

/// Returns `null` if `ptr` isn't in any registered mapping.
fn getMapping(ptr: *anyopaque) ?*FileMap {
	var node = map_list.first;
	return while (node != null) : (node = node.?.next) {
		if (node.?.data.contains(ptr)) break node.?.data;
	} else null;
}



const Context = switch (target_os) {
	.windows => ?*anyopaque,
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

	if (getMapping(error_addr)) |map| {
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

	if (getMapping(error_addr)) |map| {
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
	const aligned_kill_addr = std.mem.alignBackward(usize, kill_addr, @as(usize, std.mem.page_size));

	var file_map = FileMap {
		.allocator = allocator,
		.handle = 0,
		.slc = @alignCast(@as([*]u8, @ptrFromInt(aligned_kill_addr))[0..0xFFFFFFFF]),
		.windows_map_handle = {},
	};

	try addMapping(&file_map);
	defer removeMapping(&file_map);

	installFailureHandler();

	log.info("test: expected warning: 'FileMap: handleFailure invoked.'\n", .{});

	const pid = @import("../util.zig").getPID();
	try os.kill(pid, os.SIG.BUS);

	var buf: [1]u8 = undefined;

	const err = file_map.read(&buf, 0);
	try testing.expectError(FileMap.Error.IO, err);
}

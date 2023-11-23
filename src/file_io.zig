const cache = @import("file_io/cache.zig");
const failure = @import("file_io/failure.zig");

pub const DeltaStack = @import("file_io/DeltaStack.zig");
pub const FileMap = @import("file_io/FileMap.zig");

const builtin = @import("builtin");
const target_os = builtin.os.tag;

const std = @import("std");
const os = std.os;
const testing = std.testing;

const Allocator = std.mem.Allocator;
const Handle = os.fd_t;

/// This needs to be static otherwise the signal/exception handler can't access it
var map_list = std.SinglyLinkedList(*FileMap) {};

/// Do not call manually, use `FileMap.init()`
pub fn addMapping(map: *FileMap) Allocator.Error!void {
	const node = try map.allocator.create(@TypeOf(map_list).Node);
	node.*.data = map;

	map_list.prepend(node);
}

/// Do not call manually, use `FileMap.deinit()`
pub fn removeMapping(map: *FileMap) void {
	var node = map_list.first;
	const rem = while (node != null) : (node = node.?.next) {
		if (node.?.data == map) break node;
	} else {
		std.log.warn("Could not find mapping to remove for FileMap at 0x{x}.\n", .{ @intFromPtr(map) });
		return;
	};

	map_list.remove(rem.?);
	map.allocator.destroy(rem.?);
}

pub fn checkIfMapped(ptr: *anyopaque) ?*FileMap {
	var node = map_list.first;
	return while (node != null) : (node = node.?.next) {
		if (node.?.data.contains(ptr)) break node.?.data;
	} else null;
}

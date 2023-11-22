const cache = @import("file_io/cache.zig");
const diff = @import("file_io/diff.zig");
const failure = @import("file_io/failure.zig");

pub const FileMap = @import("file_io/FileMap.zig");

const builtin = @import("builtin");
const target_os = builtin.os.tag;

const std = @import("std");
const os = std.os;
const testing = std.testing;

const Allocator = std.mem.Allocator;

/// This needs to be static otherwise the signal/exception handler can't access it
var map_list = std.SinglyLinkedList(*FileMap) {};

pub fn addMapping(allocator: Allocator, map: *FileMap) Allocator.Error!void {
	var node = try allocator.create(@TypeOf(map_list).Node);
	node.data = map;

	map_list.prepend(node);
}

/// Allocator has to be the same the mapping has been added with.
pub fn removeMapping(allocator: Allocator, map: *FileMap) void {
	var node = map_list.first;
	const rem = while (node != null) : (node = node.?.next) {
		if (node.?.data == map) break node;
	} else return;

	map_list.remove(rem.?);
	allocator.destroy(rem.?);
}

pub fn checkIfMapped(ptr: *anyopaque) ?*FileMap {
	var node = map_list.first;
	return while (node != null) : (node = node.?.next) {
		if (node.?.data.contains(ptr)) break node.?.data;
	} else null;
}

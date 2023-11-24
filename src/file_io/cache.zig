const std = @import("std");
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

const convert = @import("../convert.zig");
const Fmt = convert.Fmt;

const file_io = @import("../file_io.zig");
const DeltaStack = file_io.DeltaStack;

const log = file_io.log;




/// Used to save the current file state every couple of user operations
pub const CacheFile = struct {
	fd: std.os.fd_t,
	size: u64,
	orig_size: ?u64, // if this is null, the file is uncompressed
};

/// Holds a past file state and a `DeltaStack` to hold succeeding changes
pub const CacheStep = struct {
	img: CacheFile,
	deltas: DeltaStack,
};

pub const CacheList = struct {
	const List = std.SinglyLinkedList(CacheStep);
	const Pool = std.heap.MemoryPool(List.Node);

	allocator: Allocator,
	pool: Pool,

	list: List,

	const Self = @This();
	pub const Error = error {
		OutOfMemory, // for memory pool
	};
};

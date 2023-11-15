const std = @import("std");
const Allocator = std.mem.Allocator;

const diff = @import("diff.zig");
const DeltaStack = diff.DeltaStack;
const Delta = diff.Delta;


/// Used to save the current file state every couple of user operations
pub const CacheFile = struct
{
	fd: std.os.fd_t,
	size: u64,
	orig_size: ?u64, // if this is null, the file is uncompressed
};

/// Holds a past file state and a DeltaList to hold succeeding changes
pub const CacheStep = struct
{
	img: CacheFile,
	deltas: DeltaStack,
};

pub const CacheList = struct
{
	const List = std.SinglyLinkedList(CacheStep);
	const Pool = std.heap.MemoryPool(List.Node);

	allocator: Allocator,
	pool: Pool,

	list: List,

	const Self = @This();
	pub const Error = error
	{
		OutOfMemory, // for memory pool
	};
};

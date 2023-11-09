const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;

const assert = std.debug.assert;

const convert = @import("convert.zig");
const Fmt = convert.Fmt;


/// Delta interval, start and end must be
/// seekable positions in the target
pub const Delta = struct
{
	start: u64,
	end: u64,
};


// How this works:
// The deltas are saved in a singly linked list with O(1)
// insert and delete operations for the latest element
// which is all we need for do/undo operations.
// Before applying the collected deltas the list is
// merge sorted and then traversed sequentially to find
// all overlaps.
// Now the deltas are ready to be applied to a target file.
// All allocations are managed by a memory pool and freed
// as soon as the deltas are applied.

/// Interval tree using memory pool to manage deltas
pub const DeltaManager = struct
{
	const List = std.SinglyLinkedList(Delta);
	const Pool = std.heap.MemoryPool(List.Node);

	pool: Pool,
	list: List,

	merge_threshold: u64,

	const Self = @This();
	pub const Error = error
	{
		OutOfMemory, // for memory pool
		DeltaCountOverflow,
	};

	pub const Options = struct
	{
		/// max distance between deltas to merge, in bytes
		merge_threshold: u64 = 8,
	};
	pub fn init(allocator: Allocator, options: Options) Self
	{
		var pool = Pool.init(allocator);

		return
		.{
			.pool = pool,
			.list = .{},

			.merge_threshold = options.merge_threshold,
		};
	}

	pub fn reset(self: *Self) void
	{
		// self.pool.reset(); // use this as soon as it's properly implemented
		const ret = self.pool.arena.reset(.{ .retain_with_limit = 256 * @sizeOf(List.Node) });
		if (ret == false) std.log.warn("Memory pool of DeltaManager could not be reset successfully.\n", .{});
		self.pool.free_list = null;
	}

	pub fn deinit(self: *Self) void
	{
		self.pool.deinit();
		self.* = undefined;
	}


	/// Start must be less than end, treat this condition
	/// as unchecked in releaseFast and releaseSmall mode.
	/// Potential error is OutOfMemory, the pool will still
	/// be intact and remain unchanged if this error occurs.
	pub fn push(self: *Self, start: u64, end: u64) Error!void
	{
		assert(start < end);

		var node = try self.pool.create();
		// errdefer self.pool.deinit();
		node.data = .{ .start = start, .end = end };

		self.list.prepend(node);
	}

	/// Disregard the latest delta. Popping an empty delta list
	/// is a noop right now.
	/// TODO: make undos possible after applying deltas by adding them
	/// as new deltas
	pub fn pop(self: *Self) Error!void
	{
		const node = self.list.popFirst() orelse return;
		self.pool.destroy(node);
	}


	pub fn mergeIntervals(self: *Self) void
	{
		var head = self.list.first;
		head = mergeSort(head);

		var merged = List {};
		var node = head orelse return;
		var next_node = node.next;

		while (next_node) |next| : (next_node = next.next)
		{
			if (node.data.start < next.data.end) // overlap
			{
				node.data.start = @min(node.data.start, next.data.start);
			}
			else // no overlap
			{
				merged.prepend(node);
				node = next;
			}
		}

		merged.prepend(node);
		self.list = merged;
	}
	fn mergeSort(head: ?*List.Node) ?*List.Node
	{
		if (head == null or head.?.next == null) return head;

		// find middle of list
		var slow = head;
		var fast = head;

		while (fast.?.next != null and fast.?.next.?.next != null)
		{
			slow = slow.?.next;
			fast = fast.?.next.?.next;
		}

		const half = slow.?.next;
		slow.?.next = null;

		const new_head = mergeSort(head);
		const new_half = mergeSort(half);

		return merge(new_head, new_half);
	}
	fn merge(head: ?*List.Node, half: ?*List.Node) ?*List.Node
	{
		var head_node = if (head) |h| h else return half;
		var half_node = if (half) |s| s else return head;

		if (head_node.data.end > half_node.data.end)
		{
			head_node.next = merge(head_node.next, half_node);
			return head_node;
		}
		else
		{
			half_node.next = merge(head_node, half_node.next);
			return half_node;
		}
	}


	pub fn dump(self: *Self) void
	{
		std.debug.print("DeltaManager dump:\n", .{});
		
		var node = self.list.first;
		var i: usize = 0;
		while (node != null) : (node = node.?.*.next)
		{
			std.debug.print("{d}: {any}\n", .{ i, node.?.*.data });
			i += 1;
		}
	}
};


pub const OutFile = struct
{
	file: *File,
	cache: *File,
	writer: std.io.Writer,

	deltas: DeltaManager,

	path: []const u8,
	fmt: Fmt,

	const Self = @This();
	pub const Error = Allocator.Error || File.OpenError || File.GetSeekPosError || File.CopyRangeError || error
	{
		CopyUnexpectedEOF,
	};

	pub fn create(allocator: Allocator, absolute_path: []const u8, fmt: Fmt, cache: *File) Error!Self
	{		
		const file = try std.fs.createFileAbsolute(absolute_path, .{ .read = true, .lock = .exclusive });
		errdefer file.close();

		const buf_writer = std.io.bufferedWriter(file.writer());
		const writer = buf_writer.writer();

		const deltas = std.ArrayList(Delta).init(allocator);

		return
		.{
			.file = file,
			.cache = cache,
			.writer = writer,
			.deltas = deltas,
			.path = absolute_path,
			.fmt = fmt,
		};
	}

	pub fn saveAs(self: *Self, absolute_path: []const u8) Error!u64
	{
		const where = try std.fs.createFileAbsolute(absolute_path, .{ .read = true });
		defer where.close();

		const end_pos = try self.file.getEndPos();
		const len = end_pos + 1;

		const copied_size = try self.file.copyRangeAll(0, where, 0, self.file, len);

		if (copied_size != len) return Error.CopyUnexpectedEOF;

		return copied_size;
	}

	// pub fn save(self: *Self, ) Error!u64
	// {

	// }

	// pub fn close(self: *Self) void
	// {
	// 	self.file.close();
	// 	self.* = undefined;
	// }
};


test "DeltaManager insert elements"
{
	var deltas = DeltaManager.init(std.testing.allocator, .{});
	defer deltas.deinit();

	try deltas.push(0, 10);
	try deltas.push(3, 11);
	try deltas.push(2, 5);
	try deltas.push(9, 27);
	try deltas.push(403, 643);
	try deltas.push(51, 89);
	try deltas.push(1, 42);
	try deltas.push(103, 210);
	try deltas.push(91, 104);
	try deltas.push(378, 415);

	deltas.dump();
}

test "DeltaManager merge sort"
{
	var deltas = DeltaManager.init(std.testing.allocator, .{});
	defer deltas.deinit();

	try deltas.push(0, 10);
	try deltas.push(3, 11);
	try deltas.push(2, 5);
	try deltas.push(9, 27);
	try deltas.push(403, 643);
	try deltas.push(51, 89);
	try deltas.push(1, 42);
	try deltas.push(103, 210);
	try deltas.push(91, 104);
	try deltas.push(378, 415);

	const sorted = DeltaManager.mergeSort(deltas.list.first);
	deltas.list.first = sorted;

	deltas.dump();
}

test "DeltaManager merge intervals"
{
	var deltas = DeltaManager.init(std.testing.allocator, .{});
	defer deltas.deinit();

	try deltas.push(0, 10);
	try deltas.push(3, 11);
	try deltas.push(2, 5);
	try deltas.push(9, 27);
	try deltas.push(403, 643);
	try deltas.push(51, 89);
	try deltas.push(1, 42);
	try deltas.push(103, 210);
	try deltas.push(91, 104);
	try deltas.push(378, 415);

	deltas.mergeIntervals();

	deltas.dump();
}

test "DeltaManager preheated reset"
{
	var deltas = DeltaManager.init(std.testing.allocator, .{});
	defer deltas.deinit();
	std.debug.print("{d}\n", .{ deltas.pool.arena.queryCapacity() });

	try deltas.push(0, 10);
	try deltas.push(3, 11);
	try deltas.push(2, 5);
	try deltas.push(9, 27);
	try deltas.push(403, 643);
	try deltas.push(51, 89);
	try deltas.push(1, 42);
	try deltas.push(103, 210);
	try deltas.push(91, 104);
	try deltas.push(378, 415);

	const cap_before_reset = deltas.pool.arena.queryCapacity();

	deltas.reset();

	const cap_after_reset = deltas.pool.arena.queryCapacity();

	try std.testing.expect(cap_before_reset == cap_after_reset);

	try deltas.push(45, 123);
	try deltas.push(0, 12);
	try deltas.push(2, 67);
	try deltas.push(90, 141);

	const cap_after_inserts = deltas.pool.arena.queryCapacity();

	try std.testing.expect(cap_after_reset == cap_after_inserts);
}

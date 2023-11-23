const std = @import("std");
const os = std.os;

const assert = std.debug.assert;
const log = std.log;

const Allocator = std.mem.Allocator;
const Handle = os.fd_t;

const c = @import("../c.zig");


pub const DeltaStack = @This();

// RATIONALE:
// * Store only relevant data by using deltas
// * After certain size threshold: store data in lz4 files instead of heap
// * Every `Delta` has a `priority` (basically timestamp) to handle overlaps correctly

const Location = union(enum) {
	slc: []u8,
	file: Handle,
};

pub const Delta = struct {
	data: Location,
	offset: u64,
	prioritiy: u32,
};

const List = std.SinglyLinkedList(Delta);
const Pool = std.heap.MemoryPool(List.Node);


allocator: Allocator,
pool: Pool,

list: List = .{},

merge_threshold: u64,


pub const Error = error { OutOfMemory };


pub const Options = struct {
	/// max distance between deltas to merge, in bytes
	merge_threshold: u64 = 256,
};
pub fn init(allocator: Allocator, options: Options) DeltaStack {
	const pool = Pool.init(allocator);

	return .{
		.allocator = allocator,
		.pool = pool,

		.merge_threshold = options.merge_threshold,
	};
}

/// Will clear all deltas and all cached undo/redo steps.
/// Half of the already allocated memory will be retained
/// with a soft minimum of the size of 256 Nodes.
pub fn resetHard(self: *DeltaStack) void {
	// self.pool.reset(); // use this as soon as it's properly implemented
	const half_cap = self.pool.arena.queryCapacity() >> 1;
	const limit = @max(256 * @sizeOf(List.Node), half_cap);

	const ret = self.pool.arena.reset(.{ .retain_with_limit = limit });
	if (ret == false) log.warn("Memory pool of DeltaList could not be reset successfully.\n", .{});
	self.pool.free_list = null;
}

/// Will clear all deltas but keep all cached undo/redo steps.
/// All allocated memory will be retained. TODO: change this
pub fn resetDeltas(self: *DeltaStack) void {
	_ = self;
}

pub fn deinit(self: *DeltaStack) void {
	self.pool.deinit();
	self.* = undefined;
}


/// `start` must be less than `end`, treat this condition
/// as unchecked in ReleaseFast and ReleaseSmall mode.
/// Potential error is `OutOfMemory`, the pool will still
/// be intact and remain unchanged if this error occurs.
pub fn push(self: *DeltaStack, start: u64, end: u64) Error!void {
	assert(start < end);

	var node = try self.pool.create();
	// errdefer self.pool.deinit();
	node.data = .{ .start = start, .end = end };

	self.list.prepend(node);
}

/// Disregard the latest delta. Popping an empty `DeltaStack`
/// is a noop right now.
/// TODO: make undos possible after applying deltas by adding them
/// as new deltas
pub fn pop(self: *DeltaStack) void {
	const node = self.list.popFirst() orelse return;
	self.pool.destroy(node);
}

/// Returns a delta whose interval contains all other deltas
pub fn mergeIntervals(self: *DeltaStack) Delta {
	var head = self.list.first;
	head = mergeSort(head);

	var merged = List {};
	var node = head orelse return;
	var next_node = node.next;

	const max_end = node.data.end;

	while (next_node) |next| : (next_node = next.next) {
		if (node.data.start < next.data.end + self.merge_threshold) {
			node.data.start = @min(node.data.start, next.data.start);
		} else {
			merged.prepend(node);
			node = next;
		}
	}

	merged.prepend(node);
	self.list = merged;

	const min_start = self.list.first.?.data.start;

	return .{
		.start = min_start,
		.end = max_end,
	};
}
fn mergeSort(head: ?*List.Node) ?*List.Node
{
	if (head == null or head.?.next == null) return head;

	// find middle of list
	var slow = head;
	var fast = head;

	while (fast.?.next != null and fast.?.next.?.next != null) {
		slow = slow.?.next;
		fast = fast.?.next.?.next;
	}

	// split list in half
	const half = slow.?.next;
	slow.?.next = null;

	// sort both halfs
	const new_head = mergeSort(head);
	const new_half = mergeSort(half);

	// merge sorted halfs
	return merge(new_head, new_half);
}
fn merge(head: ?*List.Node, half: ?*List.Node) ?*List.Node
{
	var head_node = head orelse return half;
	var half_node = half orelse return head;

	if (head_node.data.end > half_node.data.end) {
		head_node.next = merge(head_node.next, half_node);
		return head_node;
	} else {
		half_node.next = merge(head_node, half_node.next);
		return half_node;
	}
}


fn dump(self: *DeltaStack) void {
	log.debug("DeltaManager dump:\n", .{});
	
	var node = self.list.first;
	var i: usize = 0;
	while (node != null) : (node = node.?.*.next) {
		log.debug("{d}: {any}\n", .{ i, node.?.*.data });
		i += 1;
	}
}


test "DeltaStack insert elements"
{
	var deltas = DeltaStack.init(std.testing.allocator, .{});
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

test "DeltaStack merge sort"
{
	var deltas = DeltaStack.init(std.testing.allocator, .{});
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

	const sorted = DeltaStack.mergeSort(deltas.list.first);
	deltas.list.first = sorted;

	deltas.dump();
}

test "DeltaStack merge intervals"
{
	var deltas = DeltaStack.init(std.testing.allocator, .{ .merge_threshold = 8 });
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

	const delta_interval = deltas.mergeIntervals();

	deltas.dump();
	log.debug("Total interval: {d} to {d}\n",
		.{ delta_interval.start, delta_interval.end });
}

test "DeltaStack preheated reset"
{
	var deltas = DeltaStack.init(std.testing.allocator, .{});
	defer deltas.deinit();

	const cap_at_init = deltas.pool.arena.queryCapacity();

	try std.testing.expect(cap_at_init == 0);

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

	deltas.resetHard();

	const cap_after_reset = deltas.pool.arena.queryCapacity();

	try std.testing.expect(cap_before_reset == cap_after_reset);

	try deltas.push(45, 123);
	try deltas.push(0, 12);
	try deltas.push(2, 67);
	try deltas.push(90, 141);

	const cap_after_inserts = deltas.pool.arena.queryCapacity();

	try std.testing.expect(cap_after_reset == cap_after_inserts);
}

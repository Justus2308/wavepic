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
	max_end: u64,

	left: ?*Delta = null,
	right: ?*Delta = null,

	comptime
	{
		assert(@sizeOf(@This()) == 3*@sizeOf(u64) + 2*@sizeOf(?*Delta));
	}
};

/// Interval tree using memory pool to manage deltas
pub const DeltaManager = struct
{
	const Pool = std.heap.MemoryPool(Delta);

	pool: Pool,
	root: ?*Delta,

	const Self = @This();
	pub const Error = error
	{
		OutOfMemory // for memory pool
	};

	pub fn init(allocator: Allocator) Self
	{
		var pool = Pool.init(allocator);

		return
		.{
			.pool = pool,
			.root = null
		};
	}

	pub fn reset(self: *Self) void
	{
		self.pool.reset();
		// const ret = self.arena.reset(.{ .retain_with_limit = @sizeOf(List.Node) * 256 });
		// if (ret == false) std.log.warn("Memory arena of DeltaManager could not be reset successfully.\n", .{});
	}

	pub fn deinit(self: *Self) void
	{
		self.pool.deinit();
		self.* = undefined;
	}

	/// Start must be less than end, treat this condition
	/// as unchecked in releaseFast and releaseSmall mode
	pub fn insert(self: *Self, start: u64, end: u64) Error!void
	{
		assert(start < end);

		var delta = try self.pool.create();
		delta.* = .{ .start = start, .end = end, .max_end = end };

		self.root = insert_recursive(self.root, delta);
	}
	fn insert_recursive(root: ?*Delta, delta: *Delta) *Delta
	{
		const root_ptr = if (root) |r| r else return delta;

		if (delta.start < root_ptr.start)
		{
			root_ptr.left = insert_recursive(root_ptr.left, delta);
		}
		else
		{
			root_ptr.right = insert_recursive(root_ptr.right, delta);
		}

		root_ptr.max_end = @max(root_ptr.end, delta.end);

		return root_ptr;
	}

	pub fn dump(self: *Self) void
	{
		std.debug.print("DeltaManager dump:\n", .{});
		const lit = if (self.root != null) "ROOT :: " else "EMPTY\n";
		std.debug.print("{s}", .{ lit });
		dump_recursive(self.root, 0);
	}
	fn dump_recursive(root: ?*Delta, level: u32) void
	{
		const root_ptr = if (root) |r| r else return;

		std.debug.print("level: {d} | start: {d} | end: {d}\n",
			.{ level, root_ptr.start, root_ptr.end });

		const next_level = level + 1;

		if (root_ptr.left != null) std.debug.print("LEFT :: ", .{});
		dump_recursive(root_ptr.left, next_level);

		if (root_ptr.right != null) std.debug.print("RIGHT :: ", .{});
		dump_recursive(root_ptr.right, next_level);
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
	var deltas = DeltaManager.init(std.testing.allocator);
	defer deltas.deinit();

	try deltas.insert(0, 10);
	try deltas.insert(3, 10);
	try deltas.insert(2, 5);
	try deltas.insert(9, 27);
	try deltas.insert(103, 643);
	try deltas.insert(7, 89);
	try deltas.insert(2, 11);
	try deltas.insert(7, 14);
	try deltas.insert(79, 104);

	deltas.dump();
}

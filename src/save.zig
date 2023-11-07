const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;

const convert = @import("convert.zig");
const Fmt = convert.Fmt;


pub const Delta = packed struct
{
	pos: u64,
	data: []const u8,
};

/// Priority queue based on a binary heap
pub const DeltaQueue = struct
{
	allocator: Allocator,

	const Self = @This();
	pub const Error = Allocator.Error;

	pub fn init(allocator: Allocator) Self
	{

	}

	pub fn deinit(self: *Self) void
	{

	}

	pub fn insert(self: *Self, delta: Delta) !void
	{

	}
};


pub const OutFile = struct
{
	file: *File,
	cache: *File,
	writer: std.io.Writer,

	deltas: DeltaQueue,

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

		return Self
		{
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

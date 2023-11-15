const builtin = @import("builtin");
const native_os = builtin.os.tag;
const std = @import("std");
const os = std.os;

const Allocator = std.mem.Allocator;
const File = std.fs.File;

const assert = std.debug.assert;

const diff = @import("diff.zig");
const windows = struct
{
	usingnamespace os.windows;
	usingnamespace @import("windows_extra.zig");
};


const FileMap = struct
{
	allocator: Allocator,
	ptr: []align(std.mem.page_size) u8,

	handle: os.fd_t,
	offset: u64,
	length: u64,

	const Self = @This();
	pub const Error = Allocator.Error 
		|| os.FStatError || os.MMapError 
		|| os.FlockError || os.WriteError;

	pub const Options = struct {
		from: u64 = 0,
		to: ?u64 = null,
		direct: bool = false,
	};
	/// The id union passed to this must have a comptime-known tag.
	/// Use @unionInit to create it.
	/// This is only comptime checked in debug and release_safe mode.
	pub fn init(allocator: Allocator, handle: os.fd_t, options: Options) Error!Self
	{
		switch (native_os)
		{
			.windows =>
			{

				const size = try windows.GetFileSizeEx(handle);

				const offset = options.from;
				const length = (options.to orelse size) - options.from;

				try 
			},
			else =>
			{

			},
		}

		const stats = try os.fstat(fd);

		const offset = options.from;
		const length = (options.to orelse stats.size) - options.from;

		const ptr = try os.mmap(
			null,
			@intCast(length),
			os.PROT.READ || os.PROT.WRITE,
			if (options.direct) os.MAP.SHARED else os.MAP.PRIVATE,
			fd,
			offset,
		);

		return
		.{
			.allocator = allocator,
			.ptr = ptr,

			.fd = fd,
			.offset = offset,
			.length = length,
		};
	}

	pub fn deinit(self: *Self) void
	{
		os.munmap(self.ptr);
		self.ptr = undefined;
	}

	pub fn write(self: *Self, deltas: ?*diff.Delta) !void
	{
		std.os.windows.HANDLE;
	}

	pub fn apply(self: *Self) Error!void
	{
		try os.flock(self.fd, os.LOCK.EX);
	}
};

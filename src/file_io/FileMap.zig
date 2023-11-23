const builtin = @import("builtin");
const target_os = builtin.os.tag;
const std = @import("std");
const os = std.os;

const page_size = std.mem.page_size;

const assert = std.debug.assert;
const log = std.log;

const Allocator = std.mem.Allocator;
const Handle = os.fd_t;

const file_io = @import("../file_io.zig");

const windows = @import("../windows.zig");
const failure = @import("failure.zig");


pub const FileMap = @This();


allocator: Allocator,

handle: Handle,
slc: []align(page_size) u8,

io_error: bool = false,

windows_map_handle: if (target_os == .windows) Handle else void,

pub const Error = switch (target_os) {
	.windows => windows.GetFileSizeError || windows.CreateFileMappingError || windows.MapViewOfFileError,
	else => os.FStatError || os.MMapError,
} || error { IO };

pub fn init(allocator: Allocator, handle: Handle) Error!*FileMap {
	return Impl.init(allocator, handle);
}

pub fn deinit(self: *FileMap) void {
	Impl.deinit(self);
}

pub fn contains(self: *FileMap, ptr: *anyopaque) bool {
	const ptr_n = @intFromPtr(ptr);
	const slc_n = @intFromPtr(self.slc.ptr);
	const buf_size = blk: {
		const ps = @as(usize, page_size);
		break :blk (self.slc.len + ps-1) & (~(ps-1));
	};

	return (ptr_n >= slc_n and ptr_n <= slc_n + buf_size);
}

pub fn handleFailure(self: *FileMap) void {
	if (@cmpxchgStrong(bool, &self.io_error, false, true, .SeqCst, .SeqCst) != null) return;
	log.warn("FileMap: handleFailure invoked.", .{});
}

/// Returns `Error.IO` if the read process triggers `SIGBUS`/`EXCEPTION_IN_PAGE_ERROR`
/// or the `io_error` flag of this `FileMap` is already set.
/// Whether `offset` is valid is only checked in Debug and ReleaseSafe modes.
/// `dest` should be outside of the mapping to be read from as they may not overlap.
pub fn read(self: *FileMap, dest: []u8, offset: u64) Error!void {
	if (self.io_error) return Error.IO;

	assert(offset < self.slc.len);
	assert(offset + dest.len <= self.slc.len);

	@memcpy(dest, self.slc[offset..offset+dest.len]);

	if (self.io_error) return Error.IO;
}

pub fn write(self: *FileMap, src: []u8, offset: u64) Error!void {
	
}


const Impl = switch (target_os) {
	.windows => WindowsImpl,
	else => UnixImpl,
};

const UnixImpl = struct {
	fn init(allocator: Allocator, handle: Handle) Error!*FileMap {
		failure.installFailureHandler();

		const size = blk: {
			const stats = try os.fstat(handle);
			break :blk @as(u64, @bitCast(stats.size));
		};

		const slc = try os.mmap(
			null,
			size,
			os.PROT.READ,
			os.MAP.PRIVATE,
			handle,
			0,
		);
		errdefer os.munmap(slc);

		const file_map = try allocator.create(FileMap);
		errdefer allocator.destroy(file_map);
		file_map.* = .{
			.allocator = allocator,
			.handle = handle,
			.slc = slc[0..size],
			.windows_map_handle = {},
		};

		try file_io.addMapping(file_map);

		return file_map;
	}

	fn deinit(self: *FileMap) void {
		os.munmap(self.slc);

		file_io.removeMapping(self);
		self.allocator.destroy(self);
	}
};

const WindowsImpl = struct {
	fn init(allocator: Allocator, handle: Handle) Error!*FileMap {
		failure.installFailureHandler();

		const size = try windows.GetFileSizeEx(handle);

		const map_handle = try windows.CreateFileMapping(
			handle,
			null,
			windows.PAGE_READONLY,
			0,
			0,
			null,
		);
		errdefer windows.CloseHandle(map_handle);

		const slc = try windows.MapViewOfFile(
			map_handle,
			windows.FILE_MAP.READ,
			0,
			0,
			0,
		);
		errdefer windows.UnmapViewOfFile(slc) catch unreachable;

		const file_map = try allocator.create(FileMap);
		errdefer allocator.destroy(file_map);
		file_map.* = .{
			.allocator = allocator,
			.handle = handle,
			.slc = @alignCast(slc[0..size]),
			.windows_map_handle = map_handle,
		};

		try file_io.addMapping(file_map);

		return file_map;
	}

	fn deinit(self: *FileMap) void {
		windows.UnmapViewOfFile(self.slc) catch unreachable;
		windows.CloseHandle(self.handle);

		file_io.removeMapping(self);
		self.allocator.destroy(self);
	}
};

test "Map file" {
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("tmp", .{ .read = true });
	defer file.close();

	const str = "Map file test.\n";

	try file.writeAll(str);

	const allocator = std.testing.allocator;

	var map = try FileMap.init(allocator, file.handle);
	defer map.deinit();

	var buf: [str.len]u8 = undefined;
	try map.read(&buf, 0);

	log.debug("{s}", .{ buf });
}

const builtin = @import("builtin");
const target_os = builtin.os.tag;
const std = @import("std");
const os = std.os;

const page_size = std.mem.page_size;
const Handle = os.fd_t;

const assert = std.debug.assert;
const log = std.log;

const windows = @import("../windows.zig");
const failure = @import("failure.zig");


pub const FileMap = @This();

slc: []align(page_size) u8,
size: u64,

io_error: bool = false,

windows_map_handle: if (target_os == .windows) Handle else void,

pub const Error = switch (target_os) {
	.windows => windows.GetFileSizeError || windows.CreateFileMappingError || windows.MapViewOfFileError,
	else => os.FStatError || os.MMapError,
} || error { IO };

pub fn init(handle: Handle) Error!FileMap {
	return Impl.init(handle);
}

pub fn deinit(self: *FileMap) void {
	Impl.deinit(self);
}

pub fn contains(self: *FileMap, ptr: *anyopaque) bool {
	const ptr_n = @intFromPtr(ptr);
	const slc_n = @intFromPtr(self.slc.ptr);
	const buf_size = blk: {
		const ps = @as(u64, page_size);
		break :blk (self.size + ps-1) & (~(ps-1));
	};

	return (ptr_n >= slc_n and ptr_n <= slc_n + buf_size);
}

pub fn handleFailure(self: *FileMap) void {
	if (@cmpxchgStrong(bool, &self.io_error, false, true, .SeqCst, .SeqCst) != null) return;
	log.warn("FileMap: handleFailure invoked.", .{});
	// Impl.handleFailure(self);
}

/// Returns Error.IO if the read process triggers SIGBUS/EXCEPTION_IN_PAGE_ERROR
/// or the io_error flag of this FileMap is already set.
/// Whether the offset is valid is only checked in Debug/ReleaseSafe mode.
/// dest should be outside of the mapping to be read from as they may not overlap.
pub fn read(self: *FileMap, dest: []u8, offset: u64) Error!void {
	if (self.io_error) return Error.IO;

	assert(offset < self.size);
	assert(offset + dest.len <= self.size);

	@memcpy(dest, self.slc[offset..offset+dest.len]);

	if (self.io_error) return Error.IO;
}


const Impl = switch (target_os) {
	.windows => WindowsImpl,
	else => UnixImpl,
};

const UnixImpl = struct {
	fn init(handle: Handle) Error!FileMap {
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

		return .{
			.slc = slc,
			.size = size,

			.windows_map_handle = {},
		};
	}

	fn deinit(self: *FileMap) void {
		os.munmap(self.slc);
	}

	// fn handleFailure(self: *FileMap) void {
	// 	_ = os.mmap(
	// 		@ptrCast(self.slc),
	// 		self.size,
	// 		os.PROT.READ,
	// 		os.MAP.PRIVATE | os.MAP.ANONYMOUS | os.MAP.FIXED,
	// 		-1,
	// 		0
	// 	) catch log.warn(
	// 		"FileMap.handleFailure: Error replacing mapped file at {any} with zeroes.\n",
	// 		.{ self.slc.ptr }
	// 	);
	// }
};

const WindowsImpl = struct {
	fn init(handle: Handle) Error!FileMap {
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

		const slc = try windows.MapViewOfFile(
			map_handle,
			windows.FILE_MAP.READ,
			0,
			0,
			0,
		);

		return .{
			.slc = slc,
			.size = size,

			.windows_map_handle = map_handle,
		};
	}

	fn deinit(self: *FileMap) void {
		windows.UnmapViewOfFile(self.slc) orelse unreachable;
		windows.CloseHandle(self.handle);
	}

	// fn handleFailure(self: *FileMap) void {
	// 	_ = self;
	// }
};

test "Map file" {
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("tmp", .{ .read = true });
	defer file.close();

	try file.writeAll("Hello this is a temporary file to test some stuff.\n");

	var map = try FileMap.init(file.handle);
	defer map.deinit();

	// var buf: [256]u8 = undefined;
	// try map.read(&buf, 0);

	// log.debug("{any}", .{ buf });
}

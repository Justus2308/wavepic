const builtin = @import("builtin");
const target_os = builtin.os.tag;
const std = @import("std");
const os = std.os;

const Allocator = std.mem.Allocator;
const File = std.fs.File;

const page_size = std.mem.page_size;
const Handle = os.fd_t;

const assert = std.debug.assert;

const windows = struct {
	usingnamespace os.windows;
	usingnamespace @import("windows_extra.zig");
};
const diff = @import("diff.zig");



const SectionMap = struct {
	slc: []align(page_size) u8,
	deltas: diff.DeltaStack,
};

pub const FileMapper = switch (target_os) {
	.windows => struct {
		allocator: Allocator,

		handle: Handle,
		size: u64,
		// Windows only
		windows_orig_handle: Handle,
		windows_obj_name: []const u8,

		const Self = @This();
		pub const Error = Allocator.Error
			// init
			|| windows.GetFileSizeError || std.fmt.AllocPrintError || windows.CreateFileMappingError
			// map
			// unmap
			|| windows.UnmapViewOfFileError;


		pub fn init(allocator: Allocator, handle: Handle) Error!Self {
			const size = try windows.GetFileSizeEx(handle);

			const tid_str = try std.fmt.allocPrint(allocator, "{d}", .{
				windows.kernel32.GetCurrentThreadId()});

			const map_handle = try windows.CreateFileMapping(
				handle,
				null,
				windows.PAGE_READWRITE,
				0,
				0,
				tid_str,
			);

			return .{
				.allocator = allocator,

				.handle = map_handle,
				.size = size,

				.windows_orig_handle = handle,
				.windows_obj_name = tid_str,
			};
		}

		pub fn deinit(self: *Self) void {
			_ = self;
			@compileError("TODO: implement deinit() for windows.\n");
		}

		pub const Options = struct {
			from: u64 = 0,
			to: ?u64 = null,
			direct: bool = false,
		};
		pub fn map(self: *Self, options: Options) Error!SectionMap {
			_ = self;
			_ = options;
			@compileError("TODO: implement map() for windows.\n");
			// Alignment is (probably) windows allocation granularity
			// which seems to be 64KiB 99% of the time.
			// There should be no problems when casting this to the
			// systems page size as it also doesn't seem to exceed
			// 64KiB (probably).
			// const slc = windows.MapViewOfFile(self.handle, TODO, TODO, TODO, TODO);

			// const deltas = diff.DeltaStack.init(self.allocator, .{});

			// return .{
			// 	.slc = @alignCast(slc),
			// 	.deltas = deltas,
			// };
		}

		/// This has to recieve the exact slice returned by map().
		pub fn unmap(slc: []align(page_size) u8) Error!void {
			try windows.UnmapViewOfFile(@ptrCast(slc));
		}

		pub fn apply(self: *Self) Error!void {
			_ = self;
		}
	},
	else => struct {
		allocator: Allocator,

		handle: Handle,
		size: u64,

		const Self = @This();
		pub const Error = Allocator.Error
			// init
			|| os.FStatError
			// map
			|| os.MMapError;
			// unmap


		pub fn init(allocator: Allocator, handle: Handle) Error!Self {
			const stats = try os.fstat(handle);

			return .{
				.allocator = allocator,

				.handle = handle,
				.size = stats.size,
			};	
		}

		pub fn deinit(self: *Self) void {
			os.munmap(self.ptr);
			self.ptr = undefined;
		}

		pub const Options = struct {
			from: u64 = 0,
			to: ?u64 = null,
			direct: bool = false,
		};
		pub fn map(self: *Self, options: Options) Error!SectionMap {
			const slc = blk: {
				const offset = options.from;
				const length = (options.to orelse self.size) - options.from;

				break :blk try os.mmap(
					null,
					@as(usize, length),
					os.PROT.READ || os.PROT.WRITE,
					if (options.direct) os.MAP.SHARED else os.MAP.PRIVATE,
					self.handle,
					offset,
				);
			};

			const deltas = diff.DeltaStack.init(self.allocator, .{});

			return .{
				.slc = slc,
				.deltas = deltas,
			};
		}

		/// This has to recieve the exact slice returned by map().
		pub fn unmap(slc: []align(page_size) u8) Error!void {
			os.munmap(slc);
		}

		pub fn apply(self: *Self) Error!void {
			try os.flock(self.fd, os.LOCK.EX);
		}
	},
};

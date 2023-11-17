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


const MapCounter = switch (builtin.mode) {
	.Debug, .ReleaseSafe => struct {
		counter: usize = 0,

		pub fn add(self: *MapCounter, n: usize) void {
			const res = @addWithOverflow(self.counter, n);
			assert(res.@"1" != @as(u1, 1));
			self.counter = res.@"0";
		}

		pub fn sub(self: *MapCounter, n: usize) void {
			const res = @subWithOverflow(self.counter, n);
			assert(res.@"1" != @as(u1, 1));
			self.counter = res.@"0";
		}

		pub fn check(self: *MapCounter, n: usize) void {
			assert(self.counter == n);
		}
	},
	else => struct {
		pub fn add(self: *MapCounter, n: usize) void { _ = self; _ = n; }
		pub fn sub(self: *MapCounter, n: usize) void { _ = self; _ = n; }
		pub fn check(self: *MapCounter, n: usize) void { _ = self; _ = n; }
	},
};


const SectionMap = switch (target_os) {
	.windows => struct {
		slc: []u8,
		offset: u64,
		deltas: diff.DeltaStack,

		/// Just don't.
		DO_NOT_TOUCH_windows_orig_slc: []align(page_size) u8,
		// DO_NOT_TOUCH_windows_slc_offset: u64, // Is this necessary? TODO
	},
	else => struct {
		slc: []align(page_size) u8,
		offset: u64,
		deltas: diff.DeltaStack,
	},
};


pub const FileMapper = switch (target_os) {
	.windows => struct {
		allocator: Allocator,

		handle: Handle,
		size: u64,

		// Debug only
		map_counter: MapCounter,

		// Windows only
		windows_orig_handle: Handle,
		windows_obj_name: []const u8,
		windows_alloc_granularity: u32,

		const Self = @This();
		pub const Error = Allocator.Error
			// init
			|| windows.GetFileSizeError || std.fmt.AllocPrintError || windows.CreateFileMappingError
			// map
			|| windows.MapViewOfFileError || diff.DeltaStack.Error
			// apply
			|| os.FlockError || os.PWriteError || error { UnknownWriteError };


		pub fn init(allocator: Allocator, handle: Handle) Error!Self {
			const size = try windows.GetFileSizeEx(handle);

			const name = blk: {
				const tid = @as(u32, windows.kernel32.GetCurrentThreadId());
				const rand = std.rand.DefaultPrng.init(0).random().int(u16);

				break :blk try std.fmt.allocPrint(allocator, "FileMapping_{d}_{d}", .{ tid, rand });
			};
			errdefer allocator.free(name);

			const map_handle = try windows.CreateFileMapping(
				handle,
				null,
				windows.PAGE_READWRITE,
				0,
				0,
				name,
			);

			
			const alloc_granularity = blk: {
				var sys_info: windows.SYSTEM_INFO = undefined;
				windows.kernel32.GetSystemInfo(&sys_info);

				assert(sys_info.dwAllocationGranularity >= page_size);
				assert(sys_info.dwAllocationGranularity % page_size == 0);

				break :blk @as(u32, sys_info.dwAllocationGranularity);
			};

			return .{
				.allocator = allocator,

				.handle = map_handle,
				.size = size,

				.windows_orig_handle = handle,
				.windows_obj_name = name,
				.windows_alloc_granularity = alloc_granularity,
			};
		}

		pub fn deinit(self: *Self) void {
			self.map_counter.check(0);

			windows.CloseHandle(self.handle);
			self.allocator.free(self.windows_obj_name);
			self.* = undefined;
		}

		pub const Options = struct {
			from: u64 = 0,
			to: ?u64 = null,
			direct: bool = false,
		};
		pub fn map(self: *Self, options: Options) Error!SectionMap {
			assert(options.from < options.to orelse self.size);

			const offset = options.from;
			// Round down to allocation granularity multiple
			const aligned_offset: u64 = offset & (~(@as(u64, self.windows_alloc_granularity) - 1));

			const slc_offset = offset - aligned_offset;

			// Alignment is (probably) windows allocation granularity
			// which seems to be 64KiB 99% of the time.
			// There should be no problems when casting this to the
			// systems page size as it also doesn't seem to exceed
			// 64KiB (probably).
			const orig_slc = blk: {
				const access = if (options.direct) windows.FILE_MAP.ALL_ACCESS
					else windows.FILE_MAP.ALL_ACCESS | windows.FILE_MAP.COPY;

				const length = (options.to orelse self.size) - options.from;

				// Every version of Windows this is ever going to run on is little
				// endian but let's check anyways because there are exceptions
				assert(builtin.cpu.arch.endian() == std.builtin.Endian.Little);

				// alternatively:
				// const HiLoU64 = packed union {
				// 	base: u64,
				// 	split: [2]u32,
				// };
				// const hi_lo = HiLoU64 { .base = aligned_offset };

				const higher: u32 = @bitCast(aligned_offset >> 32);
				const lower: u32 = @bitCast(aligned_offset & 0xFFFF_FFFF);

				break :blk try windows.MapViewOfFile(
					self.handle,
					access,
					higher,
					lower,
					length - offset,
				);
			};

			const deltas = diff.DeltaStack.init(self.allocator, .{});

			self.map_counter.add(1);

			return .{
				.slc = orig_slc[slc_offset..orig_slc.len],
				.offset = offset,
				.deltas = deltas,

				.DO_NOT_TOUCH_windows_orig_slc = @alignCast(orig_slc),
				// .DO_NOT_TOUCH_windows_slc_offset = slc_offset,
			};
		}

		pub fn unmap(self: *Self, section: SectionMap) void {
			windows.UnmapViewOfFile(@ptrCast(section.DO_NOT_TOUCH_windows_orig_slc))
				catch unreachable;
			section.deltas.deinit();

			self.map_counter.sub(1);
		}

		pub fn apply(self: *Self, section: SectionMap) Error!void {
			_ = section.deltas.mergeIntervals();

			try os.flock(self.handle, os.LOCK.EX); // ???

			var current = section.deltas.list.first;
			while (current != null) : (current = current.next) {
				const current_slc = section.slc[current.start..current.end];

				var written_byte_count = try os.pwrite(
					self.handle,
					current_slc,
					section.offset + current.start,
				);

				// Check if partial write occured and retry max 5 times if yes
				if (written_byte_count != current_slc.len) {
					for (0..5) |_| {
						written_byte_count += try os.pwrite(
							self.handle,
							current_slc[written_byte_count..current_slc.len], 
							section.offset + current.start + written_byte_count,
						);
						if (written_byte_count == current_slc.len) break;
					} else return Error.UnknownWriteError;
				}
			}

			try os.flock(self.handle, os.LOCK.UN);
		}
	},
	else => struct {
		allocator: Allocator,

		handle: Handle,
		size: u64,

		// Debug only
		map_counter: MapCounter,

		const Self = @This();
		pub const Error = Allocator.Error
			// init
			|| os.FStatError
			// map
			|| os.MMapError || diff.DeltaStack.Error
			// apply
			|| os.FlockError || os.PWriteError || error { UnknownWriteError };


		pub fn init(allocator: Allocator, handle: Handle) Error!Self {
			const stats = try os.fstat(handle);

			return .{
				.allocator = allocator,

				.handle = handle,
				.size = stats.size,
			};	
		}

		pub fn deinit(self: *Self) void {
			self.map_counter.check(0);

			self.* = undefined;
		}

		pub const Options = struct {
			from: u64 = 0,
			to: ?u64 = null,
			direct: bool = false,
		};
		pub fn map(self: *Self, options: Options) Error!SectionMap {
			assert(options.from < options.to orelse self.size);

			const offset = options.from;

			const slc = blk: {
				const length = (options.to orelse self.size) - options.from;

				break :blk try os.mmap(
					null,
					@as(usize, length),
					os.PROT.READ | os.PROT.WRITE,
					if (options.direct) os.MAP.SHARED else os.MAP.PRIVATE,
					self.handle,
					offset,
				);
			};

			const deltas = diff.DeltaStack.init(self.allocator, .{});

			self.map_counter.add(1);

			return .{
				.slc = slc,
				.offset = offset,
				.deltas = deltas,
			};
		}

		pub fn unmap(self: *Self, section: SectionMap) void {
			os.munmap(section.slc);
			section.deltas.deinit();

			self.map_counter.sub();
		}

		pub fn apply(self: *Self, section: SectionMap) Error!void {
			_ = section.deltas.mergeIntervals();

			try os.flock(self.handle, os.LOCK.EX); // ???

			var current = section.deltas.list.first;
			while (current != null) : (current = current.next) {
				const current_slc = section.slc[current.start..current.end];

				var written_byte_count = try os.pwrite(
					self.handle,
					current_slc,
					section.offset + current.start,
				);

				// Check if partial write occured and retry max 5 times if yes
				if (written_byte_count != current_slc.len) {
					for (0..5) |_| {
						written_byte_count += try os.pwrite(
							self.handle,
							current_slc[written_byte_count..current_slc.len], 
							section.offset + current.start + written_byte_count,
						);
						if (written_byte_count == current_slc.len) break;
					} else return Error.UnknownWriteError;
				}
			}

			try os.flock(self.handle, os.LOCK.UN);
		}
	},
};

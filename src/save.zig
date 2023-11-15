const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;

const assert = std.debug.assert;

const convert = @import("convert.zig");
const Fmt = convert.Fmt;

const c = @import("c.zig");

// LZ4 compression stuff
const LZ4Error = error
{
	CompressionFailed,
	DecompressionFailed
};
/// dst needs to be preallocated by the caller.
/// To be safe it should be at least compressBound(src.len) bytes long.
/// Returns number of bytes written to dst.
inline fn compress(src: []const u8, dst: []u8) LZ4Error!usize
{
	const written = c.LZ4_compress_fast(
		@ptrCast(src), @ptrCast(dst),
		@intCast(src.len), @intCast(dst.len), 1);
	return if (written <= 0) LZ4Error.CompressionFailed else @max(written, 0);
}
/// dst needs to be preallocated by the caller.
/// To be safe it should be at least decompressBound(src.len) bytes long.
/// Returns number of bytes written to dst.
inline fn decompress(src: []const u8, dst: []u8) LZ4Error!usize
{
	const written = c.LZ4_decompress_safe(
		@ptrCast(src), @ptrCast(dst),
		@intCast(src.len), @intCast(dst.len));
	return if (written < 0) LZ4Error.DecompressionFailed else @max(written, 0);
}

/// Returns maximum compressed size of input
inline fn compressBound(inputSize: usize) usize
{
	assert(inputSize <= std.math.maxInt(i32));

	return @max(c.LZ4_compressBound(@intCast(inputSize)), 0);
}
/// Returns maximum decompressed size of input
inline fn decompressBound(inputSize: usize) usize
{
	// see https://stackoverflow.com/a/25755758/20378526
	assert(inputSize >= 10);

	return (inputSize << 8) - inputSize - 2526;
}





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





test "Compress/Decompress"
{
	std.log.debug("Compress/Decompress test", .{});

	const allocator = std.testing.allocator;

	// generate data
	const data = try allocator.alloc(u8, 4096);
	defer allocator.free(data);

	var rand = std.rand.DefaultPrng.init(0);
	rand.fill(data);

	std.log.debug("Data size: {d}", .{ data.len });

	// compress
	const compress_bound = compressBound(data.len);
	const compressed_buf = try allocator.alloc(u8, compress_bound);
	defer allocator.free(compressed_buf);

	const compressed_byte_count = try compress(data, compressed_buf);
	const compressed = compressed_buf[0..@intCast(compressed_byte_count)];

	std.log.debug("Compressed size: {d}", .{ compressed_byte_count });

	// compression ration will probably be <1 here no matter the seed as
	// the data is completely random, not important for this test though

	// decompress
	const decompress_bound = @min(data.len, decompressBound(compressed.len));
	const decompressed_buf = try allocator.alloc(u8, decompress_bound);
	defer allocator.free(decompressed_buf);

	const decompressed_byte_count = try decompress(compressed, decompressed_buf);
	const decompressed = decompressed_buf[0..@intCast(decompressed_byte_count)];

	std.log.debug("Decompressed size: {d}", .{ decompressed_byte_count });

	try std.testing.expect(decompressed.len == data.len);
	try std.testing.expectEqualSlices(u8, data, decompressed);
}

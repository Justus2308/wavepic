const std = @import("std");

const assert = std.debug.assert;
const log = std.log.scoped(.lz4);

const c = @import("c.zig");


pub const LZ4Error = error {
	CompressionFailed,
	DecompressionFailed,
};
/// `dst` needs to be preallocated by the caller.
/// To be safe it should be at least `compressBound(src.len)` bytes long.
/// Returns number of bytes written to `dst`.
/// `src` and `dst` can only be `math.maxInt(c_int)` long.
pub fn compress(dst: []u8, src: []const u8) LZ4Error!usize {
	const written = c.LZ4_compress_fast(
		src.ptr, dst.ptr,
		@intCast(src.len), @intCast(dst.len), 1);
	return if (written <= 0) LZ4Error.CompressionFailed else @bitCast(@as(isize, written));
}
/// `dst` needs to be preallocated by the caller.
/// To be safe it should be at least `decompressBound(src.len)` bytes long.
/// Returns number of bytes written to `dst`.
/// `src` and `dst` can only be `math.maxInt(c_int)` long.
pub fn decompress(dst: []u8, src: []const u8) LZ4Error!usize {
	const written = c.LZ4_decompress_safe(
		src.ptr, dst.ptr,
		@intCast(src.len), @intCast(dst.len));
	return if (written < 0) LZ4Error.DecompressionFailed else @bitCast(@as(isize, written));
}

/// Returns maximum compressed size of input
pub inline fn compressBound(inputSize: usize) usize {
	return @bitCast(@as(isize, c.LZ4_compressBound(@intCast(inputSize))));
}
/// Returns maximum decompressed size of input
pub inline fn decompressBound(inputSize: usize) usize {
	// see https://stackoverflow.com/a/25755758/20378526
	assert(inputSize >= 10);

	return (inputSize << 8) - inputSize - 2526;
}


test "Compress/Decompress" {
	const allocator = std.testing.allocator;

	// generate data
	const data = try allocator.alloc(u8, 4096);
	defer allocator.free(data);

	var rand = std.rand.DefaultPrng.init(0);
	rand.fill(data);

	// compress
	const compress_bound = compressBound(data.len);
	const compressed_buf = try allocator.alloc(u8, compress_bound);
	defer allocator.free(compressed_buf);

	const compressed_byte_count = try compress(compressed_buf, data);
	const compressed = compressed_buf[0..@intCast(compressed_byte_count)];

	// compression ration will probably be <1 here no matter the seed as
	// the data is completely random, not important for this test though

	// decompress
	const decompress_bound = data.len;
	const decompressed_buf = try allocator.alloc(u8, decompress_bound);
	defer allocator.free(decompressed_buf);

	const decompressed_byte_count = try decompress(decompressed_buf, compressed);
	const decompressed = decompressed_buf[0..@intCast(decompressed_byte_count)];

	try std.testing.expect(decompressed.len == data.len);
	try std.testing.expectEqualSlices(u8, data, decompressed);
}

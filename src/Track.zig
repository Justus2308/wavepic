const builtin = @import("builtin");
const std = @import("std");
const mem = std.mem;

const page_size = mem.page_size;

const Allocator = mem.Allocator;

const assert = std.debug.assert;
const log = std.log.scoped(.track);

const FileMap = @import("file_io.zig").FileMap;


const Track = @This();
pub const Error = Allocator.Error || FileMap.Error || error { EOF };

allocator: Allocator,

map: *FileMap,

data: []u8,
buffer: std.io.FixedBufferStream(@TypeOf(Track.data)),

offset: usize,


pub const Options = struct {
	offset: usize = 0,
	lazy: bool = false,
};
pub fn init(allocator: Allocator, map: *FileMap, size: usize, options: Options) Error!Track {
	const data = try allocator.alloc(u8, size);
	errdefer allocator.free(data);
	const buffer = std.io.fixedBufferStream(data);

	if (options.lazy == false) {
		_ = try map.readWrite(buffer.writer(), options.offset, size);
	}

	return .{
		.allocator = allocator,
		.map = map,
		.data = data,
		.buffer = buffer,
		.offset = options.offset,
	};
}


/// Loads requested data from underlying `map` into internal `buffer`.
/// Returns `Error.EOF` when `offset` >= `EOF`
pub fn load(self: *Track, offset: usize, size: usize) Error!void {
	@prefetch(&self.map.slc[offset], .{ .rw = .read, .locality = 3, .cache = .data });

	if (self.offset >= offset and self.data.len - self.buffer.pos >= size) {
		self.buffer.pos = self.offset - offset;
		return;
	}

	if (offset >= self.map.slc.len) return Error.EOF;

	_ = try self.map.readWrite(self.buffer.writer(), offset, size);
}

pub fn get(self: *Track, offset: usize, size: usize) Error![]u8 {
	assert(@addWithOverflow(self.buffer.pos, size).@"1" != 1);

	try self.load(offset, size);

	return self.data[self.buffer.pos..@min(self.buffer.pos + size, self.data.len)];
}


pub fn next(self: *Track, size: usize) Error![]u8 {
	assert(@addWithOverflow(self.buffer.pos, size).@"1" != 1);

	if (self.pos + size > self.data.len -| self.pos) {
		try self.load(self.pos, size);
	}

	const requested = self.data[self.pos..size];
	self.pos += size;
	return requested;
}

pub fn jump(self: *Track, offset: usize) Error!void {
	
}

pub fn skip(self: *Track, size: usize) Error!void {
	assert(@addWithOverflow(self.offset, size).@"1" != 1);
	try self.jump(self.offset + size);
}

pub fn read(self: *Track, pos: usize, size: usize) Error![]u8 {

}

const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;


pub const LoadError = Allocator.Error || std.fs.File.SeekError || std.io.AnyReader.Error || error
{
	ReachedEOF,
};
pub const LoadFlags = struct
{
	eof: enum { ignore, fail } = .ignore,
};
/// Caller owns returned slice on success
pub fn loadPart(allocator: Allocator, file: *File, from: usize, byte_count: usize, flags: LoadFlags) LoadError![]u8
{
	try file.seekTo(from);

	var buf = try allocator.alloc(u8, byte_count);
	errdefer allocator.free(buf);

	const reader = file.reader();
	const bytes_read = try reader.readAll(buf);

	if (flags.eof == .fail and bytes_read != byte_count) return LoadError.ReachedEOF;
}

const std = @import("std");
const os = std.os;

const Allocator = std.mem.Allocator;
const File = std.fs.File;


pub const LimitError = std.os.SetrlimitError || std.os.GetrlimitError;
pub fn setDataLimit(limit: std.os.rlim_t) LimitError!void
{
	const old_limit = try std.os.getrlimit(.DATA);
	const new_limit = std.os.rlimit { .cur = limit, .max = old_limit.max };

	try std.os.setrlimit(.DATA, new_limit);
}


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


test "set DATA limit"
{
	const old = try std.os.getrlimit(.DATA);
	std.log.debug("soft: {d} | hard: {d}\n", .{ old.cur, old.max });

	try setDataLimit(old.cur - 10);

	const new = try std.os.getrlimit(.DATA);
	std.log.debug("soft: {d} | hard: {d}\n", .{ new.cur, new.max });
}

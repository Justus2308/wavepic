test {
	const testing = @import("std").testing;
	testing.log_level = .debug;
	testing.refAllDecls(@This());

	_ = @import("convert.zig");
	_ = @import("lz4.zig");
	_ = @import("util.zig");

	const file_io = @import("file_io.zig");
	_ = file_io.cache;
	// _ = file_io.DeltaStack;
	_ = file_io.failure;
	_ = file_io.FileMap;

	_ = @import("filters.zig");
	_ = @import("playback.zig");
}

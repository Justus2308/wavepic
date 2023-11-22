test {
	const testing = @import("std").testing;
	testing.log_level = .debug;
	testing.refAllDecls(@This());

	_ = @import("convert.zig");
	_ = @import("util.zig");

	_ = @import("file_io.zig");
	_ = @import("file_io/failure.zig");
	_ = @import("file_io/FileMap.zig");
}

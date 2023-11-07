test "set global testing log level"
{
	@import("std").testing.log_level = .info;
}

comptime
{
	_ = @import("convert.zig");
	_ = @import("util.zig");
	_ = @import("load.zig");
	_ = @import("save.zig");

	@import("std").testing.refAllDecls(@This());
}

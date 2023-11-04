comptime
{
	// _ = @import("util.zig");
	// _ = @import("decode.zig");
	// _ = @import("main.zig");
	_ = @import("ffmpeg.zig");
	_ = @import("util.zig");

	@import("std").testing.refAllDecls(@This());
}

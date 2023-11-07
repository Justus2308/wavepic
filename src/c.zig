const builtin = @import("builtin");

pub usingnamespace @cImport(
{
	@cInclude("unistd.h");
});

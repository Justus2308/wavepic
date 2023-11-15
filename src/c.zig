// DISCLAIMER:
// My goal with this project is to eventually
// not need to link to libc anymore.
// I am aware that this is probably not going
// to happen anytime soon but I still want to
// keep this project as zig-based as possible
// until then by only using C libs/funcs when
// there are no zig alternatives available and
// writing one myself would be unfeasable.

pub usingnamespace @cImport(
{
	// libc
	@cInclude("unistd.h");
	// external dependencies
	@cInclude("lz4.h");
});

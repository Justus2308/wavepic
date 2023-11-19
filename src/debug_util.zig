const std = @import("std");
const builtin = @import("builtin");

const mode = builtin.mode;
const assert = std.debug.assert;

const testing = std.testing;


const Counter = switch (mode) {
	.Debug, .ReleaseSafe => packed struct {
		counter: usize = 0,

		pub fn add(self: *Counter, n: usize) void {
			const res = @addWithOverflow(self.counter, n);
			assert(res.@"1" != @as(u1, 1));
			self.counter = res.@"0";
		}

		pub fn sub(self: *Counter, n: usize) void {
			const res = @subWithOverflow(self.counter, n);
			assert(res.@"1" != @as(u1, 1));
			self.counter = res.@"0";
		}

		pub fn check(self: *Counter, n: usize) void {
			assert(self.counter == n);
		}
	},
	else => packed struct {
		pub fn add(self: *Counter, n: usize) void { _ = self; _ = n; }
		pub fn sub(self: *Counter, n: usize) void { _ = self; _ = n; }
		pub fn check(self: *Counter, n: usize) void { _ = self; _ = n; }
	},
};


test "Debug Counter" {
	var my_counter = Counter {};

	comptime switch (mode) {
		.Debug, .ReleaseSafe => try testing.expect(@sizeOf(Counter) == @sizeOf(usize)),
		else => try testing.expect(@sizeOf(Counter) == 0),
	};

	my_counter.add(1);
	my_counter.add(3);
	my_counter.sub(2);
	my_counter.check(2);
}

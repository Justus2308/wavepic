const std = @import("std");
const builtin = @import("builtin");
const os = std.os;

const Allocator = std.mem.Allocator;

const testing = std.testing;

const c = @import("c.zig");
const convert = @import("convert.zig");

const log = std.log.scoped(.util);
const exec_log = std.log.scoped(.exec);


pub inline fn getPID() os.pid_t {
	return @as(os.pid_t, switch (builtin.os.tag) {
		.windows => os.windows.kernel32.GetCurrentProcessId(),
		.linux => os.linux.getpid(),
		else => c.getpid(), // replace as soon as implemented in zig
	});
}

/// Always skips a test without the compiler complaining about unreachable code.
pub inline fn alwaysSkipTest() !void {
	return error.SkipZigTest;
}


pub const ExecError = std.process.Child.RunError || error {
	WrongExitCode,
	Stderr,
};
pub const ExecFlags = struct {
	expect: ?u8 = 0, // null: exit code will be ignored
	stdout: enum { ret, log, ignore } = .ret,
	stderr: enum { fail, log, ignore } = .log,
};
/// `argv[0]` should be the name of the executable to execute.
/// On success, caller owns the returned slice if it is non-null.
/// Eval order: stderr -> exit code -> stdout.
pub fn exec(
	allocator: Allocator,
	argv: []const []const u8,
	flags: ExecFlags
) ExecError!?[]u8 {
	const res = try std.process.Child.run(.{
		.allocator = allocator,
		.argv = argv,
	});

	const stdout = res.stdout;
	const stderr = res.stderr;

	errdefer allocator.free(stdout);
	defer allocator.free(stderr);

	
	if (stderr.len != 0) switch (flags.stderr) {
		.fail => return ExecError.Stderr,
		.log => exec_log.info("{s}", .{ stderr }),
		.ignore => {},
	};

	if (flags.expect != null and res.term.Exited != flags.expect.?) {
		return ExecError.WrongExitCode;
	}

	if (stdout.len != 0) switch (flags.stdout) {
		.ret => return stdout,
		.log => exec_log.info("{s}", .{ stdout }),
		.ignore => {},
	};

	allocator.free(stdout);
	return null;
}

/// Caller owns returned slice on success
pub fn concatPath(
	allocator: Allocator,
	path_slices: []const []const u8,
	name: []const u8,
	fmt: convert.Fmt,
) Allocator.Error![]u8 {
	const slash_lit = comptime switch (builtin.os.tag) {
		.windows => '\\',
		else => '/',
	};

	const full_path = path_slices
	++ switch (path_slices[.len-1][.len-1]) {
		slash_lit => &.{},
		else => slash_lit,
	}
	++ name
	++ switch(fmt) {
		.unknown => &.{},
		else => &.{ ".", @tagName(fmt) },
	};

	return try std.mem.concat(allocator, u8, full_path);
}

pub inline fn litToArr(comptime lit: []const u8) [lit.len]u8 {
	comptime {
		var arr: [lit.len]u8 = undefined;
		@memcpy(&arr, lit);
		return arr;
	}
}

pub fn argvTokenize(allocator: Allocator, args: anytype) ![][]const u8 {
	const ArgsType = @TypeOf(args);
	const args_type_info = @typeInfo(ArgsType);
	if (args_type_info != .Struct) {
		@compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
	}

	const arg_fields = args_type_info.Struct.fields;

	var list = std.ArrayList([]const u8).init(allocator);
	errdefer list.deinit();

	comptime var i = 0;
	inline while (i < arg_fields.len) : (i += 1) {
		const arg = args[i];

		if (arg[0] == '\"') {
			try list.append(arg);
		} else {
			var tokenizer = std.mem.tokenizeScalar(u8, arg, ' ');
			while (tokenizer.next()) |t| {
				try list.append(t);
			}
		}
	}

	const slc: [][]const u8 = try list.toOwnedSlice();
	return slc;
}



test "getPID" {
	const pipe = try os.pipe();

	const child_pid = try os.fork();

	if (child_pid == 0) {
		const pid = getPID();
		const written = try os.write(pipe[1], std.mem.asBytes(&pid));
		try testing.expect(written == @sizeOf(os.pid_t));

		os.exit(0);
	}
	const wait_res = os.waitpid(child_pid, 0);
	try testing.expect(wait_res.status == 0);

	var piped_pid: os.pid_t = undefined;
	const read = try os.read(pipe[0], std.mem.asBytes(&piped_pid));
	try testing.expect(read == @sizeOf(os.pid_t));

	try testing.expect(child_pid == piped_pid);
}

test "exec 'echo' success" {
	const allocator = testing.allocator;

	const argv = [_][]const u8 { "echo", "test", };

	const out = try exec(allocator, &argv, .{ .stderr = .fail });
	defer if (out) |o| allocator.free(o);

	try testing.expect(out != null);
	try testing.expectEqualStrings("test\n", out.?);
}

test "exec 'echo' wrong exit code" {
	const allocator = testing.allocator;

	const argv = [_][]const u8 { "echo", "test", };

	const err_union = exec(allocator, &argv, .{ .expect = 1 });
	defer if (err_union) |out| { if (out) |o| allocator.free(o); } else |_| {};

	try testing.expectError(ExecError.WrongExitCode, err_union);
}

test "exec 'date abc' ignore stderr" {
	const allocator = testing.allocator;

	const argv = [_][]const u8 { "date", "abc" };

	const out = try exec(allocator, &argv, .{ .expect = 1, .stderr = .ignore });
	defer if (out) |o| allocator.free(o);
}


test "litToArr" {
	const exp = [_]u8{ 't', 'e', 's', 't' };
	const ret = litToArr("test");
	try testing.expectEqualStrings(&exp, &ret);
}

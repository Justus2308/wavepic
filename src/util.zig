const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport(
{
	@cInclude("unistd.h");
});


pub inline fn getPID() i32
{
	const pid: i32 = c.getpid();
	return pid;
}

pub inline fn litToArr(comptime lit: []const u8) [lit.len]u8
{
	comptime
	{
		var arr: [lit.len]u8 = undefined;
		@memcpy(&arr, lit);
		return arr;
	}
}


const ExecError = std.process.Child.RunError || error
{
	WrongExitCode,
	NoStdout,
	GotStderr,
};
const ExecStderrHandling = enum
{
	fail,
	log,
	ignore,
};
const ExecFlags = packed struct
{
	expect: u8 = 0,
	require_stdout: bool = false,
	stderr: ExecStderrHandling = .fail,
};
// argv[0] should be the name of the executable to execute
// on success, caller owns the returned slice if it is non-null
pub fn exec(allocator: Allocator, argv: []const []const u8, flags: ExecFlags) ExecError![]u8
{
	const res = try std.process.Child.run(.{
		.allocator = allocator,
		.argv = argv,
	});

	const out = res.stdout;
	const err = res.stderr;

	errdefer allocator.free(out);
	defer allocator.free(err);

	if (res.stderr.len != 0)
	{
		switch (flags.stderr)
		{
			.fail => return ExecError.GotStderr,
			.log => std.log.info("{s}", .{ err }),
			.ignore => {},
		}
	}

	if (res.term.Exited != flags.expect)
	{
		return ExecError.WrongExitCode;
	}

	if (out.len == 0 and flags.require_stdout)
	{
		return ExecError.NoStdout;
	}
	return out;
}

pub fn argvTokenize(allocator: Allocator, args: anytype) ![][]const u8
{
	const ArgsType = @TypeOf(args);
	const args_type_info = @typeInfo(ArgsType);
	if (args_type_info != .Struct)
	{
		@compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
	}

	const arg_fields = args_type_info.Struct.fields;

	var list = std.ArrayList([]const u8).init(allocator);
	errdefer list.deinit();

	comptime var i = 0;
	inline while (i < arg_fields.len) : (i += 1)
	{
		const arg = args[i];

		if (arg[0] == '\"')
		{
			try list.append(arg);
		}
		else
		{
			var tokenizer = std.mem.tokenizeScalar(u8, arg, ' ');
			while (tokenizer.next()) |t|
			{
				try list.append(t);
			}
		}
	}

	const slc: [][]const u8 = try list.toOwnedSlice();
	return slc;
}


test "exec 'echo' success"
{
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer std.debug.assert(gpa.deinit() == .ok);

	const allocator = gpa.allocator();

	const argv = [_][]const u8 { "echo", "test", };

	const out = try exec(allocator, &argv, .{});
	defer if (out) |o| allocator.free(o);

	const out_chars = out orelse "";
	std.log.info("{any}", .{out_chars});
}

test "exec 'echo' wrong exit code"
{
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer std.debug.assert(gpa.deinit() == .ok);

	const allocator = gpa.allocator();

	const argv = [_][]const u8 { "echo", "test", };

	const err_union = exec(allocator, &argv, .{ .expect = 1 });
	defer if (err_union) |out| { if (out) |o| allocator.free(o); } else |_| {};

	try std.testing.expectError(ExecError.WrongExitCode, err_union);
}

test "exec 'date abc' ignore stderr"
{
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer std.debug.assert(gpa.deinit() == .ok);

	const allocator = gpa.allocator();

	const argv = [_][]const u8 { "date", "abc" };

	const out = try exec(allocator, &argv, .{ .expect = 1, .stderr = .ignore });
	defer if (out) |o| allocator.free(o);
}


test "litToArr"
{
	const exp = [_]u8{ 't', 'e', 's', 't' };
	const ret = litToArr("test");
	try std.testing.expectEqualStrings(&exp, &ret);
}

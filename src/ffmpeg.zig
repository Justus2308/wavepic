const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;

const util = @import("util.zig");


pub const FFmpegError = error {
	NoFFmpeg,
	NoFFprobe,

	FFprobeFailed,
	NoChannels,
	NoBitRate,
	NoSampleRate,
	NoLayout,

	ConversionToPCMFailed,
};


pub fn ffmpegCheck(allocator: Allocator) !void
{
	@setCold(true);

	var argv = [_][]const u8 { "which", "ffmpeg", };

	// ffmpeg
	_ = util.exec(allocator, &argv, .{ .stdout = .ignore, .stderr = .ignore })
		catch return FFmpegError.NoFFmpeg;


	// ffprobe
	argv[1] = "ffprobe";

	_ = util.exec(allocator, &argv, .{ .stdout = .ignore, .stderr = .ignore })
		catch return FFmpegError.NoFFprobe;
}


pub const ChannelLayout = enum
{
	mono,
	stereo,
	unknown,

	other,
	no_audio,
};
pub const ChannelInfo = struct
{
	id: u32,
	bit_rate: u32,
	sample_rate: u32,
	layout: ChannelLayout,
};
pub fn ffprobeChannelOverview(allocator: Allocator, file_path: []const u8) ![]ChannelInfo
{
	const argv: []const []const u8 =
	&.{
		"ffprobe",
		"-i", file_path,
		"-loglevel", "error",
		"-v", "0",
		"-select_streams", "a",
		"-show_entries", "stream=index,sample_rate,channel_layout,bit_rate",
		"-of", "csv=p=0",
	};

	const out = try util.exec(allocator, argv, .{ .stderr = .fail });
	defer if (out) |o| allocator.free(o);

	const ch_info_chars = out orelse return FFmpegError.NoChannels;

	var ch_info_list = std.ArrayList(ChannelInfo).init(allocator);
	errdefer ch_info_list.deinit();

	var lf_tknzr = std.mem.tokenizeScalar(u8, ch_info_chars, '\n');
	while (lf_tknzr.next()) |line|
	{
		var comma_tknzr = std.mem.tokenizeScalar(u8, line, ',');

		const ch_info = ChannelInfo
		{
			.id = if (comma_tknzr.next()) |csv|
				try std.fmt.parseInt(u32, csv, 10)
				else return FFmpegError.NoChannels,

			.sample_rate = if (comma_tknzr.next()) |csv|
				try std.fmt.parseInt(u32, csv, 10)
				else return FFmpegError.NoSampleRate,

			.layout = if (comma_tknzr.next()) |csv|
				std.meta.stringToEnum(ChannelLayout, csv) orelse .other
				else return FFmpegError.NoLayout,

			.bit_rate = if (comma_tknzr.next()) |csv|
				try std.fmt.parseInt(u32, csv, 10)
				else return FFmpegError.NoBitRate,
		};

		try ch_info_list.append(ch_info);
	}

	return ch_info_list.toOwnedSlice();
}


pub const AudioStream = union(enum)
{
	slice: []u8,
	file: *File,
	none,

	const Self = @This();

	pub fn from(self: *Self, stream: anytype) self
	{
		comptime return switch (@TypeOf(stream))
		{
			[]u8 => self { .slice = stream },
			*File => self { .file = *File },
			else => self { .none = {} },
		};
	}
};
pub const AudioSpecs = struct
{
	stream: AudioStream,
	channel: ChannelInfo,
	len: ?f64,

	const Self = @This();

	/// no need to free anything, retval is pass by value
	pub fn init(allocator: Allocator, file_path: []const u8, channel: ChannelInfo) !Self
	{
		var arena = std.heap.ArenaAllocator.init(allocator);
		defer arena.deinit();

		const arena_alloc = arena.allocator();

		const stream_n_lit = try std.fmt.allocPrint(arena_alloc, "{d}", .{channel.id});
		const stream_lit = try std.mem.concat(arena_alloc, u8, &.{ "a:", stream_n_lit });

		const argv: []const []const u8 =
		&.{
			"ffprobe",
			"-i", file_path,
			"-loglevel", "error",
			"-v", "0",
			"-select_streams", stream_lit,
			"-show_entries", "format=duration",
			"-of", "csv=p=0",
		};

		const len_chars = try util.exec(arena_alloc, argv, .{ .stderr = .fail });
		const len: ?f64 = if (len_chars) |c| std.fmt.parseFloat(f64, c[0..c.len-1]) catch null else null;

		return Self
		{
			.stream = AudioStream { .none = {} },
			.channel = channel,
			.len = len,
		};
	}
};


pub fn ffmpegAnyToPCM(allocator: Allocator, in_file_path: []u8, cache_path: []u8, cache_file_name: []u8, overwrite: bool) !void
{
	var overwrite_flag_lit: []u8 = undefined;
	if (overwrite)
	{
		overwrite_flag_lit = comptime @constCast("-y");
	}
	else
	{
		overwrite_flag_lit = comptime @constCast("-n");
	}

	const cache_dir = try std.fs.openDirAbsolute(cache_path, .{});
	const cache_file = try cache_dir.createFile(cache_file_name, .{
		.read = true,
		.lock = .exclusive,
	});
	

	const argv = [_][]u8{
		comptime @constCast("ffmpeg"),

		// global opts
		overwrite_flag_lit,

		comptime @constCast("-loglevel"),
		comptime @constCast("error"), // only log errors to stderr

		// in opts
		comptime @constCast("-i"),
		in_file_path,

		// out opts
		comptime @constCast("-vn"), // no video
		comptime @constCast("-sn"), // no subtitles

		comptime @constCast("-f"),
		comptime @constCast("pcm"), // force pcm format

		cache_path,
	};

	const res = try std.ChildProcess.run(.{
		.allocator = allocator,
		.argv = &argv,
	});

	if (res.stderr.len != 0)
	{
		std.log.err("FFmpeg error: {s}", .{ res.stderr });
		return FFmpegError.ConversionToPCMFailed;
	}

	return cache_file;
}



test "ffmpeg check"
{
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer std.debug.assert(gpa.deinit() == .ok);

	const allocator = gpa.allocator();

	try ffmpegCheck(allocator);
}

test "ffprobeChannelOverview of mp3"
{
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer std.debug.assert(gpa.deinit() == .ok);

	const allocator = gpa.allocator();

	const info = try ffprobeChannelOverview(allocator, "./test_in/mp3_test_in.mp3");
	defer allocator.free(info);

	std.log.info("Channel overview: {any}\n", .{ info });
}

test "init AudioSpecs with channel"
{
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer std.debug.assert(gpa.deinit() == .ok);

	const allocator = gpa.allocator();

	const file_path = "./test_in/mp3_test_in.mp3";

	const ch_infos = try ffprobeChannelOverview(allocator, file_path);
	defer allocator.free(ch_infos);

	const audio_specs = try AudioSpecs.init(allocator, file_path, ch_infos[0]);
	std.log.info("{any}", .{ audio_specs });
}

// test "ffprobe"
// {
// 	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
// 	defer std.debug.assert(gpa.deinit() == .ok);

// 	const allocator = gpa.allocator();

// 	const res = try ffprobe(allocator, "./test_in/mp3_test_in.mp3");
// 	std.debug.print("{any}\n", .{res});
// 	std.debug.print("channel count: {d}\n", .{res.channels.len});
// }

// test "mp3 to PCM"
// {
// 	const cwd = std.fs.cwd();

// 	var in_buf: [2048]u8 = undefined;
// 	const in_path = try cwd.realpath("./test_in/mp3_test_in.mp3", &in_buf);

// 	var out_buf: [2048]u8 = undefined;
// 	const out_path = try cwd.realpath("./test_out/mp3_test_out.pcm", &out_buf);

// 	try ffmpegAnyToPCM(in_path, out_path, true);

// 	return error.SkipZigTest;
// }

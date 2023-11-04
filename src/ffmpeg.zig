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

	ConversionToPCMFailed,
};


pub fn ffmpegCheck() !void
{
	@setCold(true);

	const allocator = std.heap.c_allocator;

	const which_lit: []u8 = comptime @constCast("which");

	// ffmpeg
	const ffmpeg_lit: []u8 = comptime @constCast("ffmpeg");
	const argv_ffmpeg = [_][]u8{ which_lit, ffmpeg_lit };

	const res_ffmpeg = try std.ChildProcess.run(.{
		.allocator = allocator,
		.argv = &argv_ffmpeg,
	});

	if (res_ffmpeg.term.Exited != 0)
		return FFmpegError.NoFFmpeg;


	// ffprobe
	const ffprobe_lit: []u8 = comptime @constCast("ffprobe");
	const argv_ffprobe = [_][]u8{ which_lit, ffprobe_lit };

	const res_ffprobe = try std.ChildProcess.run(.{
		.allocator = allocator,
		.argv = &argv_ffprobe,
	});

	if (res_ffprobe.term.Exited != 0)
		return FFmpegError.NoFFprobe;
}


const ChannelInfo = struct
{
	id: u32,
	lang: []u8,
	layout: []u8,
};

// pub fn ffprobeChannelOverview(allocator: Allocator, file_path: []const u8) ![]ChannelInfo
// {
// 	const argv = [_][]const u8
// 	{
// 		"ffprobe",
// 		"-i", file_path,
// 		"-loglevel", "error",
// 		"-show_entries", "stream=index:stream_tags=language,"
// 	};
// }


const AudioStream = union(enum)
{
	slice: []u8,
	file: *File,
	none,

	const Self = @This();

	fn from(self: *Self, stream: anytype) self
	{
		comptime return switch (@TypeOf(stream))
		{
			[]u8 => self { .slice = stream },
			*File => self { .file = *File },
			else => self { .none = {} },
		};
	}
};
const ChannelSpecs = struct
{
	bit_rate: u32,
	sample_rate: usize,
	len: ?usize,
};
pub const AudioSpecs = struct
{
	allocator: Allocator,

	stream: AudioStream,
	channels: []ChannelSpecs,
	max_len: ?usize,

	const Self = @This();

	pub fn destroy(self: *Self) void
	{
		for (0..self.channels.len) |i|
		{
			self.allocator.free(self.channels[i]);
		}
		self.* = undefined;
	}
};
pub fn ffprobe(allocator: Allocator, file_path: []const u8) !AudioSpecs
{
	var argv = [_][]const u8
	{ 
		"ffprobe",
		"-i", undefined,
		"-loglevel", "error",
		"-v", "0",
		"-select_streams", undefined,
		"-show_entries", undefined,
		"-of", "compact=p=0:nk=1",
	};
	const argi = enum(usize)
	{
		file_path = 2,
		select_streams = 8,
		show_entries = 10,
	};

	argv[@intFromEnum(argi.file_path)] = file_path;

	// get channel count
	argv[@intFromEnum(argi.select_streams)] = "a";
	argv[@intFromEnum(argi.show_entries)] = "stream=channels";

	const channel_c_chars = try util.exec(allocator, &argv, .{ .stderr = .log });
	defer if (channel_c_chars) |c| allocator.free(c);

	// var channel_c: usize = 0;
	// const channel_list = res_channels.stdout;
	// for (channel_list) |c|
	// {
	// 	if (c == '1')
	// 	{
	// 		channel_c += 1;
	// 	}
	// }
	const channel_c = if (channel_c_chars) |c| try std.fmt.parseInt(usize, c[0..c.len-1], 10) else return FFmpegError.No;

	// get ChannelSpecs of every channel
	// var max_len = 0; // TODO
	const channels = try allocator.alloc(ChannelSpecs, channel_c);
	errdefer allocator.free(channels);

	var a = @constCast("a:_");

	for (0..channel_c) |ch|
	{
		const ch_char = std.fmt.digitToChar(@intCast(ch), .lower);
		a[2] = ch_char;
		std.debug.print("{s}", .{a});
		argv[@intFromEnum(argi.select_streams)] = a;

		// get bit rate
		argv[@intFromEnum(argi.show_entries)] = "stream=bit_rate";

		const bit_rate_chars = try util.exec(allocator, &argv, .{ .stderr = .log });
		defer if (bit_rate_chars) |c| allocator.free(c);

		const bit_rate = if (bit_rate_chars) |c| try std.fmt.parseInt(usize, c[0..c.len-1], 10) else 0;

		// get sample rate
		argv[@intFromEnum(argi.show_entries)] = "stream=sample_rate";

		const sample_rate_chars = try util.exec(allocator, argv, .{ .stderr = .log });
		defer if (sample_rate_chars) |c| allocator.free(c);

		const sample_rate = if (sample_rate_chars) |c| try std.fmt.parseInt(usize, c[0..c.len-1], 10) else 0;

		channels[ch] = .{
			.bit_rate = bit_rate,
			.sample_rate = sample_rate,
			.len = null,
		};
	}

	return AudioSpecs
	{
		.stream = AudioStream { .none = {} },
		.channels = channels,
		.max_len = null,
	};

	// const specs = try allocator.create(AudioSpecs);
	// errdefer allocator.destroy(specs);
	// specs.* = .{
	// 	.stream = stream,
	// 	.channels = channels[0..channels.len],
	// 	.max_len = null,
	// };
}

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
	try ffmpegCheck();
}

test "ffprobe"
{
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer std.debug.assert(gpa.deinit() == .ok);

	const allocator = gpa.allocator();

	const res = try ffprobe(allocator, "./test_in/mp3_test_in.mp3");
	std.debug.print("{any}\n", .{res});
	std.debug.print("channel count: {d}\n", .{res.channels.len});
}

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

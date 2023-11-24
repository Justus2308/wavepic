const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;

const testing = std.testing;

const log = std.log.scoped(.convert);

const util = @import("util.zig");


pub const Fmt = union(enum) {
	audio: AudioFmt,
	video: VideoFmt,
	image: ImageFmt,
};

pub const AudioFmt = enum {
	// lossy compressed
	aac,
	m4a,
	mp3,
	ogg,
	// lossless compressed
	alac,
	flac,
	// lossless uncompressed
	aiff,
	pcm,
	wav,

	unknown,
};
pub const VideoFmt = enum {

};
pub const ImageFmt = enum {

};

pub const CLIError = util.ExecError || error {
	NoFFmpeg,
	NoFFprobe,
};
pub fn ffmpegCheck(allocator: Allocator) CLIError!void {
	@setCold(true);

	var argv = [_][]const u8 { "which", "ffmpeg", };

	// ffmpeg
	_ = util.exec(allocator, &argv, .{ .stdout = .ignore, .stderr = .ignore })
		catch return CLIError.NoFFmpeg;


	// ffprobe
	argv[1] = "ffprobe";

	_ = util.exec(allocator, &argv, .{ .stdout = .ignore, .stderr = .ignore })
		catch return CLIError.NoFFprobe;
}

// TODO: include video and subtitle channels with stream=codec_type [audio|video|subtitle] (is in second place after index)
pub const CodecType = enum {
	video,
	audio,
	subtitle,
};
pub const ChannelLayout = enum {
	mono,
	stereo,
	unknown,

	other,
	no_audio,
};
pub const ChannelInfo = struct {
	id: u32,
	bit_rate: u32,
	sample_rate: u32,
	layout: ChannelLayout,
	// codec_type: CodecType,
};

pub const FFprobeError = std.fmt.ParseIntError || std.mem.Allocator.Error || util.ExecError || error {
	FFprobeFailed,
	NoChannels,
	NoBitRate,
	NoSampleRate,
	NoLayout,
	UnexpectedResponse,
};
pub fn ffprobeChannelOverview(allocator: Allocator, file_path: []const u8) FFprobeError![]ChannelInfo {
	const argv: []const []const u8 = &.{
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

	const ch_info_chars = out orelse return FFprobeError.NoChannels;

	var ch_info_list = std.ArrayList(ChannelInfo).init(allocator);
	errdefer ch_info_list.deinit();

	var lf_tknzr = std.mem.tokenizeScalar(u8, ch_info_chars, '\n');
	while (lf_tknzr.next()) |line| {
		var comma_tknzr = std.mem.tokenizeScalar(u8, line, ',');

		const ch_info = ChannelInfo {
			.id = if (comma_tknzr.next()) |csv|
				try std.fmt.parseInt(u32, csv, 10)
				else return FFprobeError.NoChannels,

			.sample_rate = if (comma_tknzr.next()) |csv|
				try std.fmt.parseInt(u32, csv, 10)
				else return FFprobeError.NoSampleRate,

			.layout = if (comma_tknzr.next()) |csv|
				std.meta.stringToEnum(ChannelLayout, csv) orelse .other
				else return FFprobeError.NoLayout,

			.bit_rate = if (comma_tknzr.next()) |csv|
				try std.fmt.parseInt(u32, csv, 10)
				else return FFprobeError.NoBitRate,
		};

		if (comma_tknzr.next() != null) return FFprobeError.UnexpectedResponse;

		try ch_info_list.append(ch_info);
	}

	return ch_info_list.toOwnedSlice();
}


pub const AudioStream = union(enum) {
	slice: []u8,
	file: *File,
	none,

	pub fn from(stream: anytype) AudioStream {
		comptime return switch (@TypeOf(stream)) {
			[]u8 => AudioStream { .slice = stream },
			*File => AudioStream { .file = *File },
			else => AudioStream { .none = {} },
		};
	}
};
pub const AudioSpecs = struct {
	stream: AudioStream,
	channel: ChannelInfo,
	len: ?f64,

	pub const Error = std.fmt.AllocPrintError || std.fmt.ParseFloatError || std.mem.Allocator.Error || util.ExecError;

	/// no need to free anything, retval is pass by value
	pub fn init(allocator: Allocator, file_path: []const u8, channel: ChannelInfo) Error!AudioSpecs {
		var arena = std.heap.ArenaAllocator.init(allocator);
		defer arena.deinit();

		const arena_alloc = arena.allocator();

		const stream_n_lit = try std.fmt.allocPrint(arena_alloc, "{d}", .{ channel.id });
		const stream_lit = try std.mem.concat(arena_alloc, u8, &.{ "a:", stream_n_lit });

		const argv: []const []const u8 = &.{
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

		return .{
			.stream = AudioStream { .none = {} },
			.channel = channel,
			.len = len,
		};
	}
};

pub const FFmpegError = util.ExecError || error
{
	ConversionToPCMFailed,
};
pub fn ffmpegAnyToPCM(allocator: Allocator, in_file_path: []const u8, cache_path: []const u8, cache_file_name: []const u8, overwrite: bool) !void
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

	_ = cache_file;
	

	const argv = [_][]const u8{
		"ffmpeg",

		// global opts
		overwrite_flag_lit,
		"-loglevel", "error",

		// in opts
		"-i", in_file_path,

		// out opts
		"-vn",
		"-sn",
		"-f", "pcm",

		cache_path,
	};

	_ = try util.exec(allocator, &argv, .{ .stdout = .ignore, .stderr = .fail });
}



test "ffmpeg check"
{
	const allocator = testing.allocator;

	try ffmpegCheck(allocator);
}

test "ffprobeChannelOverview of mp3" {
	const allocator = testing.allocator;

	const info = try ffprobeChannelOverview(allocator, "./test_in/mp3_test_in.mp3");
	defer allocator.free(info);

	log.info("Channel overview: {any}\n", .{ info });
}

test "init AudioSpecs with channel" {
	const allocator = testing.allocator;

	const file_path = "./test_in/mp3_test_in.mp3";

	const ch_infos = try ffprobeChannelOverview(allocator, file_path);
	defer allocator.free(ch_infos);

	const audio_specs = try AudioSpecs.init(allocator, file_path, ch_infos[0]);
	log.info("{any}", .{ audio_specs });
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

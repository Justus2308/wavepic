const c = @cImport({
	@cInclude("libavutil/opt.h");
	@cInclude("libavcodec/avcodec.h");
	@cInclude("libavformat/avformat.h");
	@cInclude("libswresample/swresample.h"); // not needed?
});

const std = @import("std");
const File = std.fs.File;


const FFmpegError = error {
	FormatContextAlloc,
	OpenInput,
	StreamInfo,
	NoAudioStream,
	NoDecoder,
	CodecContextAlloc,
	ParamsToContext,
	UnsupportedFormat,
	OpenCodec,
	PacketAlloc,
	FrameAlloc,
	ParserInit,
	ParseError,
	DecodeSubmitPacket,
	DecodeRecieveFrame,
};

const in_buf_size = 20480;
const refill_thresh = 4096;

// WIP
fn mp3Fix(pkt: *c.AVPacket) !void
{
	// find frame sync bits of mp3 header
	// and set the packet's data pointer to
	// beginning of mp3 header, otherwise
	// ffmpeg will complain

	std.debug.print("deploying mp3Fix...\n", .{});

	const frame_sync_mask_p1: u8 = 0b1111_1111;
	const frame_sync_mask_p2: u8 = 0b1110_0000;

	const len: usize = @max(pkt.*.size, 1) - 1;

	for (0..len) |i|
	{
		if (pkt.*.data[i] == frame_sync_mask_p1
			and pkt.*.data[i+1] & frame_sync_mask_p2 == frame_sync_mask_p2)
		{

			pkt.*.data += i;
			break;
		}
	}
	else return error.FaultyMP3Header;
}


fn outputAudioFrame(frame: *c.AVFrame, outfile: *const File) !void
{
	const unpadded_linesize: usize =
		@as(usize, @max(frame.*.nb_samples, 0))
		* @as(usize, @max(c.av_get_bytes_per_sample(frame.*.format), 0));

	_ = try outfile.write(frame.*.extended_data[0][0..unpadded_linesize]);
}


fn decodeAudioPkg(
	ctx: *c.AVCodecContext, pkt: *c.AVPacket, frame: *c.AVFrame,
	outfile: *const File) !void
{
	var ret: i32 = undefined;

	ret = c.avcodec_send_packet(ctx, pkt);
	if (ret < 0)
		return FFmpegError.DecodeSubmitPacket;

	while (ret >= 0)
	{
		ret = c.avcodec_receive_frame(ctx, frame);
		if (ret == c.AVERROR(c.EAGAIN) or ret == c.AVERROR_EOF)
		{
			return; // done
		}
		else if (ret < 0)
		{
			return FFmpegError.DecodeRecieveFrame;
		}

		try outputAudioFrame(frame, outfile);

		c.av_frame_unref(frame);

		// const data_size: usize = @max(c.av_get_bytes_per_sample(ctx.sample_fmt), 0);

		// for (0..@intCast(frame.nb_samples)) |i|
		// {
		// 	for (0..@intCast(ctx.ch_layout.nb_channels)) |ch|
		// 	{
		// 		const data_idx = ch + data_size*i;
		// 		const data: []u8 = frame.data[ch][data_idx..data_idx+data_size];
		// 		_ = try outfile.write(data);
		// 	}
		// }
	}
}


pub fn openAndDecode(infile_path: []const u8, outfile: *const File) !void
{
	var ret: i32 = undefined;

	const fmt_ctx = c.avformat_alloc_context();
	// defer c.avformat_free_context(fmt_ctx); // unneeded?
	if (fmt_ctx == null)
		return FFmpegError.FormatContextAlloc;

	ret = c.avformat_open_input(@ptrCast(@constCast(&fmt_ctx)), @ptrCast(infile_path), null, null);
	defer c.avformat_close_input(@ptrCast(@constCast(&fmt_ctx)));
	if (ret != 0)
		return FFmpegError.OpenInput;

	ret = c.avformat_find_stream_info(fmt_ctx, null);
	if (ret < 0)
		return FFmpegError.StreamInfo;

	var audio_stream_index = c.av_find_best_stream(fmt_ctx, c.AVMEDIA_TYPE_AUDIO, -1, -1, null, 0);
	if (audio_stream_index < 0)
		return FFmpegError.NoAudioStream;

	const codec_params = fmt_ctx.*.streams[@max(audio_stream_index, 0)].*.codecpar;

	const codec = c.avcodec_find_decoder(codec_params.?.*.codec_id);
	if (codec == null)
		return FFmpegError.NoDecoder;

	const codec_ctx = c.avcodec_alloc_context3(codec);
	defer c.avcodec_free_context(@ptrCast(@constCast(&codec_ctx)));
	if (codec_ctx == null)
		return FFmpegError.CodecContextAlloc;

	ret = c.avcodec_parameters_to_context(codec_ctx, codec_params);
	if (ret < 0)
		return FFmpegError.ParamsToContext;

	ret = c.avcodec_open2(codec_ctx, codec, null);
	if (ret < 0)
		return FFmpegError.OpenCodec;

	const pkt = c.av_packet_alloc();
	defer c.av_packet_free(@ptrCast(@constCast(&pkt)));
	if (pkt == null)
		return FFmpegError.PacketAlloc;

	const frame = c.av_frame_alloc();
	defer c.av_frame_free(@ptrCast(@constCast(&frame)));
	if (frame == null)
		return FFmpegError.FrameAlloc;

	const parser = c.av_parser_init(@intCast(codec.*.id));
	if (parser == null)
		return FFmpegError.ParserInit;


	// replace with absolute path later
	const infile = try std.fs.cwd().openFile(infile_path, .{});
	defer infile.close();

	var in_buf_reader = std.io.bufferedReader(infile.reader());
	var in_stream = in_buf_reader.reader();

	var in_buf: [in_buf_size]u8 = undefined;
	var data_pos: usize = 0;
	var data_size = try in_stream.readAll(&in_buf);

	while (data_size > 0)
	{
		ret = c.av_parser_parse2(parser, codec_ctx, &pkt.*.data, &pkt.*.size,
			@ptrCast(in_buf[data_pos..]), @intCast(data_size),
			c.AV_NOPTS_VALUE, c.AV_NOPTS_VALUE, 0);
		if (ret < 0)
			return FFmpegError.ParseError;

		data_pos += @intCast(ret);
		data_size -= @intCast(ret);

		if (pkt.*.size > 0)
			try decodeAudioPkg(codec_ctx, pkt, frame, outfile);

		if (data_size < refill_thresh)
		{
			std.mem.copyForwards(u8, &in_buf, in_buf[data_pos..]);

			data_pos = 0;

			data_size += try in_stream.readAll(in_buf[data_size..]);
		}
	}

	// flush decoder
	pkt.*.data = null;
	pkt.*.size = 0;
	try decodeAudioPkg(codec_ctx, pkt, frame, outfile);
}


test "Decode audio stream from FLAC to PCM" {
	const infile_path = @as([]const u8, "./test_in/flac_test_in.flac");
	const outfile_name = "flac_test_out.pcm";

	const outfile_dir = try std.fs.cwd().makeOpenPath("test_out", .{});
	const outfile = try outfile_dir.createFile(outfile_name, .{
			.read = true,
	});
	defer outfile.close();

	try openAndDecode(infile_path, &outfile);
}

test "Decode audio stream from wav to PCM" {
	const infile_path = @as([]const u8, "./test_in/wav_test_in.wav");
	const outfile_name = "wav_test_out.pcm";

	const outfile_dir = try std.fs.cwd().makeOpenPath("test_out", .{});
	const outfile = try outfile_dir.createFile(outfile_name, .{
			.read = true,
	});
	defer outfile.close();

	try openAndDecode(infile_path, &outfile);
}

test "Decode audio stream from mp3 to PCM" {
	const infile_path = @as([]const u8, "./test_in/mp3_test_in.mp3");
	const outfile_name = "mp3_test_out.pcm";

	const outfile_dir = try std.fs.cwd().makeOpenPath("test_out", .{});
	const outfile = try outfile_dir.createFile(outfile_name, .{
			.read = true,
	});
	defer outfile.close();

	try openAndDecode(infile_path, &outfile);
}

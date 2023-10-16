const c = @cImport({
	@cInclude("libavutil/opt.h");
	@cInclude("libavcodec/avcodec.h");
	@cInclude("libavformat/avformat.h");
	@cInclude("libswresample/swresample.h");
});

const std = @import("std");
const File = std.fs.File;

const ReadError = error {
	OpenInFile,
	FindStreamInfo,
	NoAudioStream,
	FrameAlloc,
};

const DecodeError = error {
	UnknownSampleFormat,
	SubmitPacket,
	RecieveFrame,
};

fn getSampleFmtFromName(name: [*:0]const u8) !c.AVSampleFormat
{
	const fmt: c.AVSampleFormat = c.av_get_sample_fmt(name);

	if (fmt == c.AV_SAMPLE_FMT_NONE)
		return DecodeError.UnknownSampleFormat;

	return fmt;
}

fn decode(
	ctx: *c.AVCodecContext, pkt: *c.AVPacket, frame: *c.AVFrame,
	outfile: *const File) !void
{
	var ret: i32 = 0;

	ret = c.avcodec_send_packet(ctx, pkt);
	if (ret < 0)
		return DecodeError.SubmitPacket;

	while (ret >= 0)
	{
		ret = c.avcodec_receive_frame(ctx, frame);
		if (ret == c.AVERROR(c.EAGAIN) or ret == c.AVERROR_EOF)
		{
			return; // done
		}
		else if (ret < 0)
		{
			return DecodeError.RecieveFrame;
		}

		const data_size: usize = @max(c.av_get_bytes_per_sample(ctx.sample_fmt), 0);

		for (0..@intCast(frame.nb_samples)) |i|
			for (0..@intCast(ctx.ch_layout.nb_channels)) |ch|
			{
				const data = @as(*const [data_size]c_char, frame.data[ch] + data_size*i);
				try outfile.write(data);
			};
	}

	c.av_packet_unref(pkt);
}

pub fn sampleToPCM(infile_path: [*:0]const u8, outfile: *const File) !void
{
	var ret: i32 = 0;

	const fmt_ctx = c.avformat_alloc_context();
	defer c.avformat_free_context(fmt_ctx);
	// var in_stream: ?*c.AVStream = null;

	var codec_params: ?*c.AVCodecParameters = null;
	ret = c.avformat_open_input(@ptrCast(@constCast(&fmt_ctx)), infile_path, null, null);
	if (ret != 0)
		return ReadError.OpenInFile;

	ret = c.avformat_find_stream_info(fmt_ctx, null);
	if (ret < 0)
		return ReadError.FindStreamInfo;


	var stream_index: i32 = -1;
	for (0..fmt_ctx.*.nb_streams) |i|
		if (fmt_ctx.*.streams[i].*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO)
		{
			codec_params = fmt_ctx.*.streams[i].*.codecpar;
			stream_index = @intCast(i);
			break;
		};

	const codec = c.avcodec_find_decoder(codec_params.?.codec_id);
	const codec_ctx = c.avcodec_alloc_context3(codec);
	defer c.avcodec_free_context(@ptrCast(@constCast(&codec_ctx)));

	_ = c.avcodec_parameters_to_context(codec_ctx, codec_params);

	codec_ctx.*.request_sample_fmt = c.AV_SAMPLE_FMT_DBL;

	_ = c.avcodec_open2(codec_ctx, codec, null);
	if (stream_index == -1)
		return ReadError.NoAudioStream;

	// const first_audio_stream = fmt_ctx.streams[stream_index];
	const pkt = c.av_packet_alloc();
	defer c.av_packet_free(@ptrCast(@constCast(&pkt)));

	const frame = c.av_frame_alloc();
	defer c.av_frame_free(@ptrCast(@constCast(&frame)));
	if (frame == null)
		return ReadError.FrameAlloc;

	try decode(codec_ctx, pkt, frame, outfile);
}


test "Decode audio stream from mp3 to PCM" {
    const infile_path = @as([*:0]const u8, "./test_in.mp3");
    const outfile_name = "test_out.pcm";

    const outfile = try std.fs.cwd().createFile(outfile_name, .{
    	.read = true,
    });
    defer outfile.close();

    try sampleToPCM(infile_path, &outfile);
}

const std = @import("std");
const windows = std.os.windows;
const kernel32 = windows.kernel32;

const kernel32_extra = @import("kernel32_extra.zig");

const WINAPI = windows.WINAPI;
const HANDLE = windows.HANDLE;
const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
const DWORD = windows.DWORD;
const LPCSTR = windows.LPCSTR;
const LPVOID = windows.LPVOID;
const SIZE_T = windows.SIZE_T;

pub const CreateFileMappingError = std.os.UnexpectedError;

pub fn CreateFileMapping(
	hfile: HANDLE,
	lpFileMappingAttributes: ?*SECURITY_ATTRIBUTES,
	flProtect: DWORD,
	dwMaximumSizeHigh: DWORD,
	dwMaximumSizeLow: DWORD,
	lpName: ?LPCSTR,
) CreateFileMappingError!HANDLE {
	if (kernel32_extra.CreateFileMapping(
		hfile,
		lpFileMappingAttributes,
		flProtect,
		dwMaximumSizeHigh,
		dwMaximumSizeLow,
		lpName)
	) |handle| {
		return handle;
	} else {
		const err = kernel32.GetLastError();
		return windows.unexpectedError(err);
	}
}


pub const MapViewOfFileError = std.os.UnexpectedError;

pub const MapViewOfFileOptions = struct {
	write: bool = true,
	direct: bool = false,
};

pub fn MapViewOfFile(
	hFileMappingObject: HANDLE,
	offset: u64,
	length: usize,
	options: MapViewOfFileOptions,
) MapViewOfFileError![]u8 {
	const dwFileOffsetHigh = {};
	const dwFileOffsetLow = {};
	const dwNumberOfBytesToMap = @as(SIZE_T, length);

	const dwDesiredAccess: DWORD = if (options.write) {
		windows.SECTION_MAP_READ | windows.SECTION_MAP_WRITE;
	} else {
		windows.SECTION_MAP_READ;
	};

	if (kernel32_extra.MapViewOfFile(
		hFileMappingObject,
		dwDesiredAccess,
		dwFileOffsetHigh,
		dwFileOffsetLow,
		dwNumberOfBytesToMap)
	) |ptr| {
		return @as([*]u8, @ptrCast(ptr))[0..dwNumberOfBytesToMap];
	}
}

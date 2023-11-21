const std = @import("std");

pub usingnamespace std.os.windows;
const windows = @This();

pub const kernel32 = @import("windows/kernel32.zig");

const HANDLE = windows.HANDLE;
const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
const BOOL = windows.BOOL;
const FALSE = windows.FALSE;
const DWORD = windows.DWORD;
const LPCSTR = windows.LPCSTR;
const LPVOID = windows.LPVOID;
const LPCVOID = windows.LPCVOID;
const SIZE_T = windows.SIZE_T;



pub const EXCEPTION_CONTINUE_EXECUTION = -1;
pub const EXCEPTION_IN_PAGE_ERROR = 0xC0000006;



pub const CreateFileMappingError = std.os.UnexpectedError || error {
	ObjectAlreadyExists,
	NamespaceNameClash,
};

pub fn CreateFileMapping(
	hfile: HANDLE,
	lpFileMappingAttributes: ?*SECURITY_ATTRIBUTES,
	flProtect: DWORD,
	dwMaximumSizeHigh: DWORD,
	dwMaximumSizeLow: DWORD,
	lpName: ?LPCSTR,
) CreateFileMappingError!HANDLE {
	if (kernel32.CreateFileMappingA(
		hfile,
		lpFileMappingAttributes,
		flProtect,
		dwMaximumSizeHigh,
		dwMaximumSizeLow,
		lpName,
	)) |handle| {
		return handle;
	} else {
		const err = kernel32.GetLastError();
		return switch (err) {
			.ALREADY_EXISTS => CreateFileMappingError.ObjectAlreadyExists,
			.INVALID_HANDLE => CreateFileMappingError.NamespaceNameClash,
			else => windows.unexpectedError(err),
		};
	}
}


pub const FILE_MAP = struct {
	pub const ALL_ACCESS = 0xF001F;
	pub const READ = 0x4;
	pub const WRITE = 0x2;

	pub const COPY = 0x1;
	pub const EXECUTE = 0x20;
	pub const LARGE_PAGES = 0x20000000;
	pub const TARGETS_INVALID = 0x40000000;
};


pub const MapViewOfFileError = std.os.UnexpectedError;

pub fn MapViewOfFile(
	hFileMappingObject: HANDLE,
	dwDesiredAccess: DWORD,
	dwFileOffsetHigh: DWORD,
	dwFileOffsetLow: DWORD,
	dwNumberOfBytesToMap: SIZE_T,
) MapViewOfFileError![]u8 {
	if (kernel32.MapViewOfFile(
		hFileMappingObject,
		dwDesiredAccess,
		dwFileOffsetHigh,
		dwFileOffsetLow,
		dwNumberOfBytesToMap,
	)) |ptr| {
		return @as([*]u8, @ptrCast(ptr))[0..@as(usize, dwNumberOfBytesToMap)];
	} else {
		const err = kernel32.GetLastError();
		return windows.unexpectedError(err);
	}
}


pub const FlushViewOfFileError = std.os.UnexpectedError;

pub fn FlushViewOfFile(
	lpBaseAddress: LPCVOID,
	dwNumberOfBytesToFlush: SIZE_T,
) UnmapViewOfFileError!void {
	if (kernel32.FlushViewOfFile(
		lpBaseAddress,
		dwNumberOfBytesToFlush,
	) == FALSE) {
		const err = kernel32.GetLastError();
		return windows.unexpectedError(err);
	}
}


pub const UnmapViewOfFileError = std.os.UnexpectedError;

pub fn UnmapViewOfFile(
	lpBaseAddress: LPCVOID,
) UnmapViewOfFileError!void {
	if (kernel32.UnmapViewOfFile(
		lpBaseAddress,
	) == FALSE) {
		const err = kernel32.GetLastError();
		return windows.unexpectedError(err);
	}
}

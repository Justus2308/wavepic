const std = @import("std");
const windows = std.os.windows;
const kernel32 = windows.kernel32;

const kernel32_extra = @import("windows_extra/kernel32_extra.zig");

const HANDLE = windows.HANDLE;
const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
const BOOL = windows.BOOL;
const FALSE = windows.FALSE;
const DWORD = windows.DWORD;
const LPCSTR = windows.LPCSTR;
const LPVOID = windows.LPVOID;
const LPCVOID = windows.LPCVOID;
const SIZE_T = windows.SIZE_T;


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
	if (kernel32_extra.CreateFileMappingA(
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



pub const FILE_MAP_ALL_ACCESS = windows.SECTION_MAP_READ | windows.SECTION_MAP_WRITE;
pub const FILE_MAP_READ = windows.SECTION_MAP_READ;
pub const FILE_MAP_WRITE = windows.SECTION_MAP_WRITE;


pub const MapViewOfFileError = std.os.UnexpectedError;

pub fn MapViewOfFile(
	hFileMappingObject: HANDLE,
	dwDesiredAccess: DWORD,
	dwFileOffsetHigh: DWORD,
	dwFileOffsetLow: DWORD,
	dwNumberOfBytesToMap: SIZE_T,
) MapViewOfFileError![]u8 {
	if (kernel32_extra.MapViewOfFile(
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


pub const UnmapViewOfFileError = std.os.UnexpectedError;

pub fn UnmapViewOfFile(
	lpBaseAddress: LPCVOID,
) UnmapViewOfFileError!void {
	if (kernel32_extra.UnmapViewOfFile(
		lpBaseAddress,
	) == FALSE) {
		const err = kernel32.GetLastError();
		return windows.unexpectedError(err);
	}
}

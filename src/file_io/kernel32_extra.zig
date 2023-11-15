const windows = @import("std").os.windows;

const WINAPI = windows.WINAPI;
const HANDLE = windows.HANDLE;
const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
const DWORD = windows.DWORD;
const LPCSTR = windows.LPCSTR;
const LPVOID = windows.LPVOID;
const SIZE_T = windows.SIZE_T;


pub extern "kernel32" fn CreateFileMapping(
	hfile: HANDLE,
	lpFileMappingAttributes: ?*SECURITY_ATTRIBUTES,
	flProtect: DWORD,
	dwMaximumSizeHigh: DWORD,
	dwMaximumSizeLow: DWORD,
	lpName: ?LPCSTR,
) callconv(WINAPI) ?HANDLE;
 

pub extern "kernel32" fn MapViewOfFile(
	hFileMappingObject: HANDLE,
	dwDesiredAccess: DWORD,
	dwFileOffsetHigh: DWORD,
	dwFileOffsetLow: DWORD,
	dwNumberOfBytesToMap: SIZE_T,
) callconv(WINAPI) ?LPVOID;

#!/bin/bash

cd "$(dirname "$0")"
zig build test -freference-trace -Doptimize=Debug

RECENT=./zig-cache/o/"$(ls -t ./zig-cache/o | head -1)"

lldb $RECENT/test

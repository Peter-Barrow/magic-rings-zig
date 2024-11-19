const std = @import("std");
const utils = @import("utilities.zig");

const winZig = @import("zigwin32").zig;
const winFoundation = @import("zigwin32").foundation;
const winSysInfo = @import("zigwin32").system.system_information;
const winMem = @import("zigwin32").system.memory;
const winSec = @import("zigwin32").security;

const Handle = std.os.windows.HANDLE;

fn createFileMapping(
    handle: ?Handle,
    fileMappingAttributes: ?*winSec.SECURITY_ATTRIBUTES,
    protectionFlags: winMem.PAGE_PROTECTION_FLAGS,
    sizeHigh: u32,
    sizeLow: u32,
    name: ?[*:0]const u8,
) !Handle {
    // ) winFoundation.WIN32_ERROR!Handle {

    const handle_new: ?Handle = winMem.CreateFileMappingA(
        handle,
        fileMappingAttributes,
        protectionFlags,
        sizeHigh,
        sizeLow,
        name,
    );

    if (handle_new) |h| {
        return h;
    }

    std.debug.print("createFileMapping\n", .{});
    const err: winFoundation.WIN32_ERROR = winFoundation.GetLastError();
    std.debug.print("{s}\n", .{@tagName(err)});

    return error.createFileMapping;
}

// zig fmt: off
fn openFileMapping(
    desiredAccess: u32,
    inheritHandle: bool,
    name: ?[*:0]const u8
) !Handle {
// ) winFoundation.WIN32_ERROR!Handle {
// zig fmt: on

    const inherit: winFoundation.BOOL = if (inheritHandle) winZig.TRUE else winZig.FALSE;

    const handle = winMem.OpenFileMapping(desiredAccess, inherit, name);

    if (handle) |h| {
        return h;
    }

    std.debug.print("openFileMapping", .{});
    const err: winFoundation.WIN32_ERROR = winFoundation.GetLastError();
    std.debug.print("{s}\n", .{@tagName(err)});

    return error.openFileMapping;
}

// zig fmt: off
fn mapViewOfFile(
    handle: ?Handle,
    process: ?Handle,
    baseAddress: ?*anyopaque,
    offset: u64,
    viewSize: usize,
    allocationType: winMem.VIRTUAL_ALLOCATION_TYPE,
    pageProtection: u32,
    extendedParamters: ?[*]winMem.MEM_EXTENDED_PARAMETER,
    parameterCount: u32
) ![*]u8 {
// ) winFoundation.WIN32_ERROR![*]u8 {
    // zig fmt: on

    // zig fmt: off
    const view = winMem.MapViewOfFile3(
        handle,
        process,
        baseAddress,
        offset,
        viewSize,
        allocationType,
        pageProtection,
        extendedParamters,
        parameterCount);
    // zig fmt: on

    if (view) |v| {
        return @ptrCast(v);
    }

    std.debug.print("MapViewOfFile3\n", .{});
    const err: winFoundation.WIN32_ERROR = winFoundation.GetLastError();
    std.debug.print("{s}\n", .{@tagName(err)});

    return error.mapViewOfFile;
}

// zig fmt: off
fn virtualAlloc(
    process: ?Handle,
    baseAddress: ?*anyopaque,
    size: usize,
    allocationType: winMem.VIRTUAL_ALLOCATION_TYPE,
    pageProtection: u32,
    extendedParamters: ?[*]winMem.MEM_EXTENDED_PARAMETER,
    parameterCount: u32
) ![*]u8 {
// ) winFoundation.WIN32_ERROR![*]u8 {
    // zig fmt: off

    // zig fmt: off
    const ptr = winMem.VirtualAlloc2(
        process,
        baseAddress,
        size,
        allocationType,
        pageProtection,
        extendedParamters,
        parameterCount);
    // zig fmt: on

    if (ptr) |p| {
        return @ptrCast(p);
    }

    std.debug.print("virtualAlloc\n", .{});
    const err: winFoundation.WIN32_ERROR = winFoundation.GetLastError();
    std.debug.print("{s}\n", .{@tagName(err)});

    return error.virtualAlloc;
}

fn virtualFree(
    address: ?[*]u8,
    size: usize,
    freeType: winMem.VIRTUAL_FREE_TYPE,
) !void {
    // ) winFoundation.WIN32_ERROR!void {
    var result: winFoundation.BOOL = winZig.FALSE;
    result = winMem.VirtualFree(@ptrCast(address), size, freeType);

    if (result == winZig.TRUE) {
        return;
    }

    std.debug.print("virtualFree\n", .{});
    const err: winFoundation.WIN32_ERROR = winFoundation.GetLastError();
    std.debug.print("{s}\n", .{@tagName(err)});

    return error.virtualFree;
}

// fn createOrConnectToMapping(handle: Handle, size: usize, mode: utils.BufferMode) !utils.Maps {
//     var sys_info: winSysInfo.SYSTEM_INFO = undefined;
//     winSysInfo.GetSystemInfo(&sys_info);
//
//     const flags_protection: winMem.PAGE_PROTECTION_FLAGS = switch (mode) {
//         .Owner => winMem.PAGE_READWRITE,
//         .Client => winMem.PAGE_READONLY,
//     };
//
//     if (@mod(size, sys_info.dwAllocationGranularity) != 0) {
//         return error.AllocationGranularity;
//     }
//
//     // Reserve a region of memory twice the size of the buffer we want
//     // zig fmt: off
//     var reserved_memory: [*]u8 = try virtualAlloc(
//         null,
//         null,
//         size * 2,
//         .{
//             .RESERVE = 1,
//             .RESERVE_PLACEHOLDER = 1
//         },
//         @bitCast(winMem.PAGE_NOACCESS),
//         null, 0);
//     // zig fmt: on
//
//     // Split reserved_memory into buffer and mirror
//     // try virtualFree(reserved_memory, size, winMem.MEM_RELEASE | winMem.MEM_PRESERVE_PLACEHOLDER);
//     try virtualFree(reserved_memory, 0, winMem.MEM_RELEASE);
//
//     // Take the reserved memory and map the handle into the first half
//     const proc = std.os.windows.kernel32.GetCurrentProcess();
//     // zig fmt: off
//     const map: [*]u8 = try mapViewOfFile(
//         handle,
//         proc,
//         reserved_memory,
//         0,
//         size,
//         .{
//             //.REPLACE_PLACEHOLDER = 1,
//         },
//         @bitCast(flags_protection),
//         null,
//         0);
//     // zig fmt: on
//     std.debug.print("mapped\n", .{});
//
//     // Take a pointer to the end of the reserved_memory and map it again, this time into the
//     // second half
//     // zig fmt: off
//     const mirror: [*]u8 = try mapViewOfFile(
//         handle,
//         proc,
//         @alignCast(@ptrCast(&reserved_memory[size])),
//         0,
//         size,
//         .{
//             //.REPLACE_PLACEHOLDER = 1,
//         },
//         @bitCast(flags_protection),
//         null,
//         0);
//     // zig fmt: on
//     std.debug.print("mirrored\n", .{});
//
//     return .{
//         .buffer = @alignCast(@ptrCast(map[0..size])),
//         .mirror = @alignCast(@ptrCast(mirror[0..size])),
//     };
// }

fn mapRing(handle: Handle, size: usize, protection: winMem.PAGE_PROTECTION_FLAGS) !utils.Maps {
    var sys_info: winSysInfo.SYSTEM_INFO = undefined;
    winSysInfo.GetSystemInfo(&sys_info);

    if (@mod(size, sys_info.dwAllocationGranularity) != 0) {
        return error.AllocationGranularity;
    }
    const proc = std.os.windows.kernel32.GetCurrentProcess();

    // in the connect case this needs to be a call to mapViewOfFile probably with size*2
    const reserved_memory: [*]u8 = try virtualAlloc(proc, null, size * 2, .{ .RESERVE = 1, .RESERVE_PLACEHOLDER = 1 }, @bitCast(winMem.PAGE_NOACCESS), null, 0);

    try virtualFree(reserved_memory, 0, winMem.MEM_RELEASE);

    const map: [*]u8 = try mapViewOfFile(handle, proc, reserved_memory, 0, size, .{}, @bitCast(protection), null, 0);
    std.debug.print("map made\n", .{});

    const mirror: [*]u8 = try mapViewOfFile(handle, proc, @alignCast(@ptrCast(&reserved_memory[size])), 0, size, .{}, @bitCast(protection), null, 0);
    std.debug.print("mirrored\n", .{});

    return .{
        .buffer = @alignCast(@ptrCast(map[0..size])),
        .mirror = @alignCast(@ptrCast(mirror[0..size])),
    };
}

fn createFileDesciptor(name: [*:0]const u8, size: u32) !Handle {
    // zig fmt: off
    const handle: std.os.windows.HANDLE = try createFileMapping(
        winFoundation.INVALID_HANDLE_VALUE,
        null,
        .{
            .PAGE_READWRITE = 1
        },
        0,
        size,
        name);
    // zig fmt: on
    return handle;
}

fn openFileDescriptor(name: [*:0]const u8) !Handle {
    // fn openFileDescriptor(name: []const u8) winFoundation.WIN32_ERROR!Handle {
    //  var handle: Handle = undefined;
    if (winMem.OpenFileMappingA(@bitCast(winMem.FILE_MAP_WRITE), winZig.FALSE, name)) |h| {
        return h;
    }
    const err: winFoundation.WIN32_ERROR = winFoundation.GetLastError();
    std.debug.print("{s}\n", .{@tagName(err)});

    return error.virtualFree;
}

pub fn create(name: []const u8, size: u32) !utils.MagicRingBase {

    // Create a handle for a page backed section to hold the keep a reference to the buffer
    const name_z = try utils.makeTerminatedString(name);
    const handle = try createFileDesciptor(name_z, size);

    // in the connect case this needs to be a call to mapViewOfFile probably with size*2
    // const reserved_memory: [*]u8 = try virtualAlloc(null, null, size * 2, .{ .RESERVE = 1, .RESERVE_PLACEHOLDER = 1 }, @bitCast(winMem.PAGE_NOACCESS), null, 0);
    const maps: utils.Maps = try mapRing(handle, size, winMem.PAGE_READWRITE);

    return .{
        .name = name,
        .handle = handle,
        .buffer = maps.buffer,
        .mirror = maps.mirror,
    };
}

pub fn connect(name: []const u8) !utils.MagicRingBase {
    const name_z = try utils.makeTerminatedString(name);
    const handle = try openFileDescriptor(name_z);

    var size: i64 = 0;
    const res: std.os.windows.BOOL = std.os.windows.kernel32.GetFileSizeEx(handle, @ptrCast(&size));
    _ = res;
    // if (res == std.os.kernel32.FALSE) {
    //     return error.FileSizeUnknown;
    // }

    //const reserved: [*]u8 = try mapViewOfFile(handle, null, null, 0, @intCast(size * 2), .{}, @bitCast(winMem.PAGE_READWRITE), null, 0);
    // var reserved: [*]u8 = undefined;
    // if (winMem.MapViewOfFile(handle, winMem.FILE_MAP_WRITE, 0, 0, 0)) |ptr| {
    //     reserved = @ptrCast(ptr);
    // }
    const maps: utils.Maps = try mapRing(handle, @intCast(size), winMem.PAGE_READWRITE);

    return .{
        .name = name,
        .handle = handle,
        .buffer = maps.buffer,
        .mirror = maps.mirror,
    };
}

pub fn destroy(map: *utils.MagicRingBase) void {
    if (winMem.UnmapViewOfFile(@ptrCast(map.mirror)) == winZig.FALSE) {
        //return winFoundation.GetLastError();
        return;
    }

    if (winMem.UnmapViewOfFile(@ptrCast(map.buffer)) == winZig.FALSE) {
        //return winFoundation.GetLastError();
        return;
    }

    winZig.closeHandle(map.handle);

    map.* = undefined;
}

test "windows wraparound" {
    const T = u32;
    const n: usize = 1024 * 16;
    const n_pages: usize = utils.calculateNumberOfPages(T, n);
    // const n_pages: usize = 16;

    try std.testing.expectEqual(16, n_pages);

    const n_elems: u32 = @intCast(std.mem.page_size * n_pages);

    const name: []const u8 = "testbuffer";
    var maps: utils.MagicRingBase = try create(name, n_elems);
    defer destroy(&maps);

    var map_as_T: [*]T = @ptrCast(maps.buffer);
    var buffer: []T = map_as_T[0 .. 2 * n_elems];

    for (0..n) |i| {
        buffer[i] = @intCast(i);
    }

    const midpoint = @divExact(n, 2);
    for (0..midpoint) |i| {
        buffer[i] = @intCast(i);
    }

    std.debug.print("Base cases:\n", .{});
    std.debug.print("\t{any}\n", .{buffer[0..4]});

    // ensure start of buffer is sequential
    try std.testing.expectEqualSlices(T, &[4]T{ 0, 1, 2, 3 }, buffer[0..4]);

    std.debug.print("\t{any}\n", .{buffer[n - 4 .. n]});
    // ensure end of buffer is sequential
    try std.testing.expectEqualSlices(T, &[4]T{ n - 4, n - 3, n - 2, n - 1 }, buffer[n - 4 .. n]);

    std.debug.print("\t{any}\n", .{buffer[n - 4 .. n + 4]});
    // test magic, can we wraparound?
    try std.testing.expectEqualSlices(T, &[8]T{ n - 4, n - 3, n - 2, n - 1, 0, 1, 2, 3 }, buffer[n - 4 .. n + 4]);

    for (n..n + 4) |i| {
        buffer[i] = @intCast(i);
    }

    // ensure we can write past the end of the ring buffer and wraparound
    std.debug.print("\t{any}\n", .{buffer[n - 4 .. n + 4]});
    try std.testing.expectEqualSlices(T, &[8]T{ n - 4, n - 3, n - 2, n - 1, n, n + 1, n + 2, n + 3 }, buffer[n - 4 .. n + 4]);
    std.debug.print("\t{any}\n", .{buffer[n - 2 .. n + 6]});
    try std.testing.expectEqualSlices(T, &[8]T{ n - 2, n - 1, n, n + 1, n + 2, n + 3, 4, 5 }, buffer[n - 2 .. n + 6]);

    var connection = try connect(name);
    defer destroy(&connection);
    var connection_as_T: [*]T = @ptrCast(connection.buffer);
    var connection_buffer: []T = connection_as_T[0 .. 2 * n_elems];

    // assuming that we can connect to the buffer and it has the same representation then we can compare the original and the connection
    try std.testing.expectEqualSlices(T, connection_buffer[n - 2 .. n + 6], buffer[n - 2 .. n + 6]);

    std.debug.print("mirror:\n\t{any}\nbuffer:\n\t{any}\n", .{ connection_buffer[n - 2 .. n + 6], buffer[n - 2 .. n + 6] });
}

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

    switch (std.os.windows.kernel32.GetLastError()) {
        else => |err| return std.os.windows.unexpectedError(err),
    }
}

fn openFileMapping(
    desiredAccess: u32,
    inheritHandle: bool,
    name: ?[*:0]const u8,
) !Handle {
    // ) winFoundation.WIN32_ERROR!Handle {

    const inherit: winFoundation.BOOL = if (inheritHandle) winZig.TRUE else winZig.FALSE;

    const handle = winMem.OpenFileMapping(desiredAccess, inherit, name);

    if (handle) |h| {
        return h;
    }

    switch (std.os.windows.kernel32.GetLastError()) {
        else => |err| return std.os.windows.unexpectedError(err),
    }
}

fn mapViewOfFile(
    handle: ?Handle,
    process: ?Handle,
    baseAddress: ?*anyopaque,
    offset: u64,
    viewSize: usize,
    allocationType: winMem.VIRTUAL_ALLOCATION_TYPE,
    pageProtection: u32,
    extendedParamters: ?[*]winMem.MEM_EXTENDED_PARAMETER,
    parameterCount: u32,
) ![*]u8 {
    // ) winFoundation.WIN32_ERROR![*]u8 {

    const view = winMem.MapViewOfFile3(
        handle,
        process,
        baseAddress,
        offset,
        viewSize,
        allocationType,
        pageProtection,
        extendedParamters,
        parameterCount,
    );

    if (view) |v| {
        return @ptrCast(v);
    }

    switch (std.os.windows.kernel32.GetLastError()) {
        else => |err| return std.os.windows.unexpectedError(err),
    }
}

fn virtualAlloc(
    process: ?Handle,
    baseAddress: ?*anyopaque,
    size: usize,
    allocationType: winMem.VIRTUAL_ALLOCATION_TYPE,
    pageProtection: u32,
    extendedParamters: ?[*]winMem.MEM_EXTENDED_PARAMETER,
    parameterCount: u32,
) ![*]u8 {
    // ) winFoundation.WIN32_ERROR![*]u8 {

    const ptr = winMem.VirtualAlloc2(
        process,
        baseAddress,
        size,
        allocationType,
        pageProtection,
        extendedParamters,
        parameterCount,
    );

    if (ptr) |p| {
        return @ptrCast(p);
    }

    switch (std.os.windows.kernel32.GetLastError()) {
        else => |err| return std.os.windows.unexpectedError(err),
    }
}

fn virtualFree(
    address: ?[*]u8,
    size: usize,
    freeType: winMem.VIRTUAL_FREE_TYPE,
) void {
    var result: winFoundation.BOOL = winZig.FALSE;
    result = winMem.VirtualFree(@ptrCast(address), size, freeType);

    std.debug.assert(result == winZig.TRUE);
}

fn magicRingFromHandle(
    handle: Handle,
    size: usize,
    protection: winMem.PAGE_PROTECTION_FLAGS,
) !utils.Maps {
    var sys_info: winSysInfo.SYSTEM_INFO = undefined;
    winSysInfo.GetSystemInfo(&sys_info);

    if (@mod(size, sys_info.dwAllocationGranularity) != 0) {
        return error.AllocationGranularity;
    }
    const proc = std.os.windows.kernel32.GetCurrentProcess();

    // in the connect case this needs to be a call to mapViewOfFile probably with size*2
    const reserved_memory: [*]u8 = try virtualAlloc(
        proc,
        null,
        size * 2,
        .{
            .RESERVE = 1,
            .RESERVE_PLACEHOLDER = 1,
        },
        @bitCast(winMem.PAGE_NOACCESS),
        null,
        0,
    );

    virtualFree(reserved_memory, 0, winMem.MEM_RELEASE);

    const map: [*]u8 = try mapViewOfFile(
        handle,
        proc,
        reserved_memory,
        0,
        size,
        .{},
        @bitCast(protection),
        null,
        0,
    );

    const mirror: [*]u8 = try mapViewOfFile(
        handle,
        proc,
        @alignCast(@ptrCast(&reserved_memory[size])),
        0,
        size,
        .{},
        @bitCast(protection),
        null,
        0,
    );

    return .{
        .buffer = @alignCast(@ptrCast(map[0..size])),
        .mirror = @alignCast(@ptrCast(mirror[0..size])),
    };
}

fn createFileDesciptor(name: [*:0]const u8, size: u32) !Handle {
    const handle: std.os.windows.HANDLE = try createFileMapping(
        winFoundation.INVALID_HANDLE_VALUE,
        null,
        .{
            .PAGE_READWRITE = 1,
        },
        0,
        size,
        name,
    );
    return handle;
}

pub fn create(name: []const u8, size: u32) !utils.MagicRingBase {

    // Create a handle for a page backed section to hold the keep a reference to the buffer
    var buffer: [std.fs.MAX_NAME_BYTES]u8 = undefined;
    const name_z = try std.fmt.bufPrintZ(&buffer, "{s}", .{name});
    const handle = try createFileDesciptor(name_z, size);

    const maps: utils.Maps = try magicRingFromHandle(handle, size, winMem.PAGE_READWRITE);

    return .{
        .name = name,
        .handle = handle,
        .buffer = maps.buffer,
        .mirror = maps.mirror,
    };
}

fn openFileDescriptor(name: [*:0]const u8, flags: winMem.FILE_MAP) !Handle {
    // fn openFileDescriptor(name: []const u8) winFoundation.WIN32_ERROR!Handle {
    //  var handle: Handle = undefined;
    if (winMem.OpenFileMappingA(@bitCast(flags), winZig.FALSE, name)) |h| {
        return h;
    }

    switch (std.os.windows.kernel32.GetLastError()) {
        else => |err| return std.os.windows.unexpectedError(err),
    }
}

pub fn connect(name: []const u8, access: utils.AccessMode) !utils.MagicRingBase {
    var buffer: [std.fs.MAX_NAME_BYTES]u8 = undefined;
    const name_z = try std.fmt.bufPrintZ(&buffer, "{s}", .{name});

    const flags_handle: winMem.FILE_MAP = switch (access) {
        .ReadOnly => .{
            .READ = 1,
        },
        .ReadWrite => .{
            .READ = 1,
            .WRITE = 1,
        },
    };

    const handle = try openFileDescriptor(name_z, flags_handle);

    var size: i64 = 0;
    _ = std.os.windows.kernel32.GetFileSizeEx(handle, @ptrCast(&size));

    const flags_protection: winMem.PAGE_PROTECTION_FLAGS = switch (access) {
        .ReadOnly => winMem.PAGE_READONLY,
        .ReadWrite => winMem.PAGE_READWRITE,
    };
    const maps: utils.Maps = try magicRingFromHandle(handle, @intCast(size), flags_protection);

    return .{
        .name = name,
        .handle = handle,
        .buffer = maps.buffer,
        .mirror = maps.mirror,
    };
}

pub fn close(map: *utils.MagicRingBase) !void {
    if (winMem.UnmapViewOfFile(@ptrCast(map.mirror)) == winZig.FALSE) {
        switch (std.os.windows.kernel32.GetLastError()) {
            else => |err| return std.os.windows.unexpectedError(err),
        }
    }

    if (winMem.UnmapViewOfFile(@ptrCast(map.buffer)) == winZig.FALSE) {
        switch (std.os.windows.kernel32.GetLastError()) {
            else => |err| return std.os.windows.unexpectedError(err),
        }
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

    const name: []const u8 = "testbuffer1";
    var maps: utils.MagicRingBase = try create(name, n_elems);

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
    try std.testing.expectEqualSlices(
        T,
        &[4]T{ n - 4, n - 3, n - 2, n - 1 },
        buffer[n - 4 .. n],
    );

    std.debug.print("\t{any}\n", .{buffer[n - 4 .. n + 4]});
    // test magic, can we wraparound?
    try std.testing.expectEqualSlices(
        T,
        &[8]T{ n - 4, n - 3, n - 2, n - 1, 0, 1, 2, 3 },
        buffer[n - 4 .. n + 4],
    );

    for (n..n + 4) |i| {
        buffer[i] = @intCast(i);
    }

    // ensure we can write past the end of the ring buffer and wraparound
    std.debug.print("\t{any}\n", .{buffer[n - 4 .. n + 4]});
    try std.testing.expectEqualSlices(
        T,
        &[8]T{ n - 4, n - 3, n - 2, n - 1, n, n + 1, n + 2, n + 3 },
        buffer[n - 4 .. n + 4],
    );
    std.debug.print("\t{any}\n", .{buffer[n - 2 .. n + 6]});
    try std.testing.expectEqualSlices(
        T,
        &[8]T{ n - 2, n - 1, n, n + 1, n + 2, n + 3, 4, 5 },
        buffer[n - 2 .. n + 6],
    );

    var connection = try connect(name, .ReadWrite);
    var connection_as_T: [*]T = @ptrCast(connection.buffer);
    var connection_buffer: []T = connection_as_T[0 .. 2 * n_elems];

    // assuming that we can connect to the buffer and it has the same representation then we can compare the original and the connection
    try std.testing.expectEqualSlices(
        T,
        connection_buffer[n - 2 .. n + 6],
        buffer[n - 2 .. n + 6],
    );

    std.debug.print(
        "mirror:\n\t{any}\nbuffer:\n\t{any}\n",
        .{ connection_buffer[n - 2 .. n + 6], buffer[n - 2 .. n + 6] },
    );

    for (n + 4..n + 6) |i| {
        connection_buffer[i] = @intCast(i);
    }

    std.debug.print(
        "mirror:\n\t{any}\nbuffer:\n\t{any}\n",
        .{ connection_buffer[n - 2 .. n + 6], buffer[n - 2 .. n + 6] },
    );

    try close(&connection);
    try close(&maps);
}

const std = @import("std");
const utils = @import("utilities.zig");
const tag = @import("builtin").target.os.tag;

pub const MagicRingPosixError = std.posix.MMapError || utils.MagicRingError;

fn magicRingFromFD(file_descriptor: std.posix.fd_t, size: usize, protection: u32) std.posix.MMapError!utils.Maps {
    var map = try std.posix.mmap(
        null,
        size * 2,
        protection,
        .{ .TYPE = .SHARED },
        file_descriptor,
        0,
    );
    //
    // Get pointer to last byte in mmaped region
    const end_of_map: [*]align(4096) u8 = @alignCast(@ptrCast(&map[size]));

    var mirror = try std.posix.mmap(
        end_of_map,
        size,
        protection,
        .{
            .TYPE = .SHARED,
            .FIXED = true,
        },
        file_descriptor,
        0,
    );

    std.debug.assert(&mirror[0] == &map[size]);

    return .{
        .buffer = map,
        .mirror = mirror,
    };
}

pub const CreateError =
    std.posix.OpenError || std.posix.MemFdCreateError || std.posix.TruncateError || std.posix.MMapError;

pub fn create(name: []const u8, size: u32) CreateError!utils.MagicRingBase {
    // const fd = try std.posix.open(name, .{ .CREAT = true, .EXCL = true, .ACCMODE = .RDWR }, 0o666);
    const fd = switch (tag) {
        .linux, .freebsd => try std.posix.memfd_create(name, std.posix.MFD.ALLOW_SEALING),
        else => blk: {
            const name_z = try utils.makeTerminatedString(name);
            const flags: std.c.O = .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .EXCL = true,
            };
            const new_fd = try std.c.shm_open(name_z, @bitCast(flags), 0o666);

            const err: std.posix.E = @enumFromInt(std.c._errno().*);
            switch (err) {
                .SUCCESS => break :blk new_fd,
                .ACCES => return error.AccessDenied,
                .EXIST => return error.PathAlreadyExists,
                .INVAL => unreachable,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NAMETOOLONG => return error.NameTooLong,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOENT => return error.FileNotFound,
                else => return std.posix.unexpectedErrno(err),
            }
        },
    };

    try std.posix.ftruncate(fd, @intCast(size));

    const maps: utils.Maps = try magicRingFromFD(
        fd,
        size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
    );

    var buffer: [std.fs.max_path_bytes]u8 = undefined;

    const pid = switch (tag) {
        .linux => std.os.linux.getpid(),
        else => std.c.getpid(),
    };

    const path: []u8 = std.fmt.bufPrint(&buffer, "/proc/{d}/fd/{d}", .{ pid, fd }) catch unreachable;

    return .{
        .name = name,
        .path = path,
        .handle = fd,
        .buffer = maps.buffer,
        .mirror = maps.mirror,
    };
}

pub const ConnectError = std.posix.FStatError || std.fs.File.OpenError || std.posix.MMapError;

pub fn connect(name: []const u8) ConnectError!utils.MagicRingBase {
    // const fd = try std.posix.open(name, .{ .ACCMODE = .RDWR }, 0o666);

    const handle: std.fs.File = switch (tag) {
        .linux, .freebsd => try std.fs.openFileAbsolute(name, .{}),
        else => blk: {
            const name_z = try utils.makeTerminatedString(name);
            const flags: std.c.O = .{
                .ACCMODE = .RDONLY,
            };
            const handle = try std.c.shm_open(name_z, @bitCast(flags), 0o666); // TODO: set correct octal for readonly

            const new_file: std.fs.File = .{
                .handle = handle,
            };

            const err: std.posix.E = @enumFromInt(std.c._errno().*);
            switch (err) {
                .SUCCESS => break :blk new_file,
                .ACCES => return error.AccessDenied,
                .EXIST => return error.PathAlreadyExists,
                .INVAL => unreachable,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NAMETOOLONG => return error.NameTooLong,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOENT => return error.FileNotFound,
                else => return std.posix.unexpectedErrno(err),
            }
        },
    };

    const fd = handle.handle;

    const stat = try std.posix.fstat(fd);
    const maps: utils.Maps = try magicRingFromFD(fd, @intCast(stat.size), std.posix.PROT.READ);

    return .{
        .name = name,
        .path = name,
        .handle = fd,
        .buffer = maps.buffer,
        .mirror = maps.mirror,
    };
}

pub fn close(map: *utils.MagicRingBase) std.posix.UnlinkError!void {
    std.posix.munmap(map.buffer);
    map.buffer = undefined;

    std.posix.munmap(map.mirror);
    map.mirror = undefined;

    // std.posix.close(map.handle);

    switch (tag) {
        // .linux, .freebsd => try std.posix.unlink(map.name),
        .linux, .freebsd => std.posix.close(map.handle),
        else => blk: {
            const name_z = try utils.makeTerminatedString(map.name);
            const result = std.c.shm_unlink(name_z);
            const err: std.posix.E = @enumFromInt(std.c._errno(result));
            switch (err) {
                .SUCCESS => break :blk,
                .ACCES => return error.AccessDenied,
                .PERM => return error.AccessDenied,
                .INVAL => unreachable,
                .NAMETOOLONG => return error.NameTooLong,
                .NOENT => return error.FileNotFound,
                else => return std.posix.unexpectedErrno(err),
            }
        },
    }
    map.* = undefined;
}

test "posix wraparound" {
    const T = u32;
    const n: usize = 1024;
    const n_pages: usize = utils.calculateNumberOfPages(T, n);

    try std.testing.expectEqual(1, n_pages);

    const n_elems: u32 = @intCast(std.mem.page_size * n_pages);

    const buffer_name = "testbuffer";
    var maps: utils.MagicRingBase = try create(buffer_name, n_elems);

    var map_as_T: [*]T = @ptrCast(maps.buffer);
    var buffer: []T = map_as_T[0 .. 2 * n_elems];

    for (0..n) |i| {
        buffer[i] = @intCast(i);
    }

    std.debug.print("Base cases:\n", .{});
    std.debug.print("\t{any}\n", .{buffer[0..4]});

    // ensure start of buffer is sequential
    try std.testing.expectEqualSlices(
        T,
        &[4]T{ 0, 1, 2, 3 },
        buffer[0..4],
    );

    std.debug.print("\t{any}\n", .{buffer[1020..1024]});
    // ensure end of buffer is sequential
    try std.testing.expectEqualSlices(
        T,
        &[4]T{ 1020, 1021, 1022, 1023 },
        buffer[1020..1024],
    );

    std.debug.print("\t{any}\n", .{buffer[1020..1028]});
    // test magic, can we wraparound?
    try std.testing.expectEqualSlices(
        T,
        &[8]T{ 1020, 1021, 1022, 1023, 0, 1, 2, 3 },
        buffer[1020..1028],
    );

    for (n..n + 4) |i| {
        buffer[i] = @intCast(i);
    }

    std.debug.print("\t{any}\n", .{buffer[1020..1028]});
    // ensure we can write past the end of the ring buffer and wraparound
    try std.testing.expectEqualSlices(
        T,
        &[8]T{ 1020, 1021, 1022, 1023, 1024, 1025, 1026, 1027 },
        buffer[1020..1028],
    );

    std.debug.print("\t{any}\n", .{buffer[1022..1030]});

    try std.testing.expectEqualSlices(
        T,
        &[8]T{ 1022, 1023, 1024, 1025, 1026, 1027, 4, 5 },
        buffer[1022..1030],
    );

    var connection = try connect(maps.path);
    var connection_as_T: [*]T = @ptrCast(connection.buffer);
    var connection_buffer: []T = connection_as_T[0 .. 2 * n_elems];

    // assuming that we can connect to the buffer and it has the same representation then we can compare the original and the connection
    try std.testing.expectEqualSlices(
        T,
        connection_buffer[1022..1030],
        buffer[1022..1030],
    );

    std.debug.print(
        "mirror:\n\t{any}\nbuffer:\n\t{any}\n",
        .{ connection_buffer[1022..1030], buffer[1022..1030] },
    );

    try close(&connection);
    try close(&maps);
}

const std = @import("std");
const utils = @import("utilities.zig");
const tag = @import("builtin").target.os.tag;

const config = @import("config");
const use_shm_funcs = switch (tag) {
    .linux, .freebsd => if (@hasDecl(config, "use_shm_funcs")) config.use_shm_funcs else false,
    .windows => @compileError("Windows does not support memfd_create or shm_open/shm_unlink, use Windows API\n"),
    else => true, // all other platforms that support shm_open and shm_unlink
};

const OFlags = switch (tag) {
    .linux, .freebsd => if (@hasDecl(config, "use_shm_funcs")) std.c.O else std.posix.O,
    .windows => @compileError("O_Flags not available for Windows"),
    else => std.c.O,
};

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
    const fd = if (use_shm_funcs) blk: {
        var buffer: [std.fs.MAX_NAME_BYTES]u8 = undefined;
        const name_z = try std.fmt.bufPrintZ(&buffer, "{s}", .{name});
        const flags: std.c.O = .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .EXCL = true,
        };
        const new_fd = std.c.shm_open(name_z, @bitCast(flags), 0o666);

        const err: std.posix.E = @enumFromInt(new_fd);
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
    } else blk: {
        const new_fd = try std.posix.memfd_create(name, std.posix.MFD.ALLOW_SEALING);
        break :blk new_fd;
    };

    try std.posix.ftruncate(fd, @intCast(size));

    const maps: utils.Maps = try magicRingFromFD(
        fd,
        size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
    );

    const pid = switch (tag) {
        .linux => std.os.linux.getpid(),
        else => std.c.getpid(),
    };

    return .{
        .name = name,
        .pid = if (use_shm_funcs) null else pid,
        .handle = fd,
        .buffer = maps.buffer,
        .mirror = maps.mirror,
    };
}

pub const ConnectError = std.posix.FStatError || std.fs.File.OpenError || std.posix.MMapError;

pub fn connect(name: []const u8, access: utils.AccessMode) ConnectError!utils.MagicRingBase {
    const flags: OFlags = switch (access) {
        .ReadOnly => .{
            .ACCMODE = .RDONLY,
        },
        .ReadWrite => .{
            .ACCMODE = .RDWR,
        },
    };

    const permissions: std.posix.mode_t = switch (access) {
        .ReadOnly => 0o444,
        .ReadWrite => 0o666,
    };

    const handle: std.fs.File = if (use_shm_funcs) blk: {
        var buffer: [std.fs.MAX_NAME_BYTES]u8 = undefined;
        const name_z = try std.fmt.bufPrintZ(&buffer, "{s}", .{name});
        const new_handle = std.c.shm_open(name_z, @bitCast(flags), permissions);
        const new_file: std.fs.File = .{
            .handle = new_handle,
        };

        const err: std.posix.E = @enumFromInt(new_handle);
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
    } else blk: {
        const new_handle = try std.fs.openFileAbsolute(name, .{});
        break :blk new_handle;
    };

    const fd = handle.handle;

    const stat = try std.posix.fstat(fd);

    const flags_protection: u32 = switch (access) {
        .ReadOnly => std.posix.PROT.READ,
        .ReadWrite => std.posix.PROT.READ | std.posix.PROT.WRITE,
    };
    const maps: utils.Maps = try magicRingFromFD(fd, @intCast(stat.size), flags_protection);

    return .{
        .name = name,
        .handle = fd,
        .buffer = maps.buffer,
        .mirror = maps.mirror,
    };
}

pub fn exists(name: []const u8) !void {
    const flags: OFlags = .{
        .ACCMODE = .RDONLY,
    };

    if (use_shm_funcs) {
        var buffer: [std.fs.MAX_NAME_BYTES]u8 = undefined;
        const name_z = try std.fmt.bufPrintZ(&buffer, "{s}", .{name});
        const rc = std.c.shm_open(name_z, @bitCast(flags), 0o444);
        const err: std.posix.E = @enumFromInt(rc);

        switch (err) {
            .SUCCESS => return,
            else => return error.NoMapFound,
        }
    } else {
        const handle = std.fs.openFileAbsolute(name, .{}) catch return error.NoMapFound;
        handle.close();
    }
    return;
}

pub fn close(map: *utils.MagicRingBase) std.posix.UnlinkError!void {
    std.posix.munmap(map.buffer);
    map.buffer = undefined;

    std.posix.munmap(map.mirror);
    map.mirror = undefined;

    if (use_shm_funcs) {
        var buffer: [std.fs.MAX_NAME_BYTES]u8 = undefined;
        const name_z = std.fmt.bufPrintZ(&buffer, "{s}", .{map.name}) catch unreachable;
        const rc = std.c.shm_unlink(name_z);
        const err: std.posix.E = @enumFromInt(rc);
        switch (err) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.AccessDenied,
            .INVAL => unreachable,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return, //return error.FileNotFound,
            else => return std.posix.unexpectedErrno(err),
        }
    } else {
        std.posix.close(map.handle);
    }
    map.* = undefined;
}

test "posix wraparound" {
    std.debug.print("Use shm_funcs?:\t{any}\n", .{use_shm_funcs});
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

    try std.testing.expectError(error.NoMapFound, exists("/testbuffer"));

    const mode_rw: utils.AccessMode = .ReadOnly;
    var connection = if (maps.pid) |p| blk: {
        var byte_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&byte_buffer, "/proc/{d}/fd/{d}", .{ p, maps.handle });
        try exists(path);
        const c = try connect(path, mode_rw);
        break :blk c;
    } else blk: {
        const c = try connect(maps.name, mode_rw);
        break :blk c;
    };

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

    // for (n + 2..n + 4) |i| {
    //     connection_buffer[i] = @intCast(i);
    // }

    // std.debug.print(
    //     "mirror:\n\t{any}\nbuffer:\n\t{any}\n",
    //     .{ connection_buffer[1022..1030], buffer[1022..1030] },
    // );

    try close(&connection);
    try close(&maps);
}

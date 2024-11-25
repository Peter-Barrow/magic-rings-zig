const std = @import("std");
const windows = std.os.windows;

const pz = @import("posix.zig");

const config = @import("config");
const use_shm_funcs = switch (tag) {
    .linux, .freebsd => if (@hasDecl(config, "use_shm_funcs")) config.use_shm_funcs else false,
    .windows => false,
    else => true, // all other platforms that support shm_open and shm_unlink
};

const tag = @import("builtin").target.os.tag;

pub fn SharedMemory(comptime T: type) type {
    return struct {
        const Self = @This();

        handle: std.fs.File.Handle,
        name: []const u8,
        size: usize,
        ptr: ?[]align(4096) u8,
        data: []T,

        pub fn create(name: []const u8, count: usize) !Self {
            const size = count * @sizeOf(T);
            const result: Shared = switch (tag) {
                .linux, .freebsd => blk: {
                    // const _create = comptime if (use_shm_funcs) createPosix else createMemfdBased;
                    // break :blk try _create(name, size);
                    if (use_shm_funcs) {
                        break :blk try createPosix(name, size);
                    }
                    break :blk try createMemfdBased(name, size);
                },
                .windows => try createWindows(name, size),
                else => try createPosix(name, size),
            };
            const data: []T = @as([*]T, @ptrCast(@alignCast(result.data.ptr)))[0..count];
            return .{
                .handle = result.fd,
                .name = name,
                .size = count,
                .ptr = result.data,
                .data = data,
            };
        }

        pub fn open(name: []const u8) !Self {
            const result = switch (tag) {
                .linux, .freebsd => blk: {
                    // const _open = comptime if (use_shm_funcs) openPosix else openMemfdBased;
                    // break :blk try _open(name);
                    if (use_shm_funcs) {
                        break :blk try openPosix(name);
                    }
                    break :blk try openMemfdBased(name);
                },
                .windows => try openWindows(name),
                else => try openPosix(name),
            };
            const count = @divExact(result.size, @sizeOf(T));
            const data: []T = @as([*]T, @ptrCast(@alignCast(result.data.ptr)))[0..count];
            return .{
                .handle = result.fd,
                .name = name,
                .size = count,
                .ptr = result.data,
                .data = data,
            };
        }

        pub fn close(self: *Self) void {
            switch (tag) {
                .linux, .freebsd => closeMemfdBased(self.ptr, self.handle),
                // .windows => closeWindows(self),
                else => closePosix(self.ptr, self.handle, self.name),
            }
        }
    };
}

const Shared = struct {
    data: []align(4096) u8,
    size: usize,
    fd: std.fs.File.Handle,
};

fn createMemfdBased(name: []const u8, size: usize) !Shared {
    const fd = try std.posix.memfd_create(name, 0);

    try std.posix.ftruncate(fd, size);

    const ptr = try std.posix.mmap(
        null,
        size,
        @intCast(std.posix.PROT.READ | std.posix.PROT.WRITE),
        .{ .TYPE = .SHARED },
        fd,
        0,
    );

    return .{
        .data = ptr,
        .size = size,
        .fd = fd,
    };
}

fn openMemfdBased(name: []const u8) !Shared {
    const handle = try std.fs.openFileAbsolute(name, .{});
    const fd = handle.handle;
    const stat = try std.posix.fstat(fd);
    const flags_protection: u32 = std.posix.PROT.READ;

    const ptr = try std.posix.mmap(
        null,
        @intCast(stat.size),
        flags_protection,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );

    return .{
        .data = ptr,
        .size = @intCast(stat.size),
        .fd = fd,
    };
}

fn closeMemfdBased(ptr: ?[]u8, fd: std.fs.File.Handle) void {
    if (ptr) |p| std.posix.munmap(@alignCast(p));
    std.posix.close(fd);
}

fn createPosix(name: []const u8, size: usize) !Shared {
    const permissions: std.posix.mode_t = 0o666;
    const flags: std.posix.O = .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .EXCL = true,
    };

    var buffer = [_]u8{0} ** std.fs.MAX_NAME_BYTES;
    const name_z = try std.fmt.bufPrintZ(&buffer, "{s}", .{name});
    const fd = std.c.shm_open(name_z, @bitCast(flags), permissions);

    try std.posix.ftruncate(fd, @intCast(size));

    const flags_protection: u32 = std.posix.PROT.READ | std.posix.PROT.WRITE;

    const ptr = try std.posix.mmap(
        null,
        @intCast(size),
        flags_protection,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );

    return .{
        .data = ptr,
        .size = size,
        .fd = fd,
    };
}

fn openPosix(name: []const u8) !Shared {
    const permissions: std.posix.mode_t = 0o666;
    const flags: std.posix.O = .{
        .ACCMODE = .RDWR,
    };

    var buffer = [_]u8{0} ** std.fs.MAX_NAME_BYTES;
    const name_z = try std.fmt.bufPrintZ(&buffer, "{s}", .{name});
    const fd = std.c.shm_open(name_z, @bitCast(flags), permissions);
    if (fd == -1) {
        const err_no: u32 = @bitCast(std.c._errno().*);
        const err: std.posix.E = @enumFromInt(err_no);
        switch (err) {
            .SUCCESS => @panic("Success"),
            .ACCES => return error.AccessDenied,
            .EXIST => return error.PathAlreadyExists,
            .INVAL => unreachable,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOENT => return error.FileNotFound,
            else => return std.posix.unexpectedErrno(err),
        }
    }

    const stat = try std.posix.fstat(fd);

    const flags_protection: u32 = std.posix.PROT.READ | std.posix.PROT.WRITE;

    const ptr = try std.posix.mmap(
        null,
        @intCast(stat.size),
        flags_protection,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );

    return .{
        .data = ptr,
        .size = @intCast(stat.size),
        .fd = fd,
    };
}

fn closePosix(ptr: ?[]u8, fd: std.fs.File.Handle, name: []const u8) void {
    if (ptr) |p| std.posix.munmap(@alignCast(p));

    std.posix.close(fd);

    var buffer = [_]u8{0} ** std.fs.MAX_NAME_BYTES;
    const name_z = std.fmt.bufPrintZ(&buffer, "{s}", .{name}) catch unreachable;
    const rc = std.c.shm_unlink(name_z);
    if (rc != -1) {
        const err_no = std.c._errno().*;
        const err: std.posix.E = @enumFromInt(err_no);
        switch (err) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.AccessDenied,
            .INVAL => unreachable,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return, //return error.FileNotFound,
            else => return std.posix.unexpectedErrno(err),
        }
    }
}

fn createWindows(name: []const u8, size: usize) !Shared {
    const handle = try windows.CreateFileMappingW(
        windows.INVALID_HANDLE_VALUE,
        null,
        windows.PAGE_READWRITE,
        0,
        @intCast(size),
        name,
    );

    const ptr = try windows.MapViewOfFile(handle, windows.FILE_MAP_ALL_ACCESS, 0, 0, size);

    return .{
        .data = ptr,
        .size = size,
        .fd = handle,
    };
}

fn openWindows(name: []const u8, size: usize) !Shared {
    const handle = try windows.OpenFileMappingW(windows.FILE_MAP_ALL_ACCESS, false, name);

    const ptr = try windows.MapViewOfFile(handle, windows.FILE_MAP_ALL_ACCESS, 0, 0, size);

    return .{
        .data = ptr,
        .size = size,
        .fd = handle,
    };
}

fn closeWindows(self: *Shared) void {
    if (self.ptr) |ptr| _ = windows.UnmapViewOfFile(ptr);
    windows.CloseHandle(self.handle);
    self.* = undefined;
}

test "SharedMemory - Single Struct" {
    const TestStruct = struct {
        x: i32,
        y: f64,
    };
    const SharedStruct = SharedMemory(TestStruct);

    const shm_name = "/test_single_struct";
    const count = 1;

    // if (pz.exists(shm_name)) {
    //     _ = std.c.shm_unlink(shm_name);
    // }

    var shm: SharedStruct = try SharedStruct.create(shm_name, count);
    defer shm.close();

    shm.data[0] = .{ .x = 42, .y = 3.14 };

    // Open the shared memory in another "process"
    var buffer = [_]u8{0} ** std.fs.MAX_NAME_BYTES;
    const pid = switch (tag) {
        .linux => std.os.linux.getpid(),
        .windows => 0,
        else => std.c.getpid(),
    };
    const path = try std.fmt.bufPrint(&buffer, "/proc/{d}/fd/{d}", .{ pid, shm.handle });

    var shm2 = switch (tag) {
        .linux, .freebsd => blk: {
            if (use_shm_funcs) {
                break :blk try SharedStruct.open(shm_name);
            } else {
                break :blk try SharedStruct.open(path);
            }
        },
        .windows => try SharedStruct.open(shm_name),
        else => try SharedStruct.open(shm_name),
    };
    defer shm2.close();

    try std.testing.expectEqual(@as(i32, 42), shm2.data[0].x);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), shm2.data[0].y, 0.001);
}

test "SharedMemory - Array" {
    const array_size = 10;

    const shm_name = "/test_array";
    // if (pz.exists(shm_name)) {
    //     _ = std.c.shm_unlink(shm_name);
    // }

    var shm = try SharedMemory(i32).create(shm_name, array_size);
    defer shm.close();

    for (shm.data, 0..) |*item, i| {
        item.* = @intCast(i * 2);
    }

    // Open the shared memory in another "process"
    var buffer = [_]u8{0} ** std.fs.MAX_NAME_BYTES;
    const pid = switch (tag) {
        .linux => std.os.linux.getpid(),
        .windows => 0,
        else => std.c.getpid(),
    };
    const path = try std.fmt.bufPrint(&buffer, "/proc/{d}/fd/{d}", .{ pid, shm.handle });

    var shm2 = switch (tag) {
        .linux, .freebsd => blk: {
            if (use_shm_funcs) {
                break :blk try SharedMemory(i32).open(shm_name);
            } else {
                break :blk try SharedMemory(i32).open(path);
            }
        },
        .windows => try SharedMemory(i32).open(shm_name),
        else => try SharedMemory(i32).open(shm_name),
    };
    defer shm2.close();

    for (shm2.data, 0..) |item, i| {
        try std.testing.expectEqual(@as(i32, @intCast(i * 2)), item);
    }
}

test "SharedMemory - Structure with Array" {
    const TestStruct = struct {
        id: i32,
        float: f64,
        string: [20]u8,
    };

    const shm_name = "/test_struct_with_array";
    const count = 1;
    // if (pz.exists(shm_name)) {
    //     _ = std.c.shm_unlink(shm_name);
    // }

    var shm = try SharedMemory(TestStruct).create(shm_name, count);
    defer shm.close();

    shm.data[0].id = 42;
    shm.data[0].float = 3.14;
    _ = try std.fmt.bufPrint(&shm.data[0].string, "Hello, SHM!", .{});

    // Open the shared memory in another "process"
    var buffer = [_]u8{0} ** std.fs.MAX_NAME_BYTES;
    const pid = switch (tag) {
        .linux => std.os.linux.getpid(),
        .windows => 0,
        else => std.c.getpid(),
    };
    const path = try std.fmt.bufPrint(&buffer, "/proc/{d}/fd/{d}", .{ pid, shm.handle });

    var shm2 = switch (tag) {
        .linux, .freebsd => blk: {
            if (use_shm_funcs) {
                break :blk try SharedMemory(TestStruct).open(shm_name);
            } else {
                break :blk try SharedMemory(TestStruct).open(path);
            }
        },
        .windows => try SharedMemory(TestStruct).open(shm_name),
        else => try SharedMemory(TestStruct).open(shm_name),
    };
    defer shm2.close();

    try std.testing.expectEqual(@as(i32, 42), shm2.data[0].id);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), shm2.data[0].float, 0.001);
    try std.testing.expectEqualStrings("Hello, SHM!", std.mem.sliceTo(&shm2.data[0].string, 0));
}

const std = @import("std");
const os = std.os;
const windows = std.os.windows;

const tag = @import("builtin").target.os.tag;

pub fn SharedMemory(comptime T: type) type {
    return struct {
        handle: std.fs.File.Handle,
        size: usize,
        ptr: ?[*]u8,
        data: []T,

        pub fn create(name: []const u8, count: usize) !@This() {
            const size = count * @sizeOf(T);
            var shm = switch (tag) {
                .linux, .freebsd => try createMemfdBased(name, size),
                .windows => try createWindows(name, size),
                else => try createPosix(name, size),
            };
            shm.data = @as([*]T, @ptrCast(shm.ptr.?))[0..count];
            return shm;
        }

        pub fn open(name: []const u8, count: usize) !@This() {
            const size = count * @sizeOf(T);
            var shm = switch (tag) {
                .linux, .freebsd => try openMemfdBased(name, size),
                .windows => try openWindows(name, size),
                else => try openPosix(name, size),
            };
            shm.data = @as([*]T, @ptrCast(shm.ptr.?))[0..count];
            return shm;
        }

        pub fn close(self: *@This()) void {
            switch (tag) {
                .linux, .freebsd => closeMemfdBased(self),
                .windows => closeWindows(self),
                else => closePosix(self),
            }
        }
    };
}

const Shared = struct {
    data: [*]u8,
    size: usize,
    fd: std.fs.File.Handle,
};

fn createMemfdBased(name: []const u8, size: usize) !Shared {
    const fd = try os.memfd_create(name, 0);

    try os.ftruncate(fd, size);

    const ptr = try os.mmap(null, size, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED, fd, 0);

    return .{
        .data = ptr,
        .size = size,
        .fd = fd,
    };
}

fn openMemfdBased(name: []const u8, size: usize) !Shared {
    // For memfd, opening is the same as creating
    return createMemfdBased(name, size);
}

fn closeMemfdBased(self: *Shared) void {
    if (self.ptr) |ptr| os.munmap(ptr[0..self.size]);
    os.close(self.handle);
    self.* = undefined;
}

fn createPosix(name: []const u8, size: usize) !Shared {
    const fd = try os.shm_open(name, os.O.CREAT | os.O.RDWR, 0o666);

    try os.ftruncate(fd, @intCast(size));

    const ptr = try os.mmap(null, size, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED, fd, 0);

    return .{
        .data = ptr,
        .size = size,
        .fd = fd,
    };
}

fn openPosix(name: []const u8, size: usize) !Shared {
    const fd = try os.shm_open(name, os.O.RDWR, 0o666);

    const ptr = try os.mmap(null, size, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED, fd, 0);

    return .{
        .data = ptr,
        .size = size,
        .fd = fd,
    };
}

fn closePosix(self: *Shared) void {
    if (self.ptr) |ptr| os.munmap(ptr[0..self.size]);
    os.close(self.handle);
    self.* = undefined;
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

    const shm_name = "test_single_struct";
    const count = 1;

    var shm = try SharedMemory(TestStruct).create(shm_name, count);
    defer shm.close();

    shm.data[0] = .{ .x = 42, .y = 3.14 };

    // Open the shared memory in another "process"
    var shm2 = try SharedMemory(TestStruct).open(shm_name, count);
    defer shm2.close();

    try std.testing.expectEqual(@as(i32, 42), shm2.data[0].x);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), shm2.data[0].y, 0.001);
}

test "SharedMemory - Array" {
    const array_size = 10;

    const shm_name = "test_array";

    var shm = try SharedMemory(i32).create(shm_name, array_size);
    defer shm.close();

    for (shm.data, 0..) |*item, i| {
        item.* = @intCast(i * 2);
    }

    // Open the shared memory in another "process"
    var shm2 = try SharedMemory(i32).open(shm_name, array_size);
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

    const shm_name = "test_struct_with_array";
    const count = 1;

    var shm = try SharedMemory(TestStruct).create(shm_name, count);
    defer shm.close();

    shm.data[0].id = 42;
    shm.data[0].float = 3.14;
    _ = try std.fmt.bufPrint(&shm.data[0].string, "Hello, SHM!", .{});

    // Open the shared memory in another "process"
    var shm2 = try SharedMemory(TestStruct).open(shm_name, count);
    defer shm2.close();

    try std.testing.expectEqual(@as(i32, 42), shm2.data[0].id);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), shm2.data[0].float, 0.001);
    try std.testing.expectEqualStrings("Hello, SHM!", std.mem.sliceTo(&shm2.data[0].string, 0));
}

const std = @import("std");
const utils = @import("utilities.zig");

pub const MagicRingPosixError = std.posix.MMapError || utils.MagicRingError;

fn createMapping(file_descriptor: std.posix.fd_t, size: usize) !utils.Maps {
    try std.posix.ftruncate(file_descriptor, size);
    return mapRing(file_descriptor, size, std.posix.PROT.READ | std.posix.PROT.WRITE);
}

fn connectMapping(file_descriptor: std.posix.fd_t) !utils.Maps {
    const stat = try std.posix.fstat(file_descriptor);

    return mapRing(file_descriptor, @intCast(stat.size), std.posix.PROT.READ);
}

fn mapRing(file_descriptor: std.posix.fd_t, size: usize, protection: u32) !utils.Maps {
    // zig fmt: off
    var map = try std.posix.mmap(
        null,
        size * 2,
        protection,
        .{ .TYPE = .SHARED },
        file_descriptor,
        0
    );
    // zig fmt: on
    //
    // Get pointer to last byte in mmaped region
    const end_of_map: [*]align(4096) u8 = @alignCast(@ptrCast(&map[size]));

    var mirror = try std.posix.mmap(end_of_map, size, protection, .{
        .TYPE = .SHARED,
        .FIXED = true,
    }, file_descriptor, 0);

    if (&mirror[0] != &map[size]) {
        return MagicRingPosixError.MapsNotAdjacent;
    }

    return .{
        .buffer = map,
        .mirror = mirror,
    };
}

pub fn create(name: []const u8, size: u32) !utils.MagicRingBase {
    const fd = try std.posix.open(name, .{ .CREAT = true, .EXCL = true, .ACCMODE = .RDWR }, 0o666);
    try std.posix.ftruncate(fd, @intCast(size));

    const maps: utils.Maps = try createMapping(fd, size);

    return .{
        .name = name,
        .handle = fd,
        .buffer = maps.buffer,
        .mirror = maps.mirror,
    };
}

pub fn connect(name: []const u8) !utils.MagicRingBase {
    const fd = try std.posix.open(name, .{ .ACCMODE = .RDWR }, 0o666);
    const maps: utils.Maps = try connectMapping(fd);

    return .{
        .name = name,
        .handle = fd,
        .buffer = maps.buffer,
        .mirror = maps.mirror,
    };
}

pub fn destroy(map: *utils.MagicRingBase) void {
    std.posix.munmap(map.buffer);
    map.buffer = undefined;

    std.posix.munmap(map.mirror);
    map.mirror = undefined;

    std.posix.close(map.handle);

    // BUG: this is not the way to handle this
    std.posix.unlink(map.name) catch |err| {
        // std.debug.print("{any}\n", .{err});
        if (err == error.FileNotFound) {
            // if this happend the file had already been cleared up
        }
    };

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
    defer destroy(&maps);

    var map_as_T: [*]T = @ptrCast(maps.buffer);
    var buffer: []T = map_as_T[0 .. 2 * n_elems];

    for (0..n) |i| {
        buffer[i] = @intCast(i);
    }

    std.debug.print("Base cases:\n", .{});
    std.debug.print("\t{any}\n", .{buffer[0..4]});

    // ensure start of buffer is sequential
    try std.testing.expectEqualSlices(T, &[4]T{ 0, 1, 2, 3 }, buffer[0..4]);

    std.debug.print("\t{any}\n", .{buffer[1020..1024]});
    // ensure end of buffer is sequential
    try std.testing.expectEqualSlices(T, &[4]T{ 1020, 1021, 1022, 1023 }, buffer[1020..1024]);

    std.debug.print("\t{any}\n", .{buffer[1020..1028]});
    // test magic, can we wraparound?
    try std.testing.expectEqualSlices(T, &[8]T{ 1020, 1021, 1022, 1023, 0, 1, 2, 3 }, buffer[1020..1028]);

    for (n..n + 4) |i| {
        buffer[i] = @intCast(i);
    }

    std.debug.print("\t{any}\n", .{buffer[1020..1028]});
    // ensure we can write past the end of the ring buffer and wraparound
    try std.testing.expectEqualSlices(T, &[8]T{ 1020, 1021, 1022, 1023, 1024, 1025, 1026, 1027 }, buffer[1020..1028]);
    std.debug.print("\t{any}\n", .{buffer[1022..1030]});
    try std.testing.expectEqualSlices(T, &[8]T{ 1022, 1023, 1024, 1025, 1026, 1027, 4, 5 }, buffer[1022..1030]);

    var connection = try connect(buffer_name);
    defer destroy(&connection);
    var connection_as_T: [*]T = @ptrCast(connection.buffer);
    var connection_buffer: []T = connection_as_T[0 .. 2 * n_elems];

    // assuming that we can connect to the buffer and it has the same representation then we can compare the original and the connection
    try std.testing.expectEqualSlices(T, connection_buffer[1022..1030], buffer[1022..1030]);
}

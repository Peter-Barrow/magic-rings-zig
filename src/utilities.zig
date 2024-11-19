const std = @import("std");

pub const Maps = struct {
    buffer: []align(std.mem.page_size) u8,
    mirror: []align(std.mem.page_size) u8,
};

pub const MagicRingBase = struct {
    name: []const u8,
    path: ?[]const u8 = null,
    handle: std.fs.File.Handle,
    buffer: []align(std.mem.page_size) u8,
    mirror: []align(std.mem.page_size) u8,
};

pub const BufferMode = enum {
    Owner,
    Client,
};

pub const MagicRingError = error{
    MapsNotAdjacent,
};

/// Calculate the number of pages required to fit "count" elemnts of type T
pub fn calculateNumberOfPages(comptime T: type, count: u32) u32 {
    const size_elem: u32 = @sizeOf(T);
    const total_bytes = size_elem * count;

    var total_pages: u32 = @divFloor(total_bytes, std.mem.page_size);

    // If our element and count are less than or larger than an integer multiple of pages then we
    // must add one extra page
    if (@mod(total_bytes, std.mem.page_size) != 0) {
        total_pages += 1;
    }

    return total_pages;
}

test calculateNumberOfPages {
    const T = u32;

    // request less than a page of u32s. expect 1-page of memory
    var requested_elems: u32 = 100;
    var minimum_number_of_pages = calculateNumberOfPages(T, requested_elems);
    try std.testing.expectEqual(1, minimum_number_of_pages);

    // request 1-page of u32. expect 1-page of memory
    requested_elems = 1000;
    minimum_number_of_pages = calculateNumberOfPages(T, requested_elems);
    try std.testing.expectEqual(1, minimum_number_of_pages);

    // request 2-pages of bytes. expect 2-pages of memory
    requested_elems = 2000;
    minimum_number_of_pages = calculateNumberOfPages(T, requested_elems);
    try std.testing.expectEqual(2, minimum_number_of_pages);

    // request 1500 u32a. expect 2-pages of memory
    requested_elems = 1500;
    minimum_number_of_pages = calculateNumberOfPages(T, requested_elems);
    try std.testing.expectEqual(2, minimum_number_of_pages);
}

pub fn makeTerminatedString(name: []const u8) ![*:0]const u8 {
    var buffer: [std.fs.MAX_NAME_BYTES]u8 = undefined;
    const name_z = try std.fmt.bufPrintZ(&buffer, "{s}", .{name});
    return name_z;
}

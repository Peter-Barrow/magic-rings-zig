const std = @import("std");

const magic_ring = switch (@import("builtin").target.os.tag) {
    .linux, .freebsd => @import("platforms/posix.zig"),
    .windows => @import("platforms/windows.zig"),
    else => @compileError("Platform not supported"),
};

const Map = @import("platforms/utilities.zig").MagicRingBase;
const Mode = @import("platforms/utilities.zig").AccessMode;

pub fn MagicRing(comptime T: type) type {
    return struct {
        const Self = @This();
        const elem_size: u32 = @intCast(@sizeOf(T));

        magic: Map,
        data: []T,
        capacity: usize,
        count: usize,

        pub fn new(num_elems: u32, name: []const u8) !Self {
            const size_in_bytes: u32 = num_elems * elem_size;
            const magic = try magic_ring.create(name, size_in_bytes);
            var data_as_manyT: [*]T = @ptrCast(magic.buffer);

            return .{
                .magic = magic,
                .data = data_as_manyT[0 .. 2 * num_elems],
                .capacity = num_elems,
                .count = 0,
            };
        }

        pub fn destroy(self: *Self) !void {
            try magic_ring.close(&self.magic);
        }

        pub fn connect(name: []const u8, mode: Mode) !Self {
            const magic = try magic_ring.connect(name, mode);
            var data_as_manyT: [*]T = @ptrCast(magic.buffer);
            const num_elems = @divExact(magic.buffer.len, elem_size);

            return .{
                .magic = magic,
                .data = data_as_manyT[0 .. 2 * num_elems],
                .capacity = num_elems,
                .count = 0,
            };
        }

        pub fn slice(self: *Self, start: usize, stop: usize) ![]T {
            if (start > stop) {
                return error.StartAfterStop;
            }

            const absolute_start = @mod(start, self.capacity);
            const total = stop - start;
            const absolute_stop = absolute_start + total;

            return self.data[absolute_start..absolute_stop];
        }

        pub fn slice_const(self: *Self, start: usize, stop: usize) ![]const T {
            if (start > stop) {
                return error.StartAfterStop;
            }

            const absolute_start = @mod(start, self.capacity);
            const total = stop - start;
            const absolute_stop = absolute_start + total;

            return @ptrCast(self.data[absolute_start..absolute_stop]);
        }

        pub fn push(self: *Self, data: []T) !usize {
            if (data.len > self.capacity) {
                return error.LargerThanBuffer;
            }

            var buffer_section = self.slice(self.capacity, self.capacity + data.len);
            @memcpy(&buffer_section, data);

            return data.len;
        }

        pub fn zero(self: *Self) void {
            for (0..self.capacity) |i| {
                self.data[i] = undefined;
            }
            self.count = 0;
        }
    };
}

test {
    _ = magic_ring;
}

const std = @import("std");
const shared_memory = @import("shared_memory");

const tag = @import("builtin").target.os.tag;

pub const State = struct {
    count: u64,
    head: u64,
    tail: u64,

    pub fn withFields(comptime H: type) type {
        const fields_state = @typeInfo(@This()).@"struct".fields;
        const fields_header = @typeInfo(H).@"struct".fields;

        const num_fields = fields_state.len + fields_header.len;
        comptime var fields: [num_fields]std.builtin.Type.StructField = undefined;

        inline for (fields_state, 0..) |field, i| {
            fields[i] = field;
        }

        inline for (fields_header, fields_state.len..num_fields) |field, i| {
            fields[i] = field;
        }

        const Header: std.builtin.Type = .{
            .@"struct" = .{
                .layout = .auto,
                .fields = &fields,
                .decls = &.{},
                .is_tuple = false,
            },
        };

        return @Type(Header);
    }
};

test State {
    const Extra = struct { resolution: f64, num_fields: u32 };
    const Header = State.withFields(Extra);

    inline for (@typeInfo(State).@"struct".fields) |field| {
        try std.testing.expect(@hasField(Header, field.name));
    }

    inline for (@typeInfo(Extra).@"struct".fields) |field| {
        try std.testing.expect(@hasField(Extra, field.name));
    }
}

/// Creates a magic ring buffer type with a customizable header.
///
/// A magic ring buffer is a circular buffer that uses virtual memory mapping
/// to create the illusion of a contiguous buffer that wraps around at the end.
/// This implementation maps the physical buffer to two consecutive virtual memory
/// regions, allowing operations to seamlessly span the buffer boundary without
/// special handling for wraparound.
///
/// The head and tail pointers can range from 0 to 2*len and use modulo arithmetic
/// to ensure proper wraparound behavior. When the buffer contains data, head > tail,
/// and when the buffer is full, head - tail = len.
///
/// Parameters:
/// - T: The type of elements stored in the buffer
/// - H: An extra fields struct type to be added to the State header
///
/// Returns:
/// - A struct type that implements the magic ring buffer with customizable header fields
///
/// Example:
/// ```
/// const Extra = struct { resolution: f64, num_fields: u32 };
/// const Ring = MagicRingWithHeader(u64, Extra);
/// var ring = try Ring.create("my_buffer", 1024, allocator);
/// defer ring.close() catch {};
///
/// // Push values
/// _ = ring.push(42);
///
/// // Access the extra header fields
/// ring.header.resolution = 44100.0;
/// ```
pub fn MagicRingWithHeader(comptime T: type, comptime H: type) type {
    return struct {
        const Self = @This();
        const Header = State.withFields(H);
        const ElemSize = @sizeOf(T);
        const HeaderSize = @sizeOf(Header);

        /// Optional allocator used for memory management
        allocator: ?std.mem.Allocator = null,

        /// Name of the shared memory region
        name: []const u8,

        /// Platform-specific ring buffer info
        buffer_info: RingBufferInfo,

        /// Pointer to the header with State and custom fields
        header: *Header,

        /// Slice representing the ring buffer with virtual wraparound mapping
        ring_buffer: []T,

        /// Actual capacity of the buffer (aligned to page size)
        len: u64,

        /// Creates a new magic ring buffer with the specified parameters.
        ///
        /// Parameters:
        /// - name: Name of the shared memory region
        /// - length: Requested number of elements (actual size may be larger due to alignment)
        /// - allocator: Optional allocator for memory management
        ///
        /// Returns:
        /// - A new MagicRingWithHeader instance
        ///
        /// Errors:
        /// - error.SharedMemoryExists: A shared memory region with the given name already exists
        /// - Various platform-specific errors
        pub fn create(name: []const u8, length: usize, allocator: ?std.mem.Allocator) !Self {
            if (shared_memory.SharedMemory(T).exists(name, allocator)) {
                return error.SharedMemoryExists;
            }

            const ring_buffer = switch (tag) {
                .linux, .freebsd => blk: {
                    if (@import("builtin").link_libc) {
                        break :blk try posixCreateRingBufferWithHeader(name, ElemSize, length, HeaderSize);
                    }
                    break :blk try memfdCreateRingBufferWithHeader(allocator.?, name, ElemSize, length, HeaderSize);
                    // } else {
                    //     @compileError("Must supply allocator or link libc\n");
                    // }
                },
                .windows => try windowsCreateRingBufferWithHeader(name, ElemSize, length, HeaderSize),
                else => try posixCreateRingBufferWithHeader(name, ElemSize, length, HeaderSize),
            };

            return .{
                .allocator = allocator,
                .name = name,
                .buffer_info = ring_buffer,
                .header = @ptrCast(@alignCast(ring_buffer.header.ptr)),
                .ring_buffer = combinedRingBufferFromBytes(
                    T,
                    ring_buffer.combined_buffer.ptr,
                    ring_buffer.layout.actual_element_count,
                ),
                .len = ring_buffer.layout.actual_element_count,
            };
        }

        /// Opens an existing magic ring buffer.
        ///
        /// Parameters:
        /// - name: Name of the shared memory region to open
        /// - allocator: Optional allocator for memory management
        ///
        /// Returns:
        /// - A MagicRingWithHeader instance connected to the existing buffer
        ///
        /// Errors:
        /// - error.SharedMemoryDoesNotExist: No shared memory region with the given name exists
        /// - Various platform-specific errors
        pub fn open(name: []const u8, allocator: ?std.mem.Allocator) !Self {
            if (shared_memory.SharedMemory(T).exists(name, allocator) == false) {
                return error.SharedMemoryDoesNotExist;
            }

            const length: usize = 0;

            const ring_buffer = try switch (tag) {
                .linux, .freebsd => blk: {
                    if (@import("builtin").link_libc) {
                        break :blk posixOpenRingBuffer(name, ElemSize, length, HeaderSize);
                    }
                    if (allocator) |alloca| {
                        break :blk memfdOpenRingBuffer(alloca, name, ElemSize, length, HeaderSize);
                    }
                    @compileError("Must supply allocator or link libc\n");
                },
                .windows => windowsOpenRingBuffer(name, ElemSize, length, HeaderSize),
                else => posixOpenRingBuffer(name, ElemSize, length, HeaderSize),
            };

            return .{
                .allocator = allocator,
                .name = name,
                .buffer_info = ring_buffer,
                .header = @ptrCast(@alignCast(ring_buffer.header.ptr)),
                .ring_buffer = combinedRingBufferFromBytes(
                    T,
                    ring_buffer.combined_buffer.ptr,
                    ring_buffer.layout.actual_element_count,
                ),
                .len = ring_buffer.layout.actual_element_count,
            };
        }

        /// Closes the magic ring buffer and cleans up resources.
        ///
        /// Errors:
        /// - Platform-specific errors during resource cleanup
        pub fn close(self: *Self) !void {
            switch (tag) {
                .linux, .freebsd => {
                    if (@import("builtin").link_libc) {
                        try posixCloseRingBuffer(&self.buffer_info);
                        return;
                    }
                    try memfdCloseRingBuffer(self.allocator.?, &self.buffer_info);
                },
                .windows => try windowsCloseRingBuffer(&self.buffer_info),
                else => try posixCloseRingBuffer(&self.buffer_info),
            }
        }

        /// Resets the head, tail and count of the buffer
        pub fn reset(self: *Self) void {
            self.header.head = 0;
            self.header.tail = 0;
            self.header.count = 0;
        }

        /// Returns the current state of the buffer in terms of count and head/tail positions
        pub fn currentState(self: *Self) State {
            return .{
                .count = self.header.count,
                .head = self.header.head,
                .tail = self.header.tail,
            };
        }

        /// Gets a slice of the buffer from start to stop positions.
        ///
        /// This can seamlessly span the physical buffer boundary due to the
        /// "magic" memory mapping.
        ///
        /// Parameters:
        /// - start: Starting logical position
        /// - stop: Ending logical position (exclusive)
        ///
        /// Returns:
        /// - A slice of the buffer from start to stop
        pub fn slice(self: *Self, start: usize, stop: usize) []T {
            const left = @mod(start, self.ring_buffer.len);
            std.debug.assert(left >= @mod(self.header.tail, self.len));
            const length = stop - start;
            std.debug.assert(length <= self.len);
            const right = left + length;
            return self.ring_buffer[left..right];
        }

        /// Gets a slice of the oldest elements in the buffer, starting from the tail.
        ///
        /// Parameters:
        /// - count: Number of elements to include in the slice
        ///
        /// Returns:
        /// - A slice of the oldest elements, up to count
        pub fn sliceFromTail(self: *Self, count: u64) []T {
            std.debug.assert(count <= self.len);
            const left = @mod(self.header.tail, self.len);
            const right = left + count;
            return self.ring_buffer[left..right];
        }

        /// Gets a slice of the newest elements in the buffer, ending at the head.
        ///
        /// Parameters:
        /// - count: Number of elements to include in the slice
        ///
        /// Returns:
        /// - A slice of the newest elements, up to count
        pub fn sliceToHead(self: *Self, count: u64) []T {
            const right = self.header.head;
            std.debug.assert(count <= self.header.count);
            const left = right - count;
            return self.ring_buffer[left..right];
        }

        /// Gets the value at the specified logical index.
        ///
        /// Parameters:
        /// - index: Logical index relative to the tail (0 = oldest element)
        ///
        /// Returns:
        /// - The value at the specified index
        pub fn valueAt(self: *Self, index: u64) T {
            std.debug.assert(index < self.header.count);
            const idx = @mod(index, self.len);
            return self.ring_buffer[idx];
        }

        /// Pushes a single value to the buffer.
        ///
        /// When the buffer is full, this will overwrite the oldest element.
        ///
        /// Parameters:
        /// - value: Value to push to the buffer
        ///
        /// Returns:
        /// - The new count of elements pushed to the buffer (cumulative)
        pub fn push(self: *Self, value: T) u64 {
            const index: u64 = @mod(self.header.count, self.len);
            self.ring_buffer[index] = value;

            self.header.count += 1;
            self.header.head = @mod(self.header.count, self.len * 2);
            if (self.header.count > self.len) {
                self.header.tail = self.header.head - self.len;
            }

            return self.header.count;
        }

        /// Pushes multiple values to the buffer at once.
        ///
        /// Parameters:
        /// - values: Slice of values to push to the buffer
        ///
        /// Returns:
        /// - The new count of elements pushed to the buffer (cumulative)
        pub fn pushValues(self: *Self, values: []T) u64 {
            std.debug.assert(values.len <= self.len);
            const left = @mod(self.header.head, self.len);
            const right = left + values.len;
            @memcpy(self.ring_buffer[left..right], values);

            self.header.count += values.len;
            self.header.head = @mod(self.header.count, self.len * 2);
            if (self.header.count > self.len) {
                self.header.tail = self.header.count - self.len;
            }

            return self.header.count;
        }

        /// Inserts a value at a specific logical position.
        ///
        /// Parameters:
        /// - value: Value to insert
        /// - index: Logical index at which to insert the value
        pub fn insert(self: *Self, value: T, index: u64) void {
            std.debug.assert(index < self.header.count);
            const position = @mod(index, self.len);
            self.ring_buffer[position] = value;
        }

        /// Inserts multiple values starting at a specific logical position.
        ///
        /// Parameters:
        /// - values: Slice of values to insert
        /// - index: Starting logical index for insertion
        pub fn insertValues(self: *Self, values: []T, index: u64) void {
            std.debug.assert(index < self.header.count);
            const left = @mod(index, self.len);
            const right = left + values.len;
            std.debug.assert(right <= self.header.head);
            @memcpy(self.ring_buffer[left..right], values);
        }
    };
}

test "Magic Ring Buffer" {
    const Extra = struct { resolution: f64, num_fields: u32 };
    const Ring = MagicRingWithHeader(u64, Extra);

    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Request a buffer smaller than a page to test alignment
    const requested_size = 100;
    // const expected_min_size = 512; // 4096 bytes (page size) / 8 bytes (u64 size) = 512 elements per page

    // Create a magic ring buffer
    var ring = try Ring.create("/test_ring", requested_size, allocator);
    defer ring.close() catch {};

    // Test that our ring buffer is properly page-aligned
    std.debug.print("Requested size: {d}, Actual size: {d}\n", .{ requested_size, ring.len });
    try std.testing.expect(ring.len >= requested_size);
    try std.testing.expect(ring.len % 512 == 0); // Should be aligned to page size

    // ---- Test initial state ----
    try std.testing.expectEqual(0, ring.header.count);
    try std.testing.expectEqual(0, ring.header.head);
    try std.testing.expectEqual(0, ring.header.tail);

    // Test extra fields
    ring.header.resolution = 0.5;
    ring.header.num_fields = 2;
    try std.testing.expectEqual(@as(f64, 0.5), ring.header.resolution);
    try std.testing.expectEqual(@as(u32, 2), ring.header.num_fields);

    // ---- Test adding a single value ----
    _ = ring.push(42);
    // Verify state: count=1, head=1 (mod 2*len), tail=0 (no wraparound yet)
    std.debug.print("\nAfter pushing 1 value:\n", .{});
    std.debug.print("  count: {d}, head: {d}, tail: {d}\n", .{ ring.header.count, ring.header.head, ring.header.tail });
    try std.testing.expectEqual(1, ring.header.count);
    try std.testing.expectEqual(1, ring.header.head);
    try std.testing.expectEqual(0, ring.header.tail);
    try std.testing.expectEqual(42, ring.valueAt(0));

    // ---- Test adding 5 more values ----
    for (1..6) |i| {
        _ = ring.push(@intCast(i * 100));
    }

    // Verify state: count=6, head=6 (mod 2*len), tail=0 (buffer not full yet)
    std.debug.print("\nAfter pushing 5 more values (total 6):\n", .{});
    std.debug.print("  count: {d}, head: {d}, tail: {d}\n", .{ ring.header.count, ring.header.head, ring.header.tail });
    try std.testing.expectEqual(6, ring.header.count);
    try std.testing.expectEqual(6, ring.header.head);
    try std.testing.expectEqual(0, ring.header.tail);

    // Verify values can be accessed correctly
    try std.testing.expectEqual(42, ring.valueAt(0));
    try std.testing.expectEqual(100, ring.valueAt(1));
    try std.testing.expectEqual(200, ring.valueAt(2));
    try std.testing.expectEqual(300, ring.valueAt(3));
    try std.testing.expectEqual(400, ring.valueAt(4));
    try std.testing.expectEqual(500, ring.valueAt(5));

    // ---- Fill the buffer to capacity minus 1 ----
    // Reset for a clean test
    ring.reset();

    // Fill to capacity - 1
    for (0..ring.len - 1) |i| {
        _ = ring.push(@intCast(i));
    }

    std.debug.print("\nBuffer with len-1 elements:\n", .{});
    std.debug.print("  count: {d}, head: {d}, tail: {d}\n", .{ ring.header.count, ring.header.head, ring.header.tail });

    try std.testing.expectEqual(ring.len - 1, ring.header.count);
    try std.testing.expectEqual(ring.len - 1, ring.header.head);
    try std.testing.expectEqual(0, ring.header.tail);

    // ---- Fill to exact capacity ----
    _ = ring.push(ring.len - 1);

    std.debug.print("\nBuffer exactly full (len elements):\n", .{});
    std.debug.print("  count: {d}, head: {d}, tail: {d}\n", .{ ring.header.count, ring.header.head, ring.header.tail });

    try std.testing.expectEqual(ring.len, ring.header.count);
    try std.testing.expectEqual(ring.len, ring.header.head); // head is now 512 mod len*2
    try std.testing.expectEqual(0, ring.header.tail); // tail still 0

    // ---- Test first overwrite (wraparound) ----
    _ = ring.push(1000);

    std.debug.print("\nBuffer after first overwrite (len+1 elements added):\n", .{});
    std.debug.print("  count: {d}, head: {d}, tail: {d}\n", .{ ring.header.count, ring.header.head, ring.header.tail });

    try std.testing.expectEqual(ring.len + 1, ring.header.count);
    try std.testing.expectEqual(513, ring.header.head);
    // With this implementation, tail should now be head - len, so 1 - len, which given
    // modulo arithmetic with 2*len will be len + 1
    try std.testing.expectEqual(1, ring.header.tail);

    // First element (index 0) should have been overwritten with value 1000
    try std.testing.expectEqual(1000, ring.valueAt(ring.len));

    // ---- Test multiple overwrites ----
    for (0..5) |i| {
        _ = ring.push(@intCast(5000 + i));
    }

    std.debug.print("\nBuffer after 5 more elements (total len+6 elements added):\n", .{});
    std.debug.print("  count: {d}, head: {d}, tail: {d}\n", .{ ring.header.count, ring.header.head, ring.header.tail });

    try std.testing.expectEqual(ring.len + 6, ring.header.count);
    try std.testing.expectEqual(ring.len + 6, ring.header.head);
    try std.testing.expectEqual(6, ring.header.tail);

    // Test sliceFromTail to get 3 oldest values that are still in the buffer
    const tail_slice = ring.sliceFromTail(3);
    try std.testing.expectEqual(3, tail_slice.len);

    std.debug.print("slice:\t{d}\n", .{tail_slice});

    // Expected oldest values should be: [6, 7, 8]
    try std.testing.expectEqualSlices(u64, &[_]u64{ 6, 7, 8 }, tail_slice);

    // Test sliceToHead to get 3 newest values
    const head_slice = ring.sliceToHead(3);
    try std.testing.expectEqual(3, head_slice.len);

    std.debug.print("head slice:\t{d}\n", .{head_slice});

    // Expected newest values should be: [5002, 5003, 5004]
    try std.testing.expectEqualSlices(u64, &[_]u64{ 5002, 5003, 5004 }, head_slice);

    // ---- Test the magic wraparound feature ----

    // First reset to a known state for this test
    ring.reset();

    // Advance to almost the end of buffer
    const end_stop = ring.len - 4;
    for (0..end_stop) |i| {
        _ = ring.push(@intCast(i));
    }

    std.debug.print("\nBuffer filled to len-4 elements:\n", .{});
    std.debug.print("  count: {d}, head: {d}, tail: {d}\n", .{ ring.header.count, ring.header.head, ring.header.tail });

    // Push values that will cross the physical boundary
    for (0..8) |i| {
        _ = ring.push(@intCast(9000 + i));
    }

    std.debug.print("\nAfter pushing 8 values that cross the physical boundary:\n", .{});
    std.debug.print("  count: {d}, head: {d}, tail: {d}\n", .{ ring.header.count, ring.header.head, ring.header.tail });

    // Test that we can get a contiguous slice across the physical boundary
    const wrap_start = end_stop;
    const wrap_slice = ring.slice(wrap_start, wrap_start + 8);
    try std.testing.expectEqual(8, wrap_slice.len);

    // Verify the values in the wrap slice
    for (0..8) |i| {
        try std.testing.expectEqual(9000 + i, wrap_slice[i]);
    }

    // ---- Test insertValues across boundary ----
    var cross_values = [_]u64{ 8000, 8001, 8002, 8003, 8004 };
    const insert_position = ring.len - 2; // Near the end to test wraparound
    ring.insertValues(&cross_values, insert_position);

    // Verify the inserted values
    for (0..cross_values.len) |i| {
        // Be careful with the modulo arithmetic here
        try std.testing.expectEqual(cross_values[i], ring.valueAt((insert_position + i) % ring.len));
    }

    // ---- Test pushValues with bulk insertion ----
    var push_values = [_]u64{0} ** 10;
    for (0..push_values.len) |i| {
        push_values[i] = @intCast(7000 + i);
    }

    // Push the values
    const old_count = ring.header.count;
    // const old_head = ring.header.head;
    // const old_tail = ring.header.tail;

    _ = ring.pushValues(&push_values);

    std.debug.print("\nAfter pushValues with 10 elements:\n", .{});
    std.debug.print("  count: {d}, head: {d}, tail: {d}\n", .{ ring.header.count, ring.header.head, ring.header.tail });

    // Verify count increased correctly
    try std.testing.expectEqual(old_count + push_values.len, ring.header.count);

    // Verify we can retrieve the pushed values
    for (0..push_values.len) |i| {
        try std.testing.expectEqual(push_values[i], ring.valueAt(ring.header.count - push_values.len + i));
    }

    std.debug.print("\nMagic ring buffer successfully tested!\n", .{});
}

fn combinedRingBufferFromBytes(comptime T: type, bytes: [*]u8, length: usize) []T {
    const as_type: [*]T = @ptrCast(@alignCast(bytes));
    return @ptrCast(as_type[0 .. length * 2]);
}

fn StructOfArraysFromStruct(comptime T: type) type {
    const fields = @typeInfo(T).@"struct".fields;
    comptime var fields_new: []std.builtin.Type.StructField = .{} ** fields.len;

    const soa: std.builtin.Type = .{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields_new,
            .decls = &.{},
            .is_tuple = false,
        },
    };

    return @Type(soa);
}

test StructOfArraysFromStruct {
    const target = struct { red: u8, green: u8, blue: u8 };
    _ = target;
}

// pub fn MultiMagicRingWithHeader(comptime T: type, comptime H: type) type {
//     const info_elem = @typeInfo(T);
//     _ = switch (info_elem) {
//         .@"struct" => true,
//         else => @compileError("T " ++ @typeName(T) ++ " must be a struct\n"),
//     };
//
//     return struct {
//         const Self = @This();
//         const Header = State.withFields(H);
//         const FieldSizes = 0;
//         const HeaderSize = @sizeOf(Header);
//
//         allocator: ?std.mem.Allocator = null,
//
//         name: []const u8,
//
//         buffer_info: RingBufferInfo,
//
//         header: *Header,
//     };
// }

/// RingBufferLayout calculates and stores the memory layout for a ring buffer.
/// It handles platform-specific alignment requirements for Windows and POSIX.
///
/// The layout provides:
/// - Header region for metadata
/// - Primary buffer region for data
/// - Secondary view that mirrors the primary buffer for wraparound access
///
/// Memory layout:
/// [Header][Primary Buffer][Secondary Buffer]
/// Where Secondary Buffer is a mirror of Primary Buffer
pub const RingBufferLayout = struct {
    // System information
    page_size: usize,
    allocation_granularity: usize,

    // Raw sizes
    header_size_raw: usize,
    buffer_size_raw: usize,
    element_size: usize,
    requested_element_count: usize,

    // Aligned sizes
    header_size_aligned: usize,
    buffer_size_aligned: usize,
    actual_element_count: usize,

    // Page counts
    header_pages: usize,
    buffer_pages: usize,
    total_pages: usize,

    // Allocation information
    total_size: usize,
    header_offset: usize,
    buffer_offset: usize,
    secondary_view_offset: usize,

    /// Calculates a memory layout for a ring buffer with the given parameters.
    ///
    /// Parameters:
    /// - element_size: Size of each element in bytes
    /// - element_count: Number of elements the buffer should hold
    /// - header_size: Size of the header area in bytes
    ///
    /// Returns:
    /// - A RingBufferLayout with all fields calculated and aligned properly
    pub fn init(element_size: usize, element_count: usize, header_size: usize) !RingBufferLayout {
        const page_size = std.heap.pageSize();

        // Get platform-specific allocation granularity
        const allocation_granularity = getAllocationGranularity();

        // Calculate raw buffer size
        const buffer_size_raw = element_size * element_count;

        // Align header to page size
        const header_size_aligned = std.mem.alignForward(usize, header_size, page_size);
        const header_pages = header_size_aligned / page_size;

        // Align buffer to page size or allocation granularity, whichever is stricter
        // const alignment = std.math.max(page_size, allocation_granularity);
        const buffer_size_aligned = std.mem.alignForward(usize, buffer_size_raw, page_size);
        const buffer_pages = buffer_size_aligned / page_size;

        // Calculate actual number of elements after alignment
        const actual_element_count = buffer_size_aligned / element_size;

        // Calculate memory offsets
        const header_offset = 0;
        const buffer_offset = header_size_aligned;
        const secondary_view_offset = header_size_aligned + buffer_size_aligned;

        // Total virtual memory reservation needed
        const total_size = header_size_aligned + (buffer_size_aligned * 2);
        const total_pages = total_size / page_size;

        return RingBufferLayout{
            .page_size = page_size,
            .allocation_granularity = allocation_granularity,
            .header_size_raw = header_size,
            .buffer_size_raw = buffer_size_raw,
            .element_size = element_size,
            .requested_element_count = element_count,
            .header_size_aligned = header_size_aligned,
            .buffer_size_aligned = buffer_size_aligned,
            .actual_element_count = actual_element_count,
            .header_pages = header_pages,
            .buffer_pages = buffer_pages,
            .total_pages = total_pages,
            .total_size = total_size,
            .header_offset = header_offset,
            .buffer_offset = buffer_offset,
            .secondary_view_offset = secondary_view_offset,
        };
    }

    pub fn formatDebug(self: RingBufferLayout) void {
        std.debug.print("Ring Buffer Layout:\n", .{});
        std.debug.print("  System Info:\n", .{});
        std.debug.print("    Page Size: {d} bytes\n", .{self.page_size});
        std.debug.print("    Allocation Granularity: {d} bytes\n", .{self.allocation_granularity});

        std.debug.print("  Raw Sizes:\n", .{});
        std.debug.print("    Header Size: {d} bytes\n", .{self.header_size_raw});
        std.debug.print("    Buffer Size: {d} bytes\n", .{self.buffer_size_raw});
        std.debug.print("    Element Size: {d} bytes\n", .{self.element_size});
        std.debug.print("    Requested Elements: {d}\n", .{self.requested_element_count});

        std.debug.print("  Aligned Sizes:\n", .{});
        std.debug.print("    Header Size: {d} bytes ({d} pages)\n", .{ self.header_size_aligned, self.header_pages });
        std.debug.print("    Buffer Size: {d} bytes ({d} pages)\n", .{ self.buffer_size_aligned, self.buffer_pages });
        std.debug.print("    Actual Elements: {d}\n", .{self.actual_element_count});

        std.debug.print("  Memory Layout:\n", .{});
        std.debug.print("    Total Size: {d} bytes ({d} pages)\n", .{ self.total_size, self.total_pages });
        std.debug.print("    Header Offset: {d} bytes\n", .{self.header_offset});
        std.debug.print("    Buffer Offset: {d} bytes\n", .{self.buffer_offset});
        std.debug.print("    Secondary View Offset: {d} bytes\n", .{self.secondary_view_offset});

        // Calculate wasted space
        const header_waste = self.header_size_aligned - self.header_size_raw;
        const buffer_waste = self.buffer_size_aligned - self.buffer_size_raw;

        std.debug.print("  Utilization:\n", .{});
        std.debug.print("    Header Padding: {d} bytes\n", .{header_waste});
        std.debug.print("    Buffer Padding: {d} bytes\n", .{buffer_waste});

        const utilization = @as(f64, @floatFromInt(self.header_size_raw + self.buffer_size_raw)) /
            @as(f64, @floatFromInt(self.total_size / 2)) * 100.0;
        std.debug.print("    Utilization: {d:.2}%\n", .{utilization});
    }
};

/// Platform-specific function to get memory allocation granularity.
/// On Windows, this returns the system allocation granularity (typically 64KB).
/// On POSIX systems, this returns the page size.
fn getAllocationGranularity() usize {
    if (tag == .windows) {
        // On Windows, try to get actual allocation granularity using Windows API
        // Only include the Windows-specific import and code when on Windows
        var sys_info: winSysInfo.SYSTEM_INFO = undefined;
        winSysInfo.GetSystemInfo(&sys_info);
        return sys_info.dwAllocationGranularity;
    } else {
        // On POSIX and other systems, allocation granularity equals page size
        return std.heap.pageSize();
    }
}

/// Platform-specific data structure for a ring buffer.
/// This varies depending on the platform (Windows vs POSIX).
const RingBufferInfo = switch (tag) {
    .windows => struct {
        header: []u8, // Slice containing the header data
        buffer: []u8, // Slice containing the ring buffer data
        secondary_view: []u8, // Slice containing the duplicate view for wrap-around
        combined_buffer: []u8, // Slice spanning buffer + virtual continuation for wrap-around
        layout: RingBufferLayout, // The calculated layout
        section_handle: Handle, // Handle to the file mapping
    },
    else => struct {
        header: []u8, // Slice containing the header data
        buffer: []u8, // Slice containing the ring buffer data
        secondary_view: []u8, // Slice containing the duplicate view for wrap-around
        combined_buffer: []u8, // Slice spanning buffer + virtual continuation for wrap-around
        layout: RingBufferLayout, // The calculated layout
        mapping: Mapping, // Mapping information
        name: []const u8,
    },
};

/// POSIX-specific mapping structure for shared memory.
const Mapping = struct {
    shared: shared_memory.Shared,
    mirror: []u8,
};

/// Creates a memory-mapped mirror view of a shared memory region.
/// This is the core function that enables the wraparound feature on POSIX systems.
///
/// Parameters:
/// - shmem: The shared memory object
/// - header_offset: Offset in bytes from the start of the shared memory to where the buffer begins
/// - protection: Memory protection flags (PROT_READ, PROT_WRITE, etc.)
///
/// Returns:
/// - A slice representing the mirrored view
///
/// This function maps the same physical memory to two consecutive virtual memory addresses,
/// creating the illusion of a contiguous buffer that wraps around at the end.
pub fn posixMagicRing(
    shmem: shared_memory.Shared,
    header_offset: usize,
    protection: u32,
) ![]u8 {
    const size: usize = @divExact(shmem.size - header_offset, 2);

    const page_size = std.heap.pageSize();

    const base: []align(page_size) u8 = @ptrCast(@alignCast(
        shmem.data[header_offset..],
    ));

    const ptr: [*]align(page_size) u8 = @ptrCast(
        @alignCast(
            &base[size],
        ),
    );

    const mirror = try std.posix.mmap(
        ptr,
        size,
        protection,
        .{
            .TYPE = .SHARED,
            .FIXED = true,
        },
        shmem.fd,
        header_offset,
    );

    return mirror;
}

/// Creates a new POSIX shared memory ring buffer with a header region.
///
/// Parameters:
/// - name: Name of the shared memory object (must start with '/')
/// - element_size: Size of each element in bytes
/// - element_count: Number of elements the buffer should hold
/// - header_size: Size of the header area in bytes
///
/// Returns:
/// - A RingBufferInfo structure containing the buffer metadata and views
///
/// The created buffer will have a header region followed by a buffer region.
/// The buffer region is virtually mirrored to create a wraparound effect,
/// allowing continuous access across the buffer boundary.
pub fn posixCreateRingBufferWithHeader(
    name: []const u8,
    element_size: usize,
    element_count: usize,
    header_size: usize,
) !RingBufferInfo {
    // Calculate the memory layout
    const layout = try RingBufferLayout.init(element_size, element_count, header_size);

    // std.debug.print("Creating POSIX ring buffer with layout:\n", .{});
    // layout.formatDebug();

    // Create the POSIX shared memory mapping
    // var mapping = try posixCreate(name, layout.buffer_size_aligned, layout.header_size_aligned);

    const total_size = layout.header_size_aligned + (layout.buffer_size_aligned * 2);
    // std.debug.print("Creating POSIX shared memory of size {d} bytes\n", .{total_size});

    const shmem = try shared_memory.posixCreate(name, total_size);

    const protection = std.posix.PROT.READ | std.posix.PROT.WRITE;

    const mirror = try posixMagicRing(shmem, layout.header_size_aligned, protection);

    var mapping: Mapping = .{
        .shared = shmem,
        .mirror = mirror,
    };

    // Create buffer slices
    const header = mapping.shared.data[0..layout.header_size_aligned];
    const buffer = mapping.shared.data[layout.buffer_offset..layout.secondary_view_offset];
    const secondary_view = mapping.mirror;

    // Create the combined buffer view
    const combined_buffer = blk: {
        const ptr: [*]u8 = @ptrCast(buffer.ptr);
        break :blk ptr[0..(layout.buffer_size_aligned * 2)];
    };

    return .{
        .header = header,
        .buffer = buffer,
        .secondary_view = secondary_view,
        .combined_buffer = combined_buffer,
        .layout = layout,
        .mapping = mapping,
        .name = name,
    };
}

/// Opens an existing POSIX shared memory ring buffer.
///
/// Parameters:
/// - name: Name of the shared memory object (must start with '/')
/// - element_size: Size of each element in bytes (must match the original)
/// - element_count: Number of elements the buffer should hold (must match the original)
/// - header_size: Size of the header area in bytes (must match the original)
///
/// Returns:
/// - A RingBufferInfo structure containing the buffer metadata and views
///
/// This function opens an existing ring buffer created with posixCreateRingBufferWithHeader.
/// The parameters must match those used when creating the buffer.
pub fn posixOpenRingBuffer(
    name: []const u8,
    element_size: usize,
    element_count: usize,
    header_size: usize,
) !RingBufferInfo {
    // Calculate the memory layout (same calculation as when creating)
    const layout = try RingBufferLayout.init(element_size, element_count, header_size);

    // Open the POSIX shared memory mapping
    const shmem = try shared_memory.posixOpen(name);
    const protection = std.posix.PROT.READ | std.posix.PROT.WRITE;
    const mirror = try posixMagicRing(shmem, layout.header_size_aligned, protection);

    var mapping: Mapping = .{ .shared = shmem, .mirror = mirror };

    // Create buffer slices
    const header = mapping.shared.data[0..layout.header_size_aligned];
    const buffer = mapping.shared.data[layout.buffer_offset..layout.secondary_view_offset];
    const secondary_view = mapping.mirror;

    // Create the combined buffer view
    const combined_buffer = blk: {
        const ptr: [*]u8 = @ptrCast(buffer.ptr);
        break :blk ptr[0..(layout.buffer_size_aligned * 2)];
    };

    return .{
        .header = header,
        .buffer = buffer,
        .secondary_view = secondary_view,
        .combined_buffer = combined_buffer,
        .layout = layout,
        .mapping = mapping,
        .name = name,
    };
}

/// Checks if a POSIX shared memory ring buffer with the given name exists.
///
/// Parameters:
/// - name: Name of the shared memory object (must start with '/')
///
/// Returns:
/// - true if the buffer exists, false otherwise
pub fn posixRingBufferExists(name: []const u8) !bool {
    return shared_memory.posixMapExists(name);
}

/// Closes and cleans up a POSIX shared memory ring buffer.
///
/// Parameters:
/// - rb: Pointer to the RingBufferInfo structure to close
///
/// This function unmaps the mirror view, closes the shared memory object,
/// and zeros out the RingBufferInfo structure.
pub fn posixCloseRingBuffer(rb: *RingBufferInfo) !void {
    if (tag == .windows) {
        @compileError("closeRingBuffer POSIX implementation called on Windows platform");
    }
    // Unmap the mirror view
    std.posix.munmap(@alignCast(rb.secondary_view));

    // Close the shared memory
    shared_memory.posixClose(rb.mapping.shared.data, rb.mapping.shared.fd, rb.name);

    // Zero out the structure
    rb.* = undefined;
}

fn test_entry(
    name: []const u8,
    element_size: usize,
    element_count: usize,
    header_size: usize,
) !RingBufferInfo {
    std.debug.print(
        "Test: {s},\tPlatform:{s}, libc: {any}\n",
        .{
            name,
            @tagName(tag),
            @import("builtin").link_libc,
        },
    );

    return switch (tag) {
        .linux, .freebsd => {
            if (@import("builtin").link_libc) {
                return posixCreateRingBufferWithHeader(
                    name,
                    element_size,
                    element_count,
                    header_size,
                );
            }
            return memfdCreateRingBufferWithHeader(
                std.testing.allocator,
                name,
                element_size,
                element_count,
                header_size,
            );
        },
        .windows => try windowsCreateRingBufferWithHeader(
            name,
            element_size,
            element_count,
            header_size,
        ),
        else => try posixCreateRingBufferWithHeader(
            name,
            element_size,
            element_count,
            header_size,
        ),
    };
}

fn test_exists(name: []const u8) bool {
    return switch (tag) {
        .linux, .freebsd => blk: {
            if (@import("builtin").link_libc) {
                break :blk shared_memory.posixMapExists(name);
            }
            break :blk shared_memory.memfdBasedExists(std.testing.allocator, name);
        },
        .windows => shared_memory.windowsMapExists(name),
        else => shared_memory.posixMapExists(name),
    };
}

fn test_open(
    name: []const u8,
    element_size: usize,
    element_count: usize,
    header_size: usize,
) !RingBufferInfo {
    return switch (tag) {
        .linux, .freebsd => {
            if (@import("builtin").link_libc) {
                return posixOpenRingBuffer(
                    name,
                    element_size,
                    element_count,
                    header_size,
                );
            }
            return memfdOpenRingBuffer(
                std.testing.allocator,
                name,
                element_size,
                element_count,
                header_size,
            );
        },
        .windows => try windowsOpenRingBuffer(
            name,
            element_size,
            element_count,
            header_size,
        ),
        else => try posixOpenRingBuffer(
            name,
            element_size,
            element_count,
            header_size,
        ),
    };
}

fn test_forceclose(name: []const u8) void {
    if (test_exists(name) == false) return;

    switch (tag) {
        .windows => return,
        else => {
            if (@import("builtin").link_libc) {
                shared_memory.posixForceClose(name);
            }
        },
    }
}

fn test_cleanup(rb: *RingBufferInfo) !void {
    const os_tag = @import("builtin").os.tag;
    return switch (os_tag) {
        .linux, .freebsd => {
            if (@import("builtin").link_libc) {
                return posixCloseRingBuffer(rb);
            }
            return memfdCloseRingBuffer(std.testing.allocator, rb);
        },
        .windows => try windowsCloseRingBuffer(rb),
        else => try posixCloseRingBuffer(rb),
    };
}

test "create ring buffer" {

    // Define our test parameters
    const buffer_name = if (tag == .windows) "test_creation" else "/test_creation";
    const element_type = u64;
    const element_size = @sizeOf(element_type);
    const element_count: usize = 1000;
    const header_size = @sizeOf(RingBufferHeader);

    var ring_buffer = try test_entry(
        buffer_name,
        element_size,
        element_count,
        header_size,
    );

    defer test_cleanup(&ring_buffer) catch {};

    // Verify the layout is calculated correctly
    try std.testing.expectEqual(@sizeOf(RingBufferHeader), ring_buffer.layout.header_size_raw);
    try std.testing.expectEqual(element_size * element_count, ring_buffer.layout.buffer_size_raw);
    try std.testing.expect(ring_buffer.layout.actual_element_count >= element_count);

    // Initialize the header with test values
    const header: *RingBufferHeader = @ptrCast(@alignCast(ring_buffer.header.ptr));
    header.tail = 0;
    header.head = 0;
    header.count = 0;
    header.resolution = 44100.0;
    header.num_channels = 2.0;

    // Verify header values are set correctly
    try std.testing.expectEqual(@as(u64, 0), header.tail);
    try std.testing.expectEqual(@as(u64, 0), header.head);
    try std.testing.expectEqual(@as(u64, 0), header.count);
    try std.testing.expectEqual(@as(f64, 44100.0), header.resolution);
    try std.testing.expectEqual(@as(f32, 2.0), header.num_channels);
}

test "basic writes" {
    // Define our test parameters
    const buffer_name = if (tag == .windows) "test_basic_writes" else "/test_basic_writes";
    const element_type = u64;
    const element_size = @sizeOf(element_type);
    const element_count: usize = 1000;
    const header_size = @sizeOf(RingBufferHeader);

    var ring_buffer = try test_entry(
        buffer_name,
        element_size,
        element_count,
        header_size,
    );

    defer test_cleanup(&ring_buffer) catch {};

    // Get typed slices for the buffer
    const buffer: []element_type = @ptrCast(
        @as(
            [*]element_type,
            @ptrCast(@alignCast(ring_buffer.buffer.ptr)),
        )[0..ring_buffer.layout.actual_element_count],
    );

    // Test writing sequential values at the beginning of the buffer
    for (0..10) |i| {
        buffer[i] = @intCast(i);
    }

    // Verify the values were written correctly using slice comparison
    try std.testing.expectEqualSlices(
        element_type,
        &[_]element_type{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 },
        buffer[0..10],
    );

    // Test writing at the end of the buffer
    const end_start = ring_buffer.layout.actual_element_count - 5;
    for (0..5) |i| {
        buffer[end_start + i] = @intCast(end_start + i);
    }

    // Verify sequential values at the end of the buffer
    try std.testing.expectEqualSlices(
        element_type,
        &[_]element_type{ end_start, end_start + 1, end_start + 2, end_start + 3, end_start + 4 },
        buffer[end_start..(end_start + 5)],
    );
}

test "wrap-around" {

    // Define our test parameters
    const buffer_name = if (tag == .windows) "test_wrap_around" else "/test_wrap_around";
    const element_type = u64;
    const element_size = @sizeOf(element_type);
    const element_count: usize = 1000;
    const header_size = @sizeOf(RingBufferHeader);

    var ring_buffer = try test_entry(
        buffer_name,
        element_size,
        element_count,
        header_size,
    );

    defer test_cleanup(&ring_buffer) catch {};
    //
    // Create typed slices for access
    const buffer: []element_type = @ptrCast(
        @as(
            [*]element_type,
            @ptrCast(@alignCast(ring_buffer.combined_buffer.ptr)),
        )[0..(ring_buffer.layout.actual_element_count * 2)],
    );

    const primary_buffer: []element_type = @ptrCast(
        @as(
            [*]element_type,
            @ptrCast(@alignCast(ring_buffer.buffer.ptr)),
        )[0..ring_buffer.layout.actual_element_count],
    );

    const secondary_buffer: []element_type = @ptrCast(
        @as(
            [*]element_type,
            @ptrCast(@alignCast(ring_buffer.secondary_view.ptr)),
        )[0..ring_buffer.layout.actual_element_count],
    );

    // Define a small pattern that makes the wraparound obvious
    const pattern_start = ring_buffer.layout.actual_element_count - 4;

    // Clear the relevant portion of the buffer
    for (0..8) |i| {
        if (i < 4) {
            buffer[pattern_start + i] = 0;
        }
        if (i < 4) {
            buffer[ring_buffer.layout.actual_element_count + i] = 0;
        }
    }

    // Write data at the end of the buffer
    buffer[pattern_start + 0] = 1020;
    buffer[pattern_start + 1] = 1021;
    buffer[pattern_start + 2] = 1022;
    buffer[pattern_start + 3] = 1023;

    // Write data at the start of the wraparound region
    buffer[ring_buffer.layout.actual_element_count + 0] = 0;
    buffer[ring_buffer.layout.actual_element_count + 1] = 1;
    buffer[ring_buffer.layout.actual_element_count + 2] = 2;
    buffer[ring_buffer.layout.actual_element_count + 3] = 3;

    // Verify the pattern at the end of the buffer
    try std.testing.expectEqualSlices(
        element_type,
        &[_]element_type{ 1020, 1021, 1022, 1023 },
        primary_buffer[pattern_start..(pattern_start + 4)],
    );

    // Verify the pattern at the start of the secondary view
    try std.testing.expectEqualSlices(
        element_type,
        &[_]element_type{ 0, 1, 2, 3 },
        secondary_buffer[0..4],
    );

    // The key test - verify we can read across the boundary with combined view
    try std.testing.expectEqualSlices(
        element_type,
        &[_]element_type{ 1020, 1021, 1022, 1023, 0, 1, 2, 3 },
        buffer[pattern_start..(pattern_start + 8)],
    );
}

test "mirroring" {

    // Define our test parameters
    const buffer_name = if (tag == .windows) "test_mirroring" else "/test_mirroring";
    const element_type = u64;
    const element_size = @sizeOf(element_type);
    const element_count: usize = 1000;
    const header_size = @sizeOf(RingBufferHeader);

    var ring_buffer = try test_entry(
        buffer_name,
        element_size,
        element_count,
        header_size,
    );

    defer test_cleanup(&ring_buffer) catch {};

    // Create typed slices for access
    const primary_buffer: []element_type = @ptrCast(
        @as(
            [*]element_type,
            @ptrCast(@alignCast(ring_buffer.buffer.ptr)),
        )[0..ring_buffer.layout.actual_element_count],
    );

    const secondary_buffer: []element_type = @ptrCast(
        @as(
            [*]element_type,
            @ptrCast(@alignCast(ring_buffer.secondary_view.ptr)),
        )[0..ring_buffer.layout.actual_element_count],
    );

    // First clear the beginning of buffers
    for (0..5) |i| {
        primary_buffer[i] = 0;
        secondary_buffer[i] = 0;
    }

    // Write values at the start of secondary view
    for (0..5) |i| {
        secondary_buffer[i] = @intCast(i + 100);
    }

    // Verify that changes to secondary view are reflected in primary buffer
    try std.testing.expectEqualSlices(
        element_type,
        &[_]element_type{ 100, 101, 102, 103, 104 },
        primary_buffer[0..5],
    );

    // Test in reverse: modify primary and check secondary
    for (0..5) |i| {
        primary_buffer[i] = @intCast(i + 200);
    }

    // Verify secondary view reflects the primary changes
    try std.testing.expectEqualSlices(
        element_type,
        &[_]element_type{ 200, 201, 202, 203, 204 },
        secondary_buffer[0..5],
    );
}

test "open existing and modify bidirectionally" {

    if (@import("builtin").link_libc == false) {
        std.debug.print("memfd implementation produces immutable view, skipping...\n", .{});
        if (tag == .linux) return error.SkipZigTest;
        if (tag == .freebsd) return error.SkipZigTest;
    }

    // Define our test parameters
    const buffer_name = if (tag == .windows) "test_open_existing" else "/test_open_existing";
    const element_type = u64;
    const element_size = @sizeOf(element_type);
    const element_count: usize = 1000;
    const header_size = @sizeOf(RingBufferHeader);

    test_forceclose(buffer_name);

    var ring_buffer = try test_entry(
        buffer_name,
        element_size,
        element_count,
        header_size,
    );

    defer test_cleanup(&ring_buffer) catch {};

    // Initialize the header with test values
    const header: *RingBufferHeader = @ptrCast(@alignCast(ring_buffer.header.ptr));
    header.tail = 42;
    header.head = 20;
    header.count = 22;
    header.resolution = 44100.0;
    header.num_channels = 2.0;

    std.debug.print("name:\t{s}\n", .{buffer_name});

    // Write a pattern to the buffer
    const buffer: []element_type = @ptrCast(
        @as(
            [*]element_type,
            @ptrCast(@alignCast(ring_buffer.combined_buffer.ptr)),
        )[0..(ring_buffer.layout.actual_element_count * 2)],
    );

    // Write a simple pattern
    for (0..10) |i| {
        buffer[i] = @intCast(i * 100);
    }

    // Try to open the buffer
    var opened_buffer = try test_open(
        buffer_name,
        element_size,
        element_count,
        header_size,
    );

    defer test_cleanup(&opened_buffer) catch {};

    // Get typed slices for the opened buffer
    const opened_header: *RingBufferHeader = @ptrCast(@alignCast(opened_buffer.header.ptr));
    const opened_buffer_typed: []element_type = @ptrCast(
        @as(
            [*]element_type,
            @ptrCast(@alignCast(opened_buffer.buffer.ptr)),
        )[0..opened_buffer.layout.actual_element_count],
    );

    // Verify that the header values were preserved
    try std.testing.expectEqual(@as(u64, 42), opened_header.tail);
    try std.testing.expectEqual(@as(u64, 20), opened_header.head);
    try std.testing.expectEqual(@as(u64, 22), opened_header.count);
    try std.testing.expectEqual(@as(f64, 44100.0), opened_header.resolution);
    try std.testing.expectEqual(@as(f32, 2.0), opened_header.num_channels);

    // Verify the buffer data is still there
    try std.testing.expectEqualSlices(
        element_type,
        &[_]element_type{ 0, 100, 200, 300, 400, 500, 600, 700, 800, 900 },
        opened_buffer_typed[0..10],
    );

    // PHASE 1: Test modifying through second handle
    std.debug.print("Testing modifications through second handle...\n", .{});

    // Test bidirectional sharing between handles - modify through the second handle
    opened_buffer_typed[5] = 12345;

    // Verify the change is visible through the original handle
    try std.testing.expectEqual(@as(element_type, 12345), buffer[5]);
    std.debug.print(
        "  Second handle changed buffer[5] to {d}, original handle sees: {d}\n",
        .{ opened_buffer_typed[5], buffer[5] },
    );

    // Also test header bidirectional sharing
    opened_header.tail = 100;
    opened_header.head = 50;

    // Verify header changes are visible through original handle
    try std.testing.expectEqual(@as(u64, 100), header.tail);
    try std.testing.expectEqual(@as(u64, 50), header.head);
    std.debug.print(
        "  Second handle changed header values to {d}/{d}, original handle sees: {d}/{d}\n",
        .{ opened_header.tail, opened_header.head, header.tail, header.head },
    );

    // PHASE 2: Test modifying through original handle
    std.debug.print("Testing modifications through original handle...\n", .{});

    // Modify through original handle
    buffer[7] = 54321;
    header.count = 50;

    // Verify changes are visible through second handle
    try std.testing.expectEqual(@as(element_type, 54321), opened_buffer_typed[7]);
    try std.testing.expectEqual(@as(u64, 50), opened_header.count);
    std.debug.print(
        "  Original handle changed buffer[7] to {d}, second handle sees: {d}\n",
        .{ buffer[7], opened_buffer_typed[7] },
    );
    std.debug.print(
        "  Original handle changed header.count to {d}, second handle sees: {d}\n",
        .{ header.count, opened_header.count },
    );

    // PHASE 3: Test wraparound access through both handles
    std.debug.print("Testing wraparound access through both handles...\n", .{});

    // Create a combined view for the second handle too
    const opened_combined: []element_type = @ptrCast(
        @as(
            [*]element_type,
            @ptrCast(@alignCast(opened_buffer.combined_buffer.ptr)),
        )[0..(opened_buffer.layout.actual_element_count * 2)],
    );

    // Write a pattern at the wraparound boundary in original handle
    const wrap_start = ring_buffer.layout.actual_element_count - 3;
    buffer[wrap_start + 0] = 9001;
    buffer[wrap_start + 1] = 9002;
    buffer[wrap_start + 2] = 9003;
    buffer[ring_buffer.layout.actual_element_count + 0] = 9004;
    buffer[ring_buffer.layout.actual_element_count + 1] = 9005;

    // Verify the pattern is visible in the second handle
    // First check the end of the buffer and start of mirror separately
    try std.testing.expectEqualSlices(
        element_type,
        &[_]element_type{ 9001, 9002, 9003 },
        opened_buffer_typed[wrap_start..(wrap_start + 3)],
    );

    try std.testing.expectEqualSlices(
        element_type,
        &[_]element_type{ 9004, 9005 },
        opened_buffer_typed[0..2],
    );

    // Now check combined continuous access
    try std.testing.expectEqualSlices(
        element_type,
        &[_]element_type{ 9001, 9002, 9003, 9004, 9005 },
        opened_combined[wrap_start..(wrap_start + 5)],
    );

    std.debug.print("  Wraparound pattern visible through second handle\n", .{});

    // Modify through the second handle, crossing the boundary
    opened_combined[wrap_start + 1] = 8002;
    opened_combined[wrap_start + 3] = 8004; // This is past the buffer end

    // Verify the changes are visible in the original handle
    try std.testing.expectEqual(
        @as(element_type, 8002),
        buffer[wrap_start + 1],
    );
    try std.testing.expectEqual(
        @as(element_type, 8004),
        buffer[ring_buffer.layout.actual_element_count + 0],
    );

    std.debug.print(
        "  Successfully modified and accessed across wraparound boundary between handles\n",
        .{},
    );
}

test "check exists" {
    if (@import("builtin").link_libc == false) {
        if (tag == .linux) return error.SkipZigTest;
        if (tag == .freebsd) return error.SkipZigTest;
    }

    // Define our test parameters
    const buffer_name = if (tag == .windows) "test_exists" else "/test_exists";
    const element_type = u64;
    const element_size = @sizeOf(element_type);
    const element_count: usize = 1000;
    const header_size = @sizeOf(RingBufferHeader);

    try std.testing.expect(test_exists(buffer_name) == false);

    var ring_buffer = try test_entry(
        buffer_name,
        element_size,
        element_count,
        header_size,
    );

    defer test_cleanup(&ring_buffer) catch {};

    const exists_after = test_exists(buffer_name);
    try std.testing.expect(exists_after);

    // Check a non-existent buffer
    try std.testing.expect(test_exists("/non_existing_buffer") == false);
}

test "large header small buffer" {
    const buffer_name = if (tag == .windows) "test_large_header_small_buffer" else "/test_large_header_small_buffer";
    const element_type = u64;
    const element_size = @sizeOf(element_type);
    const element_count: usize = 1000;
    const large_header_size = 1000; // 1KB header

    test_forceclose(buffer_name);
    try std.testing.expect(test_exists(buffer_name) == false);

    var ring_buffer = try test_entry(
        buffer_name,
        element_size,
        element_count,
        large_header_size,
    );

    defer test_cleanup(&ring_buffer) catch {};

    // Verify layout calculations
    try std.testing.expect(ring_buffer.layout.header_size_raw == large_header_size);
    try std.testing.expect(ring_buffer.layout.header_size_aligned >= large_header_size);
    try std.testing.expect(
        ring_buffer.layout.header_size_aligned % ring_buffer.layout.page_size == 0,
    );
    try std.testing.expect(ring_buffer.layout.actual_element_count >= element_count);

    // Test the buffer with a simple pattern
    const buffer: []element_type = @ptrCast(
        @as(
            [*]element_type,
            @ptrCast(@alignCast(ring_buffer.combined_buffer.ptr)),
        )[0..(ring_buffer.layout.actual_element_count * 2)],
    );

    // Write a pattern
    for (0..10) |i| {
        buffer[i] = @intCast(i);
    }

    // Verify the pattern
    try std.testing.expectEqualSlices(
        element_type,
        &[_]element_type{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 },
        buffer[0..10],
    );
}

/// Creates a memfd-based ring buffer (Linux/FreeBSD specific).
///
/// Parameters:
/// - allocator: Memory allocator for internal string operations
/// - name: Name of the shared memory object
/// - element_size: Size of each element in bytes
/// - element_count: Number of elements the buffer should hold
/// - header_size: Size of the header area in bytes
///
/// Returns:
/// - A RingBufferInfo structure containing the buffer metadata and views
///
/// This function creates a memfd-based ring buffer, which is only available
/// on Linux and FreeBSD. Unlike POSIX shared memory, memfd is anonymous and
/// only accessible through file descriptors, making it useful for same-process
/// or parent-child communication.
pub fn memfdCreateRingBufferWithHeader(
    allocator: std.mem.Allocator,
    name: []const u8,
    element_size: usize,
    element_count: usize,
    header_size: usize,
) !RingBufferInfo {
    // Calculate the memory layout
    const layout = try RingBufferLayout.init(element_size, element_count, header_size);

    // Create the memfd shared memory mapping
    const total_size = layout.header_size_aligned + (layout.buffer_size_aligned * 2);
    const shmem = try shared_memory.memfdBasedCreate(
        allocator,
        name,
        total_size,
    );

    const protection = std.posix.PROT.READ | std.posix.PROT.WRITE;

    const mirror = try posixMagicRing(shmem, layout.header_size_aligned, protection);

    var mapping: Mapping = .{ .shared = shmem, .mirror = mirror };

    // Create buffer slices
    const header = mapping.shared.data[0..layout.header_size_aligned];
    const buffer = mapping.shared.data[layout.buffer_offset..layout.secondary_view_offset];
    const secondary_view = mapping.mirror;

    // Create the combined buffer view
    const combined_buffer = blk: {
        const ptr: [*]u8 = @ptrCast(buffer.ptr);
        break :blk ptr[0..(layout.buffer_size_aligned * 2)];
    };

    return .{
        .header = header,
        .buffer = buffer,
        .secondary_view = secondary_view,
        .combined_buffer = combined_buffer,
        .layout = layout,
        .mapping = mapping,
        .name = name,
    };
}

/// Opens an existing memfd-based ring buffer.
///
/// Parameters:
/// - allocator: Memory allocator for internal string operations
/// - name: Name of the shared memory object
/// - element_size: Size of each element in bytes (must match the original)
/// - element_count: Number of elements the buffer should hold (must match the original)
/// - header_size: Size of the header area in bytes (must match the original)
///
/// Returns:
/// - A RingBufferInfo structure containing the buffer metadata and views
///
/// This function opens an existing memfd-based ring buffer. Note that memfd
/// connections are read-only for secondary processes.
pub fn memfdOpenRingBuffer(
    allocator: std.mem.Allocator,
    name: []const u8,
    element_size: usize,
    element_count: usize,
    header_size: usize,
) !RingBufferInfo {
    // Calculate the memory layout
    const layout = try RingBufferLayout.init(element_size, element_count, header_size);

    // Open the memfd shared memory mapping
    const shmem = try shared_memory.memfdBasedOpen(allocator, name);
    const protection = std.posix.PROT.READ; // memfd does not allow external processes to write
    const mirror = try posixMagicRing(shmem, layout.header_size_aligned, protection);

    var mapping: Mapping = .{ .shared = shmem, .mirror = mirror };

    // Create buffer slices
    const header = mapping.shared.data[0..layout.header_size_aligned];
    const buffer = mapping.shared.data[layout.buffer_offset..layout.secondary_view_offset];
    const secondary_view = mapping.mirror;

    // Create the combined buffer view
    const combined_buffer = blk: {
        const ptr: [*]u8 = @ptrCast(buffer.ptr);
        break :blk ptr[0..(layout.buffer_size_aligned * 2)];
    };

    return .{
        .header = header,
        .buffer = buffer,
        .secondary_view = secondary_view,
        .combined_buffer = combined_buffer,
        .layout = layout,
        .mapping = mapping,
        .name = name,
    };
}

/// Closes a memfd-based ring buffer.
///
/// Parameters:
/// - allocator: Memory allocator that was used to create/open the buffer
/// - rb: Pointer to the RingBufferInfo structure to close
///
/// This function unmaps the mirror view, closes the memfd object,
/// and zeros out the RingBufferInfo structure.
pub fn memfdCloseRingBuffer(allocator: std.mem.Allocator, rb: *RingBufferInfo) !void {
    if (tag != .windows) {
        try memfdClose(allocator, rb.name, &rb.mapping);
        rb.* = undefined;
    } else {
        @compileError("closeMemfdRingBuffer called on Windows platform");
    }
}

/// Closes a memfd mapping.
///
/// Parameters:
/// - allocator: Memory allocator that was used to create/open the mapping
/// - name: Name of the shared memory object
/// - mapping: Pointer to the Mapping structure to close
///
/// This is an internal function used by memfdCloseRingBuffer.
fn memfdClose(allocator: std.mem.Allocator, name: []const u8, mapping: *Mapping) !void {
    std.posix.munmap(@alignCast(mapping.mirror));
    mapping.mirror = undefined;

    shared_memory.memfdBasedClose(
        allocator,
        mapping.shared.data,
        mapping.shared.fd,
        name,
    );
    mapping.* = undefined;
}

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
    const inherit: winFoundation.BOOL = if (inheritHandle) winZig.TRUE else winZig.FALSE;

    const handle = winMem.OpenFileMappingA(desiredAccess, inherit, name);

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

/// Creates a file mapping object with the specified name and size.
///
/// Parameters:
/// - name: Null-terminated name of the file mapping object
/// - size: Size of the file mapping in bytes
///
/// Returns:
/// - A Windows HANDLE to the file mapping object
///
/// This is an internal function used by windowsCreateRingBufferWithHeader.
fn createFileDescriptor(name: [*:0]const u8, size: usize) !Handle {
    const handle: std.os.windows.HANDLE = try createFileMapping(
        winFoundation.INVALID_HANDLE_VALUE,
        null,
        .{
            .PAGE_READWRITE = 1,
        },
        @intCast((size >> 32) & 0xFFFFFFFF), // High 32 bits
        @intCast(size & 0xFFFFFFFF), // Low 32 bits
        name,
    );
    return handle;
}

/// Opens an existing file mapping object by name.
///
/// Parameters:
/// - name: Null-terminated name of the file mapping object
/// - flags: Access flags (e.g., FILE_MAP_READ, FILE_MAP_WRITE)
///
/// Returns:
/// - A Windows HANDLE to the file mapping object
///
/// This is an internal function used by windowsOpenRingBuffer.
fn openFileDescriptor(name: [*:0]const u8, flags: winMem.FILE_MAP) !Handle {
    if (winMem.OpenFileMappingA(@bitCast(flags), winZig.FALSE, name)) |h| {
        return h;
    }

    switch (std.os.windows.kernel32.GetLastError()) {
        else => |err| return std.os.windows.unexpectedError(err),
    }
}

/// Creates a ring buffer with header from a file mapping handle.
///
/// Parameters:
/// - handle: Windows HANDLE to a file mapping object
/// - layout: RingBufferLayout structure with memory layout information
/// - protection: Memory protection flags
///
/// Returns:
/// - A RingBufferInfo structure containing the buffer metadata and views
///
/// This function creates a ring buffer from an existing file mapping.
/// It reserves virtual memory and maps the file mapping in a way that
/// creates the wrap-around effect using Windows API functions.
fn windowsCreateRingBuffer(
    handle: Handle,
    layout: RingBufferLayout,
    protection: winMem.PAGE_PROTECTION_FLAGS,
) !RingBufferInfo {
    var sys_info: winSysInfo.SYSTEM_INFO = undefined;
    winSysInfo.GetSystemInfo(&sys_info);

    // Verify that our layout is valid
    // std.debug.print("Creating ring buffer with layout:\n", .{});
    // layout.formatDebug();

    const proc = std.os.windows.kernel32.GetCurrentProcess();

    // Step 1: Reserve placeholder memory region for the entire allocation
    // This reserves virtual address space for header + buffer + buffer (for wraparound)
    const reserved_memory: [*]u8 = try virtualAlloc(
        proc,
        null,
        layout.total_size, // Header + Buffer + Buffer for wraparound
        .{
            .RESERVE = 1,
            .RESERVE_PLACEHOLDER = 1,
        },
        @bitCast(winMem.PAGE_NOACCESS),
        null,
        0,
    );

    // std.debug.print("Reserved memory at {*}, size: {d}\n", .{ reserved_memory, layout.total_size });

    // Step 2: Split the placeholder into three regions

    // Split off the header region
    // const free_result1 = std.os.windows.VirtualFree(
    //     reserved_memory,
    //     layout.header_size_aligned,
    //     @intFromEnum(winMem.MEM_RELEASE) | @intFromEnum(winMem.MEM_PRESERVE_PLACEHOLDER),
    // );

    // if (free_result1 != winZig.TRUE) {
    //     return error.VirtualFreeFailed;
    // }
    std.os.windows.VirtualFree(
        reserved_memory,
        layout.header_size_aligned,
        @as(u32, @intFromEnum(winMem.MEM_RELEASE)) | @as(u32, @intFromEnum(winMem.MEM_PRESERVE_PLACEHOLDER)),
    );

    // Check if an error occurred after the call
    var err = std.os.windows.kernel32.GetLastError();
    if (err != .SUCCESS) {
        std.debug.print("VirtualFree failed with error: {any}\n", .{err});
        return error.VirtualFreeFailed;
    }

    // std.debug.print("Split header region: {d} bytes\n", .{layout.header_size_aligned});

    // Calculate pointers to the placeholder regions
    const placeholder_header = reserved_memory;
    const placeholder_buffer: [*]u8 = @ptrCast(reserved_memory + layout.header_size_aligned);

    // Split the first buffer region
    std.os.windows.VirtualFree(
        placeholder_buffer,
        layout.buffer_size_aligned,
        @as(u32, @intFromEnum(winMem.MEM_RELEASE)) | @as(u32, @intFromEnum(winMem.MEM_PRESERVE_PLACEHOLDER)),
    );

    // Check if an error occurred after the call
    err = std.os.windows.kernel32.GetLastError();
    if (err != .SUCCESS) {
        std.debug.print("VirtualFree failed with error: {any}\n", .{err});
        return error.VirtualFreeFailed;
    }

    // std.debug.print("Split first buffer region: {d} bytes\n", .{layout.buffer_size_aligned});

    // Calculate the second buffer placeholder address
    const placeholder_secondary: [*]u8 = @ptrCast(placeholder_buffer + layout.buffer_size_aligned);

    // std.debug.print(
    //     "Placeholders:\n  Header: {*}\n  Buffer: {*}\n  Secondary: {*}\n",
    //     .{ placeholder_header, placeholder_buffer, placeholder_secondary },
    // );

    // Step 3: Create mapped views of the file mapping

    // Map the header region (offset 0 in the file mapping)
    const header_view = try mapViewOfFile(
        handle,
        proc,
        placeholder_header,
        0, // Offset 0
        layout.header_size_aligned,
        .{ .REPLACE_PLACEHOLDER = 1 },
        @bitCast(protection),
        null,
        0,
    );

    // std.debug.print("Mapped header view at {*}\n", .{header_view});

    // Map the first buffer region (offset = header size in the file mapping)
    const buffer_view = try mapViewOfFile(
        handle,
        proc,
        placeholder_buffer,
        layout.header_size_aligned, // Offset after header
        layout.buffer_size_aligned,
        .{ .REPLACE_PLACEHOLDER = 1 },
        @bitCast(protection),
        null,
        0,
    );

    // std.debug.print("Mapped buffer view at {*}\n", .{buffer_view});

    // Map the second buffer region with the same offset as the first buffer
    // This creates the wrap-around effect
    const secondary_view = try mapViewOfFile(
        handle,
        proc,
        placeholder_secondary,
        layout.header_size_aligned, // Same offset as buffer view
        layout.buffer_size_aligned,
        .{ .REPLACE_PLACEHOLDER = 1 },
        @bitCast(protection),
        null,
        0,
    );

    // std.debug.print("Mapped secondary view at {*}\n", .{secondary_view});

    // Create slices for the mapped regions
    return RingBufferInfo{
        .header = header_view[0..layout.header_size_aligned],
        .buffer = buffer_view[0..layout.buffer_size_aligned],
        .secondary_view = secondary_view[0..layout.buffer_size_aligned],
        // Create a virtual "combined" buffer that tricks the compiler into allowing access past buffer length
        .combined_buffer = blk: {
            // Create a pointer to the buffer
            const ptr: [*]u8 = buffer_view;
            // Create a slice that spans both the original buffer and its mirror
            // This is a "trick" since they're not physically contiguous,
            // but the virtual memory mapping makes them appear contiguous
            break :blk ptr[0..(layout.buffer_size_aligned * 2)];
        },
        .layout = layout,
        .section_handle = handle,
    };
}

/// Creates a new Windows shared memory ring buffer with a header area.
///
/// Parameters:
/// - name: Name of the shared memory object
/// - element_size: Size of each element in bytes
/// - element_count: Number of elements the buffer should hold
/// - header_size: Size of the header area in bytes
///
/// Returns:
/// - A RingBufferInfo structure containing the buffer metadata and views
///
/// This function creates a Windows shared memory ring buffer with a header area.
/// It can be accessed by other processes using the same name.
pub fn windowsCreateRingBufferWithHeader(
    name: []const u8,
    element_size: usize,
    element_count: usize,
    header_size: usize,
) !RingBufferInfo {
    // Calculate the memory layout
    const layout = try RingBufferLayout.init(element_size, element_count, header_size);

    // Calculate the section size (header + one copy of the buffer)
    const section_size = layout.header_size_aligned + layout.buffer_size_aligned;

    // Create a null-terminated version of the name
    var buffer = [_]u8{0} ** std.fs.MAX_NAME_BYTES;
    const name_z = try std.fmt.bufPrintZ(&buffer, "{s}", .{name});

    // Create the file mapping object
    const handle = try createFileDescriptor(name_z, section_size);

    // Create the ring buffer
    return try windowsCreateRingBuffer(handle, layout, .{ .PAGE_READWRITE = 1 });
}

/// Opens an existing Windows shared memory ring buffer.
///
/// Parameters:
/// - name: Name of the shared memory object
/// - element_size: Size of each element in bytes (must match the original)
/// - element_count: Number of elements the buffer should hold (must match the original)
/// - header_size: Size of the header area in bytes (must match the original)
///
/// Returns:
/// - A RingBufferInfo structure containing the buffer metadata and views
///
/// This function opens an existing Windows shared memory ring buffer.
/// The parameters must match those used when creating the buffer.
pub fn windowsOpenRingBuffer(
    name: []const u8,
    element_size: usize,
    element_count: usize,
    header_size: usize,
) !RingBufferInfo {
    // Calculate the memory layout (same calculation as when creating)
    const layout = try RingBufferLayout.init(element_size, element_count, header_size);

    // Create a null-terminated version of the name
    var buffer = [_]u8{0} ** std.fs.MAX_NAME_BYTES;
    const name_z = try std.fmt.bufPrintZ(&buffer, "{s}", .{name});

    // Open the existing file mapping object
    const flags_handle: winMem.FILE_MAP = .{ .READ = 1, .WRITE = 1 };
    const handle = try openFileDescriptor(name_z, flags_handle);

    // Create the ring buffer with the same layout
    return try windowsCreateRingBuffer(handle, layout, .{ .PAGE_READWRITE = 1 });
}

/// Checks if a Windows shared memory ring buffer with the given name exists.
///
/// Parameters:
/// - name: Name of the shared memory object
///
/// Returns:
/// - true if the buffer exists, false otherwise
pub fn windowsRingBufferExists(name: []const u8) !bool {
    var buffer: [std.fs.MAX_NAME_BYTES]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&buffer, "{s}", .{name}) catch unreachable;

    const flags_handle: winMem.FILE_MAP = .{ .READ = 1 };

    const handle = openFileDescriptor(name_z, flags_handle) catch {
        // Any error when opening means the file mapping doesn't exist
        // No need to check specific error code - simplifies compatibility
        return false;
    };

    // If we got here, the mapping exists, so close the handle
    winZig.closeHandle(handle);
    return true;
}

/// Closes and cleans up a Windows shared memory ring buffer.
///
/// Parameters:
/// - rb: Pointer to the RingBufferInfo structure to close
///
/// This function unmaps all views, closes the file mapping handle,
/// and zeros out the RingBufferInfo structure.
pub fn windowsCloseRingBuffer(rb: *RingBufferInfo) !void {
    // Unmap the views in reverse order
    if (winMem.UnmapViewOfFile(@ptrCast(rb.secondary_view.ptr)) == winZig.FALSE) {
        switch (std.os.windows.kernel32.GetLastError()) {
            else => |err| return std.os.windows.unexpectedError(err),
        }
    }

    if (winMem.UnmapViewOfFile(@ptrCast(rb.buffer.ptr)) == winZig.FALSE) {
        switch (std.os.windows.kernel32.GetLastError()) {
            else => |err| return std.os.windows.unexpectedError(err),
        }
    }

    if (winMem.UnmapViewOfFile(@ptrCast(rb.header.ptr)) == winZig.FALSE) {
        switch (std.os.windows.kernel32.GetLastError()) {
            else => |err| return std.os.windows.unexpectedError(err),
        }
    }

    // Close the file mapping handle
    winZig.closeHandle(rb.section_handle);

    // Zero out the structure
    rb.* = undefined;
}

/// Example of a ring buffer header structure
const RingBufferHeader = struct {
    tail: u64,
    head: u64,
    count: u64,
    resolution: f64,
    num_channels: f32,
};

// Test large header with small buffer
test "ring buffer - large header small buffer" {
    if (@import("builtin").os.tag != .windows) {
        return error.SkipZigTest;
    }
    std.debug.print("\nring buffer - large header small buffer\n", .{});

    // Define test parameters
    const buffer_name = "Global\\test_large_header";
    const element_type = u64;
    const element_size = @sizeOf(element_type);
    const element_count: usize = 10;
    const large_header_size = 1000; // 1KB header

    // Create the buffer
    var ring_buffer = try windowsCreateRingBufferWithHeader(
        buffer_name,
        element_size,
        element_count,
        large_header_size,
    );
    defer windowsCloseRingBuffer(&ring_buffer) catch {};

    // Verify layout calculations
    try std.testing.expect(ring_buffer.layout.header_size_raw == large_header_size);
    try std.testing.expect(ring_buffer.layout.header_size_aligned >= large_header_size);
    try std.testing.expect(ring_buffer.layout.header_size_aligned % ring_buffer.layout.page_size == 0);
    try std.testing.expect(ring_buffer.layout.actual_element_count >= element_count);

    // Test the buffer with a simple pattern
    const buffer: []element_type = @ptrCast(
        @as(
            [*]element_type,
            @ptrCast(@alignCast(ring_buffer.combined_buffer.ptr)),
        )[0..(ring_buffer.layout.actual_element_count * 2)],
    );

    // Write a pattern
    for (0..10) |i| {
        buffer[i] = @intCast(i);
    }

    // Verify the pattern
    try std.testing.expectEqualSlices(
        element_type,
        &[_]element_type{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 },
        buffer[0..10],
    );
}

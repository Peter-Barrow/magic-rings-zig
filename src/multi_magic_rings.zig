const std = @import("std");
const MagicRingWithHeader = @import("magic_ring.zig").MagicRingWithHeader;
const State = @import("magic_ring.zig").State;
const RingBufferLayout = @import("magic_ring.zig").RingBufferLayout;
const getAllocationGranularity = @import("magic_ring.zig").getAllocationGranularity;

/// Represents an allocation strategy for a single field in a multi-field ring buffer.
/// This struct contains the calculated memory requirements and allocation parameters
/// needed to efficiently allocate memory for a specific field type.
const AllocationStrategy = struct {
    /// The type of the field this strategy applies to
    field_type: type,
    /// The number of elements that will be allocated for this field
    element_count: usize,
    /// The total number of bytes required for this field's allocation
    bytes: usize,
    /// The number of memory pages required for this field's allocation
    pages: usize,
};

/// Calculates the least common multiple (LCM) of multiple numbers.
///
/// This function computes the LCM of an array of numbers, which is essential
/// for determining the minimum number of elements needed to ensure all field
/// allocations align properly with system memory granularity requirements.
///
/// Parameters:
/// - numbers: Slice of numbers to compute the LCM for
///
/// Returns:
/// - The least common multiple of all input numbers
///
/// The algorithm handles different array lengths efficiently:
/// - Single number: returns the number itself
/// - Two numbers: uses built-in LCM function
/// - Multiple numbers: iteratively computes LCM while tracking the minimum
fn lcm_of_many(numbers: []usize) usize {
    return switch (numbers.len) {
        1 => numbers[0],
        2 => std.math.lcm(numbers[0], numbers[1]),
        else => blk: {
            var lowest: usize = std.math.maxInt(usize);
            var multiple = std.math.lcm(numbers[0], numbers[1]);
            for (numbers[2..]) |n| {
                multiple = std.math.lcm(multiple, n);
                lowest = @min(lowest, multiple);
            }
            break :blk multiple;
        },
    };
}

/// Calculates memory allocation strategies for each field in a multi-field ring buffer.
/// 
/// This function determines the optimal memory allocation parameters for each field type
/// in a struct-based ring buffer, ensuring proper memory alignment and efficient usage
/// based on the system's allocation granularity.
///
/// 1. Computing allocation ratios for each field type based on granularity alignment
/// 2. Finding the least common multiple (LCM) of all ratios to determine minimum elements
/// 3. Scaling up the allocation if more elements are requested than the minimum
/// 4. Returning allocation strategies with calculated bytes, pages, and element counts
///
/// Parameters:
///   - T: The struct type containing the fields to allocate for
///   - requested_elements: The minimum number of elements requested for allocation
///
/// Returns:
///   An array of AllocationStrategy structs, one for each field in the input struct,
///   containing the calculated memory requirements and allocation parameters.
///
/// The returned strategies ensure that:
/// - All field allocations are properly aligned to system granularity
/// - Memory usage is optimized by using the LCM of field size ratios
/// - The actual element count meets or exceeds the requested count
/// - Each field gets the same logical element count for consistent indexing
fn allocationStrategy(
    comptime T: type,
    requested_elements: usize,
) []AllocationStrategy {
    const granularity = getAllocationGranularity();
    const info = @typeInfo(T);
    const fields = info.@"struct".fields;

    var ratios = [_]usize{1} ** fields.len;
    inline for (fields, &ratios) |field, *ratio| {
        ratio.* = @divFloor(granularity, std.math.gcd(granularity, @sizeOf(field.type)));
    }

    const min_elements = lcm_of_many(&ratios);

    var strategies: [fields.len]AllocationStrategy = undefined;
    inline for (fields, &strategies) |field, *strategy| {
        const total_bytes = @sizeOf(field.type) * min_elements;
        strategy.* = .{
            .field_type = field.type,
            .bytes = total_bytes,
            .pages = @divFloor(total_bytes, granularity),
            .element_count = min_elements,
        };
    }

    if (requested_elements <= min_elements) return &strategies;

    const multiplier: usize = @intFromFloat(
        std.math.ceil(
            @as(f64, @floatFromInt(requested_elements)) / @as(
                f64,
                @floatFromInt(min_elements),
            ),
        ),
    );
    const actual_elements = multiplier * min_elements;

    inline for (fields, &strategies) |field, *strategy| {
        const total_bytes = @sizeOf(field.type) * actual_elements;
        strategy.* = .{
            .field_type = field.type,
            .bytes = total_bytes,
            .pages = @divFloor(total_bytes, granularity),
            .element_count = min_elements,
        };
    }

    return &strategies;
}

/// Finds the allocation strategy for a specific type from an array of strategies.
///
/// This is a compile-time function that searches through the provided allocation
/// strategies to find the one that matches the requested type.
///
/// Parameters:
/// - T: The type to search for in the strategies
/// - strategies: Array of AllocationStrategy structs to search through
///
/// Returns:
/// - The AllocationStrategy struct for the specified type
///
/// Errors:
/// - Compile error if the type is not found in the strategies array
fn strategyForType(comptime T: type, strategies: []AllocationStrategy) AllocationStrategy {
    inline for (strategies) |strat| {
        if (strat.field_type == T) return strat;
    }
    @compileError("Type not present");
}

test allocationStrategy {
    const test_struct = struct {
        first: u8,
        second: u32,
        third: u15,
        fourth: struct { x: f64, y: f64 },
    };

    const strategies = allocationStrategy(test_struct, 1234);
    inline for (strategies) |strat| {
        std.debug.print(
            "field - {s}:\n\telements:{d}\n\tbytes:{d}\n\tpages:{d}\n\n",
            .{
                @typeName(strat.field_type),
                strat.element_count,
                strat.bytes,
                strat.pages,
            },
        );
    }

    inline for (strategies[1..], 0..) |strat, i| {
        try std.testing.expectEqual(strategies[i].element_count, strat.element_count);
    }
}

/// Creates a multi-field ring buffer type that manages separate ring buffers for each field of a struct.
///
/// Parameters:
///   - T: The struct type whose fields will become separate ring buffers.
///        Each field in this struct will get its own ring buffer of the corresponding type.
///   - H: The header type to use for each ring buffer's metadata.
///        This type is passed to MagicRingWithHeader for each field.
///
/// Returns:
///   A type that provides a multi-field ring buffer interface with methods for:
///   - Creating and opening ring buffer sets
///   - Pushing data to all fields simultaneously or individual fields
///   - Slicing data from all fields or individual fields
///   - Accessing individual field values at specific indices
///
/// Example usage:
///   ```zig
///   const Point = struct { x: f64, y: f64, timestamp: u64 };
///   const MultiRing = MultiMagicRing(Point, struct {});
///   var ring = try MultiRing.create("points", 1000, allocator);
///   _ = ring.push(Point{ .x = 1.0, .y = 2.0, .timestamp = 12345 });
///   ```
pub fn MultiMagicRing(comptime T: type, comptime H: type) type {
    
    const info = switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => @compileError("Must be a struct"),
    };

    return struct {
        const Self = @This();
        // const Header = State.withFields(H);

        const Fields = std.meta.FieldEnum(T);

        fn FieldSlice(field: Fields) type {
            return []@FieldType(T, @tagName(field));
        }

        /// Converts a struct to its struct-of-arrays representation:
        /// S := {a: u8, b: f32} -> S := {a: []u8, b: []f32}
        /// Each field becomes a slice of its corresponding type, allowing for efficient
        /// batch operations on columnar data. Used by slice operations to return
        /// synchronized views across all field ring buffers.
        const Slice = blk: {
            var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
            for (info.fields, &fields) |f, *field| {
                field.* = .{
                    .name = f.name,
                    .type = []f.type,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(f.type),
                };
            }
            break :blk @Type(.{
                .@"struct" = .{
                    .layout = .auto,
                    .fields = &fields,
                    .decls = &.{},
                    .is_tuple = false,
                },
            });
        };

        /// Hold the push result (index) for each field in the original struct.
        /// Each field becomes a u64 representing the index where data was pushed in the corresponding
        /// ring buffer. Used by push operations to return synchronized push results across all
        /// field ring buffers.
        const Pushed = blk: {
            var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
            for (info.fields, &fields) |f, *field| {
                field.* = .{
                    .name = f.name,
                    .type = u64,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(f.type),
                };
            }
            break :blk @Type(.{
                .@"struct" = .{
                    .layout = .auto,
                    .fields = &fields,
                    .decls = &.{},
                    .is_tuple = false,
                },
            });
        };

        /// Converts a type 'T', a struct with fields, to a 'Struct-of-Rings' formulism.
        /// Each field becomes a MagicRingWithHeader of its corresponding type, providing individual
        /// ring buffer management for each field while maintaining type safety and unified operations.
        const RingBuffers = blk: {
            var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
            for (info.fields, &fields) |ifield, *field| {
                const RingType = MagicRingWithHeader(ifield.type, H);
                field.* = std.builtin.Type.StructField{
                    .name = ifield.name,
                    .type = RingType,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(RingType),
                };
            }

            break :blk @Type(std.builtin.Type{
                .@"struct" = std.builtin.Type.Struct{
                    .layout = .auto,
                    .fields = &fields,
                    .decls = &.{},
                    .is_tuple = false,
                },
            });
        };

        rings: RingBuffers,

        name: []const u8,

        /// Creates a new multi-field ring buffer with the specified parameters.
        ///
        /// This function creates separate ring buffers for each field in the struct type T,
        /// with each ring buffer optimally sized based on memory allocation strategies.
        /// All ring buffers share the same logical element count for synchronized access.
        ///
        /// Parameters:
        /// - name: Base name for the ring buffer set (individual buffers get field suffixes)
        /// - length: Requested number of elements (actual size may be larger due to alignment)
        /// - allocator: Optional allocator for memory management operations
        ///
        /// Returns:
        /// - A new MultiMagicRing instance with all field buffers created and ready for use
        ///
        /// Errors:
        /// - error.SharedMemoryExists: If any field buffer with the computed name already exists
        /// - Various platform-specific errors from underlying ring buffer creation
        ///
        /// Example:
        /// ```zig
        /// const Point = struct { x: f64, y: f64 };
        /// const MultiRing = MultiMagicRing(Point, struct {});
        /// var ring = try MultiRing.create("points", 1000, allocator);
        /// ```
        pub fn create(name: []const u8, length: usize, allocator: ?std.mem.Allocator) !Self {
            var buffers: RingBuffers = .{};
            const strategies = allocationStrategy(T, length);

            inline for (info.fields) |field| {
                var name_buffer = [_]u8{0} ** std.fs.MAX_NAME_BYTES;

                const ring_name = try std.fmt.bufPrintZ(
                    &name_buffer,
                    "{s}-{s}",
                    .{ name, field.name },
                );

                const strat = strategyForType(field.type, strategies);

                const ring = try MagicRingWithHeader(field.type, H).create(
                    ring_name,
                    strat.element_count,
                    allocator,
                );

                @field(buffers, field.name) = ring;
            }

            return .{
                .name = name,
                .rings = buffers,
            };
        }

        /// Opens an existing multi-field ring buffer set.
        ///
        /// This function opens all the individual ring buffers that were previously created
        /// as part of a multi-field ring buffer set. The ring buffers must have been created
        /// with the same struct type and base name.
        ///
        /// Parameters:
        /// - name: Base name of the ring buffer set to open (matches name used in create)
        /// - allocator: Optional allocator for memory management operations
        ///
        /// Returns:
        /// - A MultiMagicRing instance connected to the existing ring buffer set
        ///
        /// Errors:
        /// - error.SharedMemoryDoesNotExist: If any required field buffer doesn't exist
        /// - Various platform-specific errors from underlying ring buffer opening
        ///
        /// Example:
        /// ```zig
        /// var ring = try MultiRing.open("points", allocator);
        /// defer ring.close() catch {};
        /// ```
        pub fn open(name: []const u8, allocator: ?std.mem.Allocator) !Self {
            var buffers: RingBuffers = .{};

            inline for (info.fields) |field| {
                var name_buffer = [_]u8{0} ** std.fs.MAX_NAME_BYTES;
                const ring_name = try std.fmt.bufPrintZ(
                    &name_buffer,
                    "{s}-{s}",
                    .{ name, field.name },
                );

                const ring = try MagicRingWithHeader(field.type, H).open(
                    ring_name,
                    allocator,
                );

                @field(buffers, field.name) = ring;
            }

            return .{
                .name = name,
                .rings = buffers,
            };
        }

        /// Closes the multi-field ring buffer and cleans up all resources.
        ///
        /// This function closes all individual field ring buffers and releases their
        /// associated shared memory resources. After calling this function, the
        /// MultiMagicRing instance should not be used.
        ///
        /// Parameters:
        /// - self: Pointer to the MultiMagicRing instance to close
        ///
        /// Errors:
        /// - Platform-specific errors during resource cleanup from any field buffer
        ///
        /// Note: This function attempts to close all field buffers even if some fail,
        /// but will return the first error encountered.
        pub fn close(self: *Self) !void {
            inline for (info.fields) |field| {
                @field(self.rings, field.name).close();
            }
        }

        /// Gets a slice of data from a specific field's ring buffer.
        ///
        /// This function provides access to a contiguous range of elements from one
        /// field's ring buffer, taking advantage of the magic ring buffer's seamless
        /// wraparound capability.
        ///
        /// Parameters:
        /// - self: Pointer to the MultiMagicRing instance
        /// - field: The field enum specifying which field buffer to slice from
        /// - start: Starting logical position (inclusive)
        /// - stop: Ending logical position (exclusive)
        ///
        /// Returns:
        /// - A slice containing the requested range of elements from the specified field
        ///
        /// Example:
        /// ```zig
        /// const x_values = ring.sliceField(.x, 10, 20); // Get x[10..20]
        /// ```
        pub fn sliceField(
            self: *Self,
            field: Fields,
            start: usize,
            stop: usize,
        ) FieldSlice(field) {
            return @field(self.rings, field).slice(start, stop);
        }

        /// Gets a slice of the oldest elements from a specific field's ring buffer.
        ///
        /// This function returns the oldest elements still in the ring buffer for the
        /// specified field, starting from the tail position.
        ///
        /// Parameters:
        /// - self: Pointer to the MultiMagicRing instance
        /// - field: The field enum specifying which field buffer to slice from
        /// - count: Number of oldest elements to include in the slice
        ///
        /// Returns:
        /// - A slice containing the oldest elements from the specified field
        ///
        /// Example:
        /// ```zig
        /// const oldest_y = ring.sliceFieldFromTail(.y, 5); // Get 5 oldest y values
        /// ```
        pub fn sliceFieldFromTail(self: *Self, field: Fields, count: u64) FieldSlice(field) {
            return @field(self.rings, @tagName(field)).sliceFromTail(count);
        }

        /// Gets a slice of the newest elements from a specific field's ring buffer.
        ///
        /// This function returns the newest elements in the ring buffer for the
        /// specified field, ending at the head position.
        ///
        /// Parameters:
        /// - self: Pointer to the MultiMagicRing instance
        /// - field: The field enum specifying which field buffer to slice from
        /// - count: Number of newest elements to include in the slice
        ///
        /// Returns:
        /// - A slice containing the newest elements from the specified field
        ///
        /// Example:
        /// ```zig
        /// const latest_x = ring.sliceFieldToHead(.x, 3); // Get 3 newest x values
        /// ```
        pub fn sliceFieldToHead(self: *Self, field: Fields, count: u64) FieldSlice(field) {
            return @field(self.rings, @tagName(field)).sliceToHead(count);
        }

        /// Gets the value at a specific logical index from a field's ring buffer.
        ///
        /// This function retrieves a single element from the specified field's ring buffer
        /// at the given logical index, where index 0 represents the oldest element still
        /// in the buffer.
        ///
        /// Parameters:
        /// - self: Pointer to the MultiMagicRing instance
        /// - field: The field enum specifying which field buffer to access
        /// - index: Logical index relative to the tail (0 = oldest element)
        ///
        /// Returns:
        /// - The value at the specified index in the field's ring buffer
        ///
        /// Example:
        /// ```zig
        /// const x_val = ring.valueAtInField(.x, 5); // Get the 6th oldest x value
        /// ```
        pub fn valueAtInField(self: *Self, field: Fields, index: u64) @FieldType(T, @tagName(field)) {
            return @field(self.rings, @tagName(field)).valueAt(index);
        }

        /// Pushes a single value to a specific field's ring buffer.
        ///
        /// This function adds one element to the specified field's ring buffer.
        /// When the buffer is full, this will overwrite the oldest element in that field.
        ///
        /// Parameters:
        /// - self: Pointer to the MultiMagicRing instance
        /// - field: The field enum specifying which field buffer to push to
        /// - value: The value to push to the specified field's buffer
        ///
        /// Returns:
        /// - The new cumulative count of elements pushed to that field's buffer
        ///
        /// Example:
        /// ```zig
        /// _ = ring.pushField(.x, 3.14);
        /// _ = ring.pushField(.y, 2.71);
        /// ```
        pub fn pushField(self: *Self, field: Fields, value: @FieldType(T, @tagName(field))) u64 {
            return @field(self.rings, @tagName(field)).push(value);
        }

        /// Pushes multiple values to a specific field's ring buffer.
        ///
        /// This function adds multiple elements to the specified field's ring buffer
        /// in a single operation, which is more efficient than multiple individual pushes.
        ///
        /// Parameters:
        /// - self: Pointer to the MultiMagicRing instance
        /// - field: The field enum specifying which field buffer to push to
        /// - values: Slice of values to push to the specified field's buffer
        ///
        /// Returns:
        /// - The new cumulative count of elements pushed to that field's buffer
        ///
        /// Example:
        /// ```zig
        /// const x_values = [_]f64{ 1.0, 2.0, 3.0 };
        /// _ = ring.pushValuesField(.x, &x_values);
        /// ```
        pub fn pushValuesField(self: *Self, field: Fields, values: []@FieldType(T, @tagName(field))) u64 {
            return @field(self.rings, @tagName(field)).pushValues(values);
        }

        /// Gets synchronized slices from all field ring buffers for a specific range.
        ///
        /// This function returns a struct-of-arrays view where each field becomes a slice
        /// containing the specified range of elements from that field's ring buffer.
        /// All slices represent the same logical time range across all fields.
        ///
        /// Parameters:
        /// - self: Pointer to the MultiMagicRing instance
        /// - start: Starting logical position (inclusive)
        /// - stop: Ending logical position (exclusive)
        ///
        /// Returns:
        /// - A Slice struct with synchronized slices from all field buffers
        ///
        /// Example:
        /// ```zig
        /// const data = ring.slice(10, 20);
        /// // data.x contains x[10..20], data.y contains y[10..20], etc.
        /// ```
        pub fn slice(self: *Self, start: usize, stop: usize) Slice {
            var result: Slice = undefined;

            inline for (info.fields) |field| {
                @field(result, field.name) = @field(self.rings, field.name).slice(start, stop);
            }
            return result;
        }

        /// Gets synchronized slices of the oldest elements from all field ring buffers.
        ///
        /// This function returns a struct-of-arrays view where each field becomes a slice
        /// containing the oldest elements from that field's ring buffer. All slices
        /// represent the same logical time period across all fields.
        ///
        /// Parameters:
        /// - self: Pointer to the MultiMagicRing instance
        /// - count: Number of oldest elements to include in each field's slice
        ///
        /// Returns:
        /// - A Slice struct with synchronized slices of oldest elements from all fields
        ///
        /// Example:
        /// ```zig
        /// const oldest = ring.sliceFromTail(5);
        /// // oldest.x contains 5 oldest x values, oldest.y contains 5 oldest y values
        /// ```
        pub fn sliceFromTail(self: *Self, count: u64) Slice {
            var result: Slice = undefined;
            inline for (info.fields) |field| {
                @field(result, field.name) = @field(self.rings, field.name).sliceFromTail(count);
            }
            return result;
        }

        /// Gets synchronized slices of the newest elements from all field ring buffers.
        ///
        /// This function returns a struct-of-arrays view where each field becomes a slice
        /// containing the newest elements from that field's ring buffer. All slices
        /// represent the same logical time period across all fields.
        ///
        /// Parameters:
        /// - self: Pointer to the MultiMagicRing instance
        /// - count: Number of newest elements to include in each field's slice
        ///
        /// Returns:
        /// - A Slice struct with synchronized slices of newest elements from all fields
        ///
        /// Example:
        /// ```zig
        /// const latest = ring.sliceToHead(3);
        /// // latest.x contains 3 newest x values, latest.y contains 3 newest y values
        /// ```
        pub fn sliceToHead(self: *Self, count: u64) Slice {
            var result: Slice = undefined;
            inline for (info.fields) |field| {
                @field(result, field.name) = @field(self.rings, field.name).sliceToHead(count);
            }
            return result;
        }

        /// Pushes a complete struct instance to all field ring buffers simultaneously.
        ///
        /// This function decomposes the input struct and pushes each field value to its
        /// corresponding ring buffer. This maintains synchronization across all fields,
        /// ensuring they all have the same logical timeline.
        ///
        /// Parameters:
        /// - self: Pointer to the MultiMagicRing instance
        /// - value: The struct instance to push (must be of type T)
        ///
        /// Returns:
        /// - A Pushed struct containing the new cumulative count for each field's buffer
        ///
        /// Example:
        /// ```zig
        /// const point = Point{ .x = 1.5, .y = 2.5, .timestamp = 12345 };
        /// const indices = ring.push(point);
        /// // indices.x, indices.y, indices.timestamp contain push counts
        /// ```
        pub fn push(self: *Self, value: T) Pushed {
            var result: Pushed = undefined;
            inline for (info.fields) |field| {
                @field(result, field.name) = @field(self.rings, field.name).push(@field(value, field.name));
            }
            return result;
        }

        /// Pushes multiple complete struct instances to all field ring buffers.
        ///
        /// This function takes an array of struct instances and pushes them one by one
        /// to maintain field synchronization. For better performance with large datasets,
        /// consider using pushSlice instead.
        ///
        /// Parameters:
        /// - self: Pointer to the MultiMagicRing instance
        /// - values: Slice of struct instances to push (each must be of type T)
        ///
        /// Returns:
        /// - A Pushed struct containing the final cumulative count for each field's buffer
        ///
        /// Example:
        /// ```zig
        /// const points = [_]Point{
        ///     Point{ .x = 1.0, .y = 2.0, .timestamp = 100 },
        ///     Point{ .x = 1.5, .y = 2.5, .timestamp = 101 },
        /// };
        /// const final_indices = ring.pushValues(&points);
        /// ```
        pub fn pushValues(self: *Self, values: []T) Pushed {
            var result: Pushed = undefined;
            for (values) |v| {
                result = self.push(v);
            }
            return result;
        }

        /// Pushes a struct-of-arrays slice to all field ring buffers efficiently.
        ///
        /// This function takes a Slice struct (where each field is an array) and pushes
        /// the arrays to their corresponding ring buffers using bulk operations. This is
        /// the most efficient way to push large amounts of structured data.
        ///
        /// Parameters:
        /// - self: Pointer to the MultiMagicRing instance
        /// - values: A Slice struct containing arrays for each field
        ///
        /// Returns:
        /// - A Pushed struct containing the new cumulative count for each field's buffer
        ///
        /// Example:
        /// ```zig
        /// const data = Slice{
        ///     .x = &[_]f64{ 1.0, 2.0, 3.0 },
        ///     .y = &[_]f64{ 4.0, 5.0, 6.0 },
        ///     .timestamp = &[_]u64{ 100, 101, 102 },
        /// };
        /// const indices = ring.pushSlice(data);
        /// ```
        pub fn pushSlice(self: *Self, values: Slice) Pushed {
            var result: Pushed = undefined;
            inline for (info.fields) |field| {
                const r = @field(self.rings, field.name).pushValues(@field(values, field.name));
                @field(result, field.name) = r;
            }
            return result;
        }

    };
}

test MultiMagicRing {
    const S = struct { x: f64, y: f64 };
    const MultiMagic = MultiMagicRing(S, struct {});

    const info = @typeInfo(MultiMagic.RingBuffers);
    inline for (info.@"struct".fields) |field| {
        std.debug.print("{s}:\t{s}\n", .{ field.name, @typeName(field.type) });
    }

    // const ring = try MultiMagic.create("test_multi_magic", 1000, std.testing.allocator);

}

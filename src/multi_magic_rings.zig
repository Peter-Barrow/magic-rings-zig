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

        pub fn close(self: *Self) !void {
            inline for (info.fields) |field| {
                @field(self.rings, field.name).close();
            }
        }

        pub fn sliceField(
            self: *Self,
            field: Fields,
            start: usize,
            stop: usize,
        ) FieldSlice(field) {
            return @field(self.rings, field).slice(start, stop);
        }

        pub fn sliceFieldFromTail(self: *Self, field: Fields, count: u64) FieldSlice(field) {
            return @field(self.rings, @tagName(field)).sliceFromTail(count);
        }

        pub fn sliceFieldToHead(self: *Self, field: Fields, count: u64) FieldSlice(field) {
            return @field(self.rings, @tagName(field)).sliceToHead(count);
        }

        pub fn valueAtInField(self: *Self, field: Fields, index: u64) @FieldType(T, @tagName(field)) {
            return @field(self.rings, @tagName(field)).valueAt(index);
        }

        pub fn pushField(self: *Self, field: Fields, value: @FieldType(T, @tagName(field))) u64 {
            return @field(self.rings, @tagName(field)).push(value);
        }

        pub fn pushValuesField(self: *Self, field: Fields, values: []@FieldType(T, @tagName(field))) u64 {
            return @field(self.rings, @tagName(field)).pushValues(values);
        }

        pub fn slice(self: *Self, start: usize, stop: usize) Slice {
            var result: Slice = undefined;

            inline for (info.fields) |field| {
                @field(result, field.name) = @field(self.rings, field.name).slice(start, stop);
            }
            return result;
        }

        pub fn sliceFromTail(self: *Self, count: u64) Slice {
            var result: Slice = undefined;
            inline for (info.fields) |field| {
                @field(result, field.name) = @field(self.rings, field.name).sliceFromTail(count);
            }
            return result;
        }

        pub fn sliceToHead(self: *Self, count: u64) Slice {
            var result: Slice = undefined;
            inline for (info.fields) |field| {
                @field(result, field.name) = @field(self.rings, field.name).sliceToHead(count);
            }
            return result;
        }

        pub fn push(self: *Self, value: T) Pushed {
            var result: Pushed = undefined;
            inline for (info.fields) |field| {
                @field(result, field.name) = @field(self.rings, field.name).push(@field(value, field.name));
            }
            return result;
        }

        pub fn pushValues(self: *Self, values: []T) Pushed {
            var result: Pushed = undefined;
            for (values) |v| {
                result = self.push(v);
            }
            return result;
        }

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

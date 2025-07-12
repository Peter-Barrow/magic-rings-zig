const std = @import("std");
const MagicRingWithHeader = @import("magic_ring.zig").MagicRingWithHeader;
const State = @import("magic_ring.zig").State;
const RingBufferLayout = @import("magic_ring.zig").RingBufferLayout;
const getAllocationGranularity = @import("magic_ring.zig").getAllocationGranularity;

const AllocationStrategy = struct {
    field_type: type,
    element_count: usize,
    bytes: usize,
    pages: usize,
};

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

pub fn MultiMagicRing(comptime T: type, comptime H: type) type {
    // const info = @typeInfo(T);
    // // TODO: should include enums
    // if (info != .@"struct") @compileError("must be a struct");
    // const fields = switch (info) {
    //     .@"struct" => |s| s.fields,
    //     else => @compileError("Must be a struct"),
    // };

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

        // Create magic rings for each field
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

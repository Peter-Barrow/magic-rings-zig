# Magic-Rings-Zig

**Magic-Rings-Zig** is a high-performance ring buffer library for Zig that implements *magic ring buffers* with advanced struct-of-arrays support. It provides seamless wraparound access without modulo arithmetic and supports both single-field and multi-field ring buffers optimized for columnar data processing.

The library supports Linux, FreeBSD (via `memfd_create` or `shm_open`/`shm_unlink`), and Windows platforms with cross-platform shared memory capabilities for inter-process communication, built on top of [shared-memory-zig](https://github.com/Peter-Barrow/shared-memory-zig).

**STATUS: Stable Core with Active Development** - The core functionality is stable and battle-tested, with ongoing development of advanced features. Built and tested with Zig 0.14.0, tracking subsequent releases.

## Key Features

- **Magic Ring Buffers**: Eliminates wraparound handling via virtual memory mapping
- **Multi-Field Ring Buffers**: Struct-of-arrays processing for columnar data
- **Custom Headers**: Extensible metadata support for application-specific needs
- **Cross-Platform**: Linux, FreeBSD, and Windows support with shared memory
- **Zero-Copy Operations**: Direct memory access with CPU cache efficiency
- **Type Safety**: Compile-time type checking for both elements and headers

## How Magic Ring Buffers Work

A typical ring buffer requires modulo arithmetic for every access:

```
Traditional Ring Buffer:
+---+---+---+---+---+---+---+---+---+---+
| 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | <-- Buffer slots (indices)
+---+---+---+---+---+---+---+---+---+---+
                  ^               ^
                  |               |
                HEAD             TAIL
```

The *magic ring buffer* uses virtual memory mapping to create a seamless view:

```
Virtual Memory Layout:
+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
| 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
  \__________ First Mapping __________/   \_____________Mirror ____________/
```

While maintaining a single physical memory allocation:

```
Physical Memory Mapping:
+---+---+---+---+---+---+---+---+---+---+
| 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
+---+---+---+---+---+---+---+---+---+---+
  \__________ Original Buffer ________/
```

This allows contiguous access across the buffer boundary without special wraparound handling.

## Installation

Create a `build.zig.zon` file:

```zig
.{
    .name = "my-project",
    .version = "0.0.0",
    .dependencies = .{
        .magic_rings = .{
            .url = "https://github.com/Peter-Barrow/magic-rings-zig/archive/<git-ref-here>.tar.gz",
            .hash = "...",
        },
    },
}
```

Add to your `build.zig`:

```zig
const magic_rings = b.dependency("magic_rings", .{});
exe.root_module.addImport("magic_rings", magic_rings.module("magic_rings"));
```

## Usage Examples

### Basic Magic Ring Buffer

```zig
const std = @import("std");
const magic_rings = @import("magic_rings");

// Create a ring buffer for u64 values with custom header
const Header = struct { sample_rate: f64, channels: u32 };
const Ring = magic_rings.MagicRingWithHeader(u64, Header);

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

// Create a new ring buffer
var ring = try Ring.create("my_buffer", 1024, allocator);
defer ring.close() catch {};

// Set custom header fields
ring.header.sample_rate = 44100.0;
ring.header.channels = 2;

// Push data
_ = ring.push(42);
_ = ring.push(123);

// Get slices that seamlessly wrap around
const data = ring.sliceFromTail(2); // [42, 123]

// Push bulk data
const values = [_]u64{ 1, 2, 3, 4, 5 };
_ = ring.pushValues(&values);
```

### Multi-Field Ring Buffer (Struct-of-Arrays)

```zig
// Define a point structure
const Point = struct {
    x: f64,
    y: f64,
    timestamp: u64,
};

// Create multi-field ring buffer
const MultiRing = magic_rings.MultiMagicRing(Point, struct {});
var multi = try MultiRing.create("points", 1000, allocator);
defer multi.close() catch {};

// Push complete structs (gets decomposed into separate field buffers)
const point = Point{ .x = 1.5, .y = 2.5, .timestamp = 12345 };
_ = multi.push(point);

// Access individual fields efficiently
const x_values = multi.sliceField(.x, 0, 10);     // Get 10 x coordinates
const recent_timestamps = multi.sliceFieldToHead(.timestamp, 5); // Last 5 timestamps

// Get synchronized slices across all fields
const recent_data = multi.sliceToHead(5);
// recent_data.x contains last 5 x values
// recent_data.y contains last 5 y values  
// recent_data.timestamp contains last 5 timestamps

// Push columnar data efficiently
const columnar_data = MultiRing.Slice{
    .x = &[_]f64{ 1.0, 2.0, 3.0 },
    .y = &[_]f64{ 4.0, 5.0, 6.0 },
    .timestamp = &[_]u64{ 100, 101, 102 },
};
_ = multi.pushSlice(columnar_data);
```

### Shared Memory Between Processes

```zig
// Process 1: Create and write
var ring = try Ring.create("/shared_buffer", 1024, null);
_ = ring.push(42);

// Process 2: Open and read  
var ring2 = try Ring.open("/shared_buffer", null);
const value = ring2.valueAt(0); // 42
```

## Performance Benefits

### Single-Field Buffers
- **Zero modulo arithmetic** for wraparound access
- **Contiguous memory access** improves CPU cache performance
- **Direct slicing** across buffer boundaries without copying

### Multi-Field Buffers  
- **Struct-of-Arrays layout** for better cache locality when processing specific fields
- **SIMD-friendly** memory patterns for vectorized operations
- **Reduced memory waste** from struct padding and alignment
- **Efficient columnar processing** for data analysis workloads

## Use Cases

- **High-frequency data streams** (audio processing, sensor data, network packets)
- **Inter-process communication** with shared circular buffers
- **Real-time systems** requiring predictable, low-latency access  
- **Time-series data processing** with efficient columnar access
- **Logging systems** with circular log buffers
- **Scientific computing** with large datasets requiring efficient field access

## Platform Support

| Platform | Shared Memory | Anonymous Memory |
|----------|---------------|------------------|
| Linux    | `shm_open` / `memfd_create` | `memfd_create` |
| FreeBSD  | `shm_open` | Limited |  
| Windows  | `CreateFileMapping` | `CreateFileMapping` |

## API Reference

### MagicRingWithHeader(T, H)
- `create(name, length, allocator)` - Create new ring buffer
- `open(name, allocator)` - Open existing ring buffer  
- `close()` - Clean up resources
- `push(value)` - Add single element
- `pushValues(slice)` - Add multiple elements
- `slice(start, stop)` - Get range with wraparound
- `sliceFromTail(count)` - Get oldest elements
- `sliceToHead(count)` - Get newest elements
- `valueAt(index)` - Get element at logical index

### MultiMagicRing(T, H)
- All single-field operations plus:
- `sliceField(field, start, stop)` - Access specific field
- `pushField(field, value)` - Push to specific field
- `push(struct_value)` - Push complete struct (decomposed)
- `pushSlice(columnar_data)` - Efficient bulk columnar insert

## Contributing

Contributions are welcome! Please ensure:
- Code follows Zig style conventions
- Tests pass on all supported platforms  
- Documentation is updated for new features
- Performance-critical paths are benchmarked

## License

MIT

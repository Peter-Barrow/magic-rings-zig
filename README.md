# Magic-Rings-Zig

**Magic-Rings-Zig** is a small library to implement *magic ring buffers* available for Linux and Unix based platforms supporting either `memfd_create` or `shm_open` and `shm_unlink` as well as Windows.
This ring buffer implementation makes use of a second mapping of the underlying data to allow reading off the end of buffer allocation and letting the OS and hardware take care of getting your cursor to wraparound to the beginning of the buffer.

**STATUS: Unstable and feature incomplete** The core of this library does everything that I need at the moment but the user facing layer needs finishing. The core functionality covers everything that I need but to be most useful this needs a complete implementation for structure-of-arrays and methods to manage which buffers are available. It has been built and tested with Zig 0.13.0 with plans to keep it line with subsequent releases.

## Overview

A typical ring buffer implementation requires the use of modulo division to find each index and is essentially just an arrys with context looking something like the following:
```
+---+---+---+---+---+---+---+---+---+---+
| 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | <-- Buffer slots (indices)
+---+---+---+---+---+---+---+---+---+---+
                  ^               ^
                  |               |
                HEAD             TAIL
```

The *magic ring buffer* however looks something like this instead:
```
Virtual Memory Layout:
+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
| 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
  \__________ First Mapping __________/   \_____________Duplicate ____________/
 ```
Whilst maintaining an underlying memory layout like so.
```

Physical Memory Mapping:
+---+---+---+---+---+---+---+---+---+---+
| 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
+---+---+---+---+---+---+---+---+---+---+
  \__________ Original Buffer ________/
```

The idea here is to reserve twice the amount of virtual memory that is required and maintain a duplicate of the physical memory in the process.
This way we can `mmap` the data twice placing the second exactly at the end of the first.
The result of this is that we now only need to calculate a single absolute position in our buffer, using modulo division, and can happily work with a continguous segment of our buffer up to it's full length.

## Installation

Create a `build.zig.zon` file like this:

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

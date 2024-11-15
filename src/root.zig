const magic_ring = switch (@import("builtin").target.os.tag) {
    .linux, .freebsd => @import("posix.zig"),
    .windows => @import("windows.zig"),
    else => @compileError("Platform not supported"),
};

test {
    _ = magic_ring;
}

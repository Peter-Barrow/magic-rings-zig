const magic_ring = switch (@import("builtin").target.os.tag) {
    .linux, .freebsd => @import("platforms/posix.zig"),
    .windows => @import("platforms/windows.zig"),
    else => @compileError("Platform not supported"),
};

test {
    _ = magic_ring;
}

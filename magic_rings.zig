const magic_ring = @import("src/magic_ring.zig");
const multi_magic = @import("src/multi_magic_rings.zig");

pub const State = magic_ring.State;
pub const MagicRing = magic_ring.MagicRing;
pub const MultiMagicRing = multi_magic.MultiMagicRing;

test "ref all decls" {
    _ = @import("src/magic_ring.zig");
    _ = @import("src/multi_magic_rings.zig");
}

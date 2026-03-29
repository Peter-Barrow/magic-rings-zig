const magic_ring = @import("magic_ring.zig");
const multi_magic = @import("multi_magic_rings.zig");

pub const MagicRing = magic_ring.MagicRingWithHeader;
pub const MultiMagicRing = multi_magic.MultiMagicRing;

test "ref all decls" {
    _ = @import("magic_ring.zig");
    _ = @import("multi_magic_rings.zig");
}

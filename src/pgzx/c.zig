const std = @import("std");

pub const c = @import("c_translated");

test {
    std.testing.refAllDecls(@This());
}

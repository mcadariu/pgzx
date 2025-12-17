const std = @import("std");

const pg = @import("pgzx_pgsys");
const collections = @import("collections.zig");
const meta = @import("meta.zig");

const generated = @import("gen_node_tags");

pub const Tag = generated.Tag;

pub const List = collections.list.PointerListOf(pg.c.Node);

pub inline fn intVal(node: anytype) c_int {
    const n = safeCastNode(pg.c.Integer, node) orelse {
        @panic("Expected Integer node");
    };
    return n.ival;
}

pub inline fn floatVal(node: anytype) f64 {
    const n = safeCastNode(pg.c.Float, node) orelse {
        @panic("Expected Float node");
    };
    return std.fmt.parseFloat(f64, std.mem.span(n.fval));
}

pub inline fn strVal(node: anytype) [:0]const u8 {
    const n = safeCastNode(pg.c.String, node) orelse {
        @panic("Expected String node");
    };
    return std.mem.span(n.sval);
}

pub inline fn boolVal(node: anytype) bool {
    const n = safeCastNode(pg.c.Boolean, node) orelse {
        @panic("Expected Boolean node");
    };
    return n.boolval;
}

pub inline fn make(comptime T: type) *T {
    const node: *pg.c.Node = @ptrCast(@alignCast(pg.c.palloc0(@sizeOf(T))));
    node.*.type = @intFromEnum(mustFindTag(T));
    return @ptrCast(@alignCast(node));
}

pub inline fn create(initFrom: anytype) *@TypeOf(initFrom) {
    const node = make(@TypeOf(initFrom));
    node.* = initFrom;
    setTag(node, mustFindTag(@TypeOf(initFrom)));
    return node;
}

pub inline fn initNode(initFrom: anytype) @TypeOf(initFrom) {
    var node = initFrom;
    setTag(&node, mustFindTag(@TypeOf(initFrom)));
    return node;
}

fn mustFindTag(comptime T: type) Tag {
    return generated.findTag(T) orelse @compileError("No tag found for type");
}

pub inline fn tag(node: anytype) Tag {
    return @enumFromInt(asNodePtr(node).*.type);
}

pub inline fn setTag(node: anytype, t: Tag) void {
    asNodePtr(node).*.type = @intFromEnum(t);
}

pub inline fn isA(node: anytype, t: Tag) bool {
    return tag(node) == t;
}

pub inline fn castNode(comptime T: type, node: anytype) *T {
    return @ptrCast(@alignCast(asNodePtr(node)));
}

pub inline fn safeCastNode(comptime T: type, node: anytype) ?*T {
    if (@typeInfo(@TypeOf(node)) == .optional) {
        if (node == null) {
            return null;
        }
    }

    if (tag(node) != generated.findTag(T)) {
        return null;
    }
    return castNode(T, node);
}

pub inline fn copy(node: anytype) *pg.c.Node {
    const raw = pg.c.copyObjectImpl(node);
    return @ptrCast(@alignCast(raw));
}

pub inline fn copyTypedNode(node: anytype) @TypeOf(node) {
    return @ptrCast(@alignCast(copy(node)));
}

pub inline fn asNodePtr(node: anytype) *pg.c.Node {
    checkIsPotentialNodePtr(node);
    return @ptrCast(@alignCast(node));
}

inline fn checkIsPotentialNodePtr(node: anytype) void {
    const tn = @TypeOf(node);
    if (!meta.isPointer(tn) and !meta.isCPointer(tn)) {
        @compileError("Expected single node pointer");
    }
}

pub const TestSuite_Node = struct {
    pub fn testMakeAndTag() !void {
        const node = make(pg.c.FdwRoutine);
        try std.testing.expectEqual(tag(node), .FdwRoutine);
    }

    pub fn testCreate() !void {
        const node = create(pg.c.Query{
            .commandType = pg.c.CMD_SELECT,
        });
        try std.testing.expectEqual(tag(node), .Query);
        try std.testing.expectEqual(node.*.commandType, pg.c.CMD_SELECT);
    }

    pub fn testSetTag() !void {
        const node = make(pg.c.Query);
        setTag(node, .FdwRoutine);
        try std.testing.expectEqual(tag(node), .FdwRoutine);
    }

    pub fn testIsA_Ok() !void {
        const node = make(pg.c.Query);
        try std.testing.expect(isA(node, .Query));
    }

    pub fn testIsA_Fail() !void {
        const node = make(pg.c.Query);
        try std.testing.expect(!isA(node, .FdwRoutine));
    }

    pub fn testCastNode() !void {
        const node: *pg.c.Node = @ptrCast(@alignCast(make(pg.c.Query)));
        const query: *pg.c.Query = castNode(pg.c.Query, node);
        try std.testing.expect(isA(query, .Query));
    }

    pub fn testSafeCast_Ok() !void {
        const node = make(pg.c.Query);
        const query = safeCastNode(pg.c.Query, node) orelse {
            return error.UnexpectedCastFailure;
        };
        try std.testing.expect(isA(query, .Query));
    }

    pub fn testSafeCast_Fail() !void {
        const node = make(pg.c.Query);
        const fdw = safeCastNode(pg.c.FdwRoutine, node);
        try std.testing.expect(fdw == null);
    }
};

const std = @import("std");

const pg = @import("pgzx_pgsys");

const err = @import("err.zig");
const mem = @import("mem.zig");
const meta = @import("meta.zig");
const varatt = @import("varatt.zig");

pub fn fromNullableDatum(comptime T: type, d: pg.c.NullableDatum) !T {
    return findConv(T).fromNullableDatum(d);
}

pub fn fromNullableDatumWithOID(comptime T: type, d: pg.c.NullableDatum, oid: ?pg.c.Oid) !T {
    return findConv(T).fromNullableDatumWithOID(d, oid);
}

pub fn fromDatum(comptime T: type, d: pg.c.Datum, is_null: bool) !T {
    return findConv(T).fromNullableDatum(.{ .value = d, .isnull = is_null });
}

pub fn fromDatumWithOID(comptime T: type, d: pg.c.Datum, is_null: bool, oid: ?pg.c.Oid) !T {
    return findConv(T).fromNullableDatumWithOID(.{ .value = d, .isnull = is_null }, oid);
}

pub fn toNullableDatum(v: anytype) !pg.c.NullableDatum {
    return findConv(@TypeOf(v)).toNullableDatum(v);
}

pub fn toNullableDatumWithOID(v: anytype, oid: ?pg.c.Oid) !pg.c.NullableDatum {
    return findConv(@TypeOf(v)).toNullableDatumWithOID(v, oid);
}

// pub fn Conv(comptime T: type, comptime from: anytype, comptime to: anytype) type {
pub fn Conv(comptime context: type) type {
    return struct {
        pub const Type = context.Type;

        const Self = @This();

        pub fn fromNullableDatum(d: pg.c.NullableDatum) !Type {
            return Self.fromNullableDatumWithOID(d, null);
        }

        pub fn fromNullableDatumWithOID(d: pg.c.NullableDatum, oid: ?pg.c.Oid) !Type {
            if (d.isnull) {
                return err.PGError.UnexpectedNullValue;
            }
            return try context.from(d.value, normalizeOid(oid));
        }

        pub fn toNullableDatum(v: Type) !pg.c.NullableDatum {
            return Self.toNullableDatumWithOID(v, null);
        }

        pub fn toNullableDatumWithOID(v: Type, oid: ?pg.c.Oid) !pg.c.NullableDatum {
            return .{
                .value = try context.to(v, normalizeOid(oid)),
                .isnull = false,
            };
        }
    };
}

pub fn ConvNoFail(comptime context: type) type {
    return Conv(struct {
        pub const Type = context.Type;

        pub fn from(d: pg.c.Datum, oid: pg.c.Oid) !Type {
            return context.from(d, oid);
        }

        pub fn to(v: Type, oid: pg.c.Oid) !pg.c.Datum {
            return context.to(v, oid);
        }
    });
}

pub fn SimpleConv(comptime T: type, comptime from_datum: anytype, comptime to_datum: anytype) type {
    return ConvNoFail(struct {
        pub const Type = T;

        pub fn from(d: pg.c.Datum, oid: pg.c.Oid) !Type {
            _ = oid;
            return from_datum(d);
        }

        pub fn to(v: Type, oid: pg.c.Oid) !pg.c.Datum {
            _ = oid;
            return to_datum(v);
        }
    });
}

/// Conversion decorator for optional types.
pub fn OptConv(comptime C: anytype) type {
    return struct {
        pub const Type = ?C.Type;

        const Self = @This();

        pub fn fromNullableDatum(d: pg.c.NullableDatum) !Type {
            return try Self.fromNullableDatumWithOID(d, null);
        }

        pub fn fromNullableDatumWithOID(d: pg.c.NullableDatum, oid: ?pg.c.Oid) !Type {
            if (d.isnull) {
                return null;
            }
            return try C.fromNullableDatumWithOID(d, oid);
        }

        pub fn toNullableDatum(v: Type) !pg.c.NullableDatum {
            return Self.toNullableDatumWithOID(v, null);
        }

        pub fn toNullableDatumWithOID(v: Type, oid: ?pg.c.Oid) !pg.c.NullableDatum {
            if (v) |value| {
                return try C.toNullableDatumWithOID(value, oid);
            } else {
                return .{
                    .value = 0,
                    .isnull = true,
                };
            }
        }
    };
}

/// Map concrete type to their converters.
/// This allows us find to return pre-defined converters besides relying on
/// reflection only.
var directMappings = .{
    .{ pg.c.Datum, PGDatum },
};

pub fn findConv(comptime T: type) type {
    if (isConv(T)) { // is T already a converter?
        return T;
    }
    comptime for (directMappings) |e| {
        if (e[0] == T) {
            return e[1];
        }
    };

    // TODO:
    // allow types to implement conversion functions directly
    // in that case we will return the original type by wrapping it in
    // Conv

    return switch (@typeInfo(T)) {
        .void => Void,
        .bool => Bool,
        .int => |i| switch (i.signedness) {
            .signed => switch (i.bits) {
                8 => Int8,
                16 => Int16,
                32 => Int32,
                64 => Int64,
                else => @compileError("unsupported int type"),
            },
            .unsigned => switch (i.bits) {
                8 => UInt8,
                16 => UInt16,
                32 => UInt32,
                64 => UInt64,
                else => @compileError("unsupported unsigned int type"),
            },
        },
        .float => |f| switch (f.bits) {
            32 => Float32,
            64 => Float64,
            else => @compileError("unsupported float type"),
        },
        .optional => |opt| OptConv(findConv(opt.child)),
        .array => @compileLog("fixed size arrays not supported"),
        .pointer => blk: {
            if (!meta.isStringLike(T)) {
                @compileLog("type:", T);
                @compileError("unsupported ptr type");
            }
            break :blk if (meta.hasSentinal(T)) SliceU8Z else SliceU8;
        },
        else => {
            @compileLog("type:", T);
            @compileError("type not supported");
        },
    };
}

inline fn isConv(comptime T: type) bool {
    // we require T to be a struct with the following fields:
    // Type: type
    // fromDatum: fn(d: pg.c.Datum) !Type
    // toDatum: fn(v: Type) !pg.c.Datum

    if (@typeInfo(T) != .@"struct") {
        return false;
    }

    // TODO: improve checks
    return @hasDecl(T, "Type") and @hasDecl(T, "fromNullableDatum") and @hasDecl(T, "toNullableDatum");
}

inline fn normalizeOid(oid: ?pg.c.Oid) pg.c.Oid {
    return oid orelse pg.c.InvalidOid;
}

pub const Void = SimpleConv(void, idDatum, toVoid);
pub const Bool = SimpleConv(bool, pg.c.DatumGetBool, pg.c.BoolGetDatum);
pub const Int8 = SimpleConv(i8, datumGetInt8, pg.c.Int8GetDatum);
pub const Int16 = SimpleConv(i16, pg.c.DatumGetInt16, pg.c.Int16GetDatum);
pub const Int32 = SimpleConv(i32, pg.c.DatumGetInt32, pg.c.Int32GetDatum);
pub const Int64 = SimpleConv(i64, pg.c.DatumGetInt64, pg.c.Int64GetDatum);
pub const UInt8 = SimpleConv(u8, pg.c.DatumGetUInt8, pg.c.UInt8GetDatum);
pub const UInt16 = SimpleConv(u16, pg.c.DatumGetUInt16, pg.c.UInt16GetDatum);
pub const UInt32 = SimpleConv(u32, pg.c.DatumGetUInt32, pg.c.UInt32GetDatum);
pub const UInt64 = SimpleConv(u64, pg.c.DatumGetUInt64, pg.c.UInt64GetDatum);
pub const Float32 = SimpleConv(f32, pg.c.DatumGetFloat4, pg.c.Float4GetDatum);
pub const Float64 = SimpleConv(f64, pg.c.DatumGetFloat8, pg.c.Float8GetDatum);
pub const PGDatum = SimpleConv(pg.c.Datum, idDatum, idDatum);

pub const SliceU8Z = Conv(struct {
    pub const Type = [:0]const u8;
    pub const from = getDatumStringLikeZ;
    pub const to = sliceToDatumStringLikeZ;
});

pub const SliceU8 = Conv(struct {
    pub const Type = []const u8;
    pub const from = getDatumStringLikeZ;
    pub const to = sliceToDatumStringLike;
});

// TODO: conversion decorator for array types

// TODO: conversion decorator for jsonb decoding/encoding types

fn idDatum(d: pg.c.Datum) pg.c.Datum {
    return d;
}

fn toVoid(d: void) pg.c.Datum {
    _ = d;
    return 0;
}

fn datumGetInt8(d: pg.c.Datum) i8 {
    return @as(i8, @bitCast(@as(i8, @truncate(d))));
}

pub fn getDatumStringLike(datum: pg.c.Datum, oid: pg.c.Oid) ![]const u8 {
    return getDatumStringLikeZ(datum, oid);
}

/// Convert a datum to a TEXT slice. This function detoast the datum if necessary.
/// All allocations will be performed in the Current Memory Context.
pub fn getDatumTextSlice(datum: pg.c.Datum, oid: pg.c.Oid) ![]const u8 {
    return getDatumTextSliceZ(datum, oid);
}

pub inline fn getDatumCString(datum: pg.c.Datum) ![]const u8 {
    return getDatumCStringZ(datum);
}

pub fn getDatumStringLikeZ(datum: pg.c.Datum, oid: pg.c.Oid) ![:0]const u8 {
    return if (useStringPointer(oid)) getDatumCStringZ(datum) else getDatumTextSliceZ(datum);
}

pub inline fn getDatumCStringZ(datum: pg.c.Datum) ![:0]const u8 {
    return std.mem.span(pg.c.DatumGetCString(datum));
}

/// Convert a datum to a TEXT slice. This function detoast the datum if necessary.
/// All allocations will be performed in the Current Memory Context.
///
pub fn getDatumTextSliceZ(datum: pg.c.Datum) ![:0]const u8 {
    const ptr = pg.c.DatumGetTextPP(datum);

    const unpacked = try err.wrap(pg.c.pg_detoast_datum_packed, .{ptr});
    const len = varatt.VARSIZE_ANY_EXHDR(unpacked);
    var buffer = try mem.PGCurrentContextAllocator.alloc(u8, len + 1);
    std.mem.copyForwards(u8, buffer, varatt.VARDATA_ANY(unpacked)[0..len]);
    buffer[len] = 0;
    if (unpacked != ptr) {
        pg.c.pfree(unpacked);
    }
    return buffer[0..len :0];
}

pub fn sliceToDatumStringLikeZ(slice: [:0]const u8, oid: pg.c.Oid) !pg.c.Datum {
    return if (useStringPointer(oid)) sliceToDatumCStringZ(slice) else sliceToDatumTextZ(slice);
}

pub fn sliceToDatumStringLike(slice: []const u8, oid: pg.c.Oid) !pg.c.Datum {
    return if (useStringPointer(oid)) sliceToDatumCString(slice) else sliceToDatumText(slice);
}

pub inline fn sliceToDatumCString(slice: []const u8) !pg.c.Datum {
    const alloc = mem.PGCurrentContextAllocator;
    const slice_z = try alloc.dupeZ(u8, slice);
    return pg.c.CStringGetDatum(slice_z.ptr);
}

pub inline fn sliceToDatumCStringZ(slice: [:0]const u8) !pg.c.Datum {
    return pg.c.CStringGetDatum(slice.ptr);
}

pub inline fn sliceToDatumText(slice: []const u8) !pg.c.Datum {
    const text = pg.c.cstring_to_text_with_len(slice.ptr, @intCast(slice.len));
    return pg.c.PointerGetDatum(text);
}

pub inline fn sliceToDatumTextZ(slice: [:0]const u8) !pg.c.Datum {
    return sliceToDatumText(slice);
}

pub inline fn useStringPointer(oid: pg.c.Oid) bool {
    return switch (oid) {
        pg.c.CHAROID, pg.c.NAMEOID, pg.c.CSTRINGOID => true,
        else => false,
    };
}

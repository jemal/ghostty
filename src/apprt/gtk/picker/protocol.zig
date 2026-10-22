//! Versioned, transport-independent native picker contract.
const std = @import("std");
pub const max_bytes = 1024 * 1024;
pub const max_choices = 1024;
pub const path = "/com/mitchellh/ghostty/Picker1";
pub const interface = "com.mitchellh.ghostty.Picker1";

pub const Choice = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8 = "",
};
pub const Request = struct {
    version: u32,
    request_id: []const u8,
    kind: []const u8 = "select",
    selection: []const u8 = "single",
    surface_id: ?[]const u8 = null,
    instance: ?[]const u8 = null,
    title: []const u8 = "Choose an item",
    placeholder: []const u8 = "Search…",
    choices: []const Choice,
    timeout_ms: u32 = 0,
    placement: enum { center, cursor } = .center,

    pub fn validate(self: Request, alloc: std.mem.Allocator) !void {
        if (self.version != 1) return error.UnsupportedVersion;
        if (!std.mem.eql(u8, self.kind, "select") or !std.mem.eql(u8, self.selection, "single"))
            return error.UnsupportedKind;
        if (!validText(self.request_id, 128) or self.request_id.len == 0 or
            !validText(self.title, 1024) or !validText(self.placeholder, 1024)) return error.InvalidText;
        if (self.choices.len == 0 or self.choices.len > max_choices) return error.InvalidChoiceCount;
        if (self.timeout_ms > 24 * 60 * 60 * 1000) return error.InvalidTimeout;
        var ids: std.StringHashMap(void) = .init(alloc);
        defer ids.deinit();
        for (self.choices) |choice| {
            if (!validText(choice.id, 256) or choice.id.len == 0 or
                !validText(choice.label, 1024) or choice.label.len == 0 or
                !validText(choice.description, 4096)) return error.InvalidText;
            const entry = try ids.getOrPut(choice.id);
            if (entry.found_existing) return error.DuplicateChoiceId;
        }
    }

    pub fn surfaceId(self: Request) !u64 {
        const value = self.surface_id orelse return error.SurfaceRequired;
        const id = std.fmt.parseUnsigned(u64, value, 0) catch return error.InvalidSurface;
        if (id == 0) return error.InvalidSurface;
        return id;
    }
};

fn validText(value: []const u8, limit: usize) bool {
    if (value.len > limit or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Request) {
    if (bytes.len > max_bytes) return error.RequestTooLarge;
    var parsed = try std.json.parseFromSlice(Request, alloc, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate(alloc);
    return parsed;
}

pub const Response = struct {
    version: u32 = 1,
    request_id: ?[]const u8,
    status: enum { selected, cancelled, @"error" },
    result: ?struct { kind: []const u8 = "select", ids: []const []const u8 } = null,
    reason: ?[]const u8 = null,
    @"error": ?struct { code: []const u8, message: []const u8 } = null,
};

pub fn encode(alloc: std.mem.Allocator, value: anytype) ![:0]const u8 {
    // Correlation is always present, including null for unparseable requests.
    const bytes = if (@TypeOf(value) == Response)
        try std.json.Stringify.valueAlloc(alloc, .{
            .version = value.version,
            .request_id = if (value.request_id) |id| std.json.Value{ .string = id } else std.json.Value.null,
            .status = value.status,
            .result = value.result,
            .reason = value.reason,
            .@"error" = value.@"error",
        }, .{ .emit_null_optional_fields = false })
    else
        try std.json.Stringify.valueAlloc(alloc, value, .{ .emit_null_optional_fields = false });
    defer alloc.free(bytes);
    return alloc.dupeSentinel(u8, bytes, 0);
}

pub fn failure(alloc: std.mem.Allocator, id: ?[]const u8, code: []const u8, message: []const u8) ![:0]const u8 {
    return encode(alloc, Response{ .request_id = id, .status = .@"error", .@"error" = .{ .code = code, .message = message } });
}

test "picker protocol preserves IDs and rejects ambiguous input" {
    const a = std.testing.allocator;
    var request = try parse(a,
        \\{"version":1,"request_id":"r","surface_id":"0xffffffffffffffff","choices":[{"id":"α","label":"Same"},{"id":"β","label":"Same"}]}
    );
    defer request.deinit();
    try std.testing.expectEqual(std.math.maxInt(u64), try request.value.surfaceId());
    try std.testing.expectEqualStrings("β", request.value.choices[1].id);
    try std.testing.expectError(error.DuplicateChoiceId, parse(a,
        \\{"version":1,"request_id":"r","choices":[{"id":"a","label":"A"},{"id":"a","label":"B"}]}
    ));
    try std.testing.expectError(error.DuplicateField, parse(a,
        \\{"version":1,"version":1,"request_id":"r","choices":[]}
    ));
    try std.testing.expectError(error.InvalidChoiceCount, parse(a,
        \\{"version":1,"request_id":"r","choices":[]}
    ));
    try std.testing.expectError(error.InvalidText, parse(a,
        \\{"version":1,"request_id":"r","choices":[{"id":"a","label":"bad\u0000text"}]}
    ));
}

test "picker protocol response contains opaque ID and correlation" {
    const a = std.testing.allocator;
    const result = try encode(a, Response{ .request_id = "r", .status = .selected, .result = .{ .ids = &.{"x\"y"} } });
    defer a.free(result);
    var decoded = try std.json.parseFromSlice(Response, a, result, .{});
    defer decoded.deinit();
    try std.testing.expectEqualStrings("x\"y", decoded.value.result.?.ids[0]);
    try std.testing.expectEqualStrings("r", decoded.value.request_id.?);
}

test "picker protocol enforces size mode and timeout bounds" {
    const a = std.testing.allocator;
    const oversized = try a.alloc(u8, max_bytes + 1);
    defer a.free(oversized);
    try std.testing.expectError(error.RequestTooLarge, parse(a, oversized));
    var request: Request = .{ .version = 2, .request_id = "r", .choices = &.{.{ .id = "a", .label = "A" }} };
    try std.testing.expectError(error.UnsupportedVersion, request.validate(a));
    request.version = 1;
    request.selection = "multiple";
    try std.testing.expectError(error.UnsupportedKind, request.validate(a));
    request.selection = "single";
    request.timeout_ms = std.math.maxInt(u32);
    try std.testing.expectError(error.InvalidTimeout, request.validate(a));
    request.timeout_ms = 0;
    request.surface_id = "0";
    try std.testing.expectError(error.InvalidSurface, request.surfaceId());
}

fn allocationFailureCase(a: std.mem.Allocator) !void {
    var parsed = try parse(a,
        \\{"version":1,"request_id":"r","choices":[{"id":"a","label":"A"},{"id":"b","label":"B"}]}
    );
    defer parsed.deinit();
}

test "picker protocol releases partial allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureCase, .{});
}

/// Recover only an unambiguous, bounded correlation ID from a rejected request.
pub fn recoverRequestId(alloc: std.mem.Allocator, bytes: []const u8) !?[]const u8 {
    if (bytes.len > max_bytes) return null;
    const envelope = try std.json.parseFromSlice(struct { request_id: ?[]const u8 = null }, alloc, bytes, .{ .ignore_unknown_fields = true });
    defer envelope.deinit();
    const id = envelope.value.request_id orelse return null;
    if (id.len == 0 or !validText(id, 128)) return null;
    return try alloc.dupe(u8, id);
}

test "picker errors retain correlation including unknown request ID" {
    const a = std.testing.allocator;
    const id = try recoverRequestId(a,
        \\{"version":99,"request_id":"correlation","choices":[]}
    );
    defer if (id) |v| a.free(v);
    try std.testing.expectEqualStrings("correlation", id.?);
    const json = try failure(a, null, "invalid_request", "Invalid JSON");
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"request_id\":null") != null);
}

test "picker protocol validates cursor placement and keeps centered default" {
    const a = std.testing.allocator;
    var centered = try parse(a,
        \\{"version":1,"request_id":"r","choices":[{"id":"a","label":"A"}]}
    );
    defer centered.deinit();
    try std.testing.expectEqual(.center, centered.value.placement);
    var anchored = try parse(a,
        \\{"version":1,"request_id":"r","placement":"cursor","choices":[{"id":"a","label":"A"}]}
    );
    defer anchored.deinit();
    try std.testing.expectEqual(.cursor, anchored.value.placement);
    try std.testing.expectError(error.InvalidEnumTag, parse(a,
        \\{"version":1,"request_id":"r","placement":"mouse","choices":[{"id":"a","label":"A"}]}
    ));
}

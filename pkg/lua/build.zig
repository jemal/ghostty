const std = @import("std");
const translate_c = @import("translate_c");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("lua", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib: union(enum) {
        system,
        static: *std.Build.Step.Compile,
    } = if (b.systemIntegrationOption("lua", .{}))
        .system
    else
        .{ .static = buildLib(b, target, optimize) orelse return };

    try translate_c.addImportToModule(b, "lua_c", module, .{
        .source = .{ .includes = .{
            .files = &.{
                .{ .path = "lua.h" },
                .{ .path = "lauxlib.h" },
                .{ .path = "lualib.h" },
            },
        } },
        .target = target,
        .optimize = optimize,
        .link_system_libs = if (lib == .system) &.{"lua"} else &.{},
        .link_libs = if (lib == .static) &.{lib.static} else &.{},
    });
}

fn buildLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*std.Build.Step.Compile {
    const upstream = b.lazyDependency("lua", .{}) orelse return null;

    const lib = b.addLibrary(.{
        .name = "lua",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .static,
    });
    lib.root_module.addIncludePath(upstream.path("src"));
    lib.installHeadersDirectory(
        upstream.path("src"),
        "",
        .{ .include_extensions = &.{ ".h", ".hpp" } },
    );

    // LUA_USE_POSIX enables mkstemp, popen and similar POSIX functions.
    // Dynamic C modules are not needed, so LUA_USE_DLOPEN is not set.
    const flags: []const []const u8 = switch (target.result.os.tag) {
        .windows => &.{"-std=gnu99"},
        else => &.{ "-std=gnu99", "-DLUA_USE_POSIX" },
    };
    lib.root_module.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = srcs,
        .flags = flags,
    });

    b.installArtifact(lib);
    return lib;
}

const srcs: []const []const u8 = &.{
    // Core
    "lapi.c",
    "lcode.c",
    "lctype.c",
    "ldebug.c",
    "ldo.c",
    "ldump.c",
    "lfunc.c",
    "lgc.c",
    "llex.c",
    "lmem.c",
    "lobject.c",
    "lopcodes.c",
    "lparser.c",
    "lstate.c",
    "lstring.c",
    "ltable.c",
    "ltm.c",
    "lundump.c",
    "lvm.c",
    "lzio.c",

    // Standard libraries
    "lauxlib.c",
    "lbaselib.c",
    "lcorolib.c",
    "ldblib.c",
    "liolib.c",
    "lmathlib.c",
    "loadlib.c",
    "loslib.c",
    "lstrlib.c",
    "ltablib.c",
    "lutf8lib.c",
    "linit.c",
};

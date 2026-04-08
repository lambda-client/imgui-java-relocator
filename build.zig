const std = @import("std");

/// Cross-platform native build for relocated imgui-java JNI libraries.
///
/// Replaces the Ant-based build that gdx-jnigen generates. Compiles all C/C++
/// sources in the JNI directory into a shared library for the target platform.
/// Zig's bundled cross-compilation sysroots let you build for all platforms
/// from a single Linux machine.
///
/// Prerequisites:
///   1. Run scripts/relocate.sh (clones upstream, renames, generates JNI C++)
///   2. The JNI dir at work/imgui-java/imgui-binding/build/jni must exist
///      with a sources.txt manifest (relocate.sh creates this)
///
/// Usage:
///   zig build                                          # host platform, debug
///   zig build --release=fast                           # host platform, optimized
///   zig build -Dtarget=x86_64-windows-gnu --release=fast  # cross-compile to Windows
///   zig build -Dtarget=aarch64-macos --release=fast       # cross-compile to macOS ARM
///
pub fn build(b: *std.Build) void {
    const lib_name = b.option(
        []const u8,
        "lib-name",
        "Native library base name (default: delta-imgui-java64)",
    ) orelse "delta-imgui-java64";

    const jni_dir = b.option(
        []const u8,
        "jni-dir",
        "Path to JNI source directory (default: work/imgui-java/imgui-binding/build/jni)",
    ) orelse "work/imgui-java/imgui-binding/build/jni";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const resolved = target.result;

    // ── Read source manifest ────────────────────────────────────────────

    const sources_path = b.fmt("{s}/sources.txt", .{jni_dir});
    const sources_content = std.fs.cwd().readFileAlloc(
        b.allocator,
        sources_path,
        10 * 1024 * 1024,
    ) catch |err| {
        std.log.err(
            "Could not read {s}: {s}\n\n" ++
                "Run scripts/relocate.sh first to generate the JNI sources.\n",
            .{ sources_path, @errorName(err) },
        );
        return;
    };

    var cpp_files: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, sources_content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        cpp_files.append(b.allocator, b.allocator.dupe(u8, trimmed) catch @panic("OOM")) catch @panic("OOM");
    }

    if (cpp_files.items.len == 0) {
        std.log.err("sources.txt is empty — no C++ files to compile", .{});
        return;
    }

    // ── Platform-specific settings ──────────────────────────────────────

    const jni_platform: []const u8 = switch (resolved.os.tag) {
        .linux => "linux",
        .windows => "win32",
        .macos => "mac",
        else => "linux",
    };

    // ── Configure shared library ────────────────────────────────────────

    const jni_path = b.path(jni_dir);

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    mod.addIncludePath(jni_path);
    mod.addIncludePath(b.path(b.fmt("{s}/dirent", .{jni_dir})));

    // JNI headers: use bundled jni-headers/ (contains jni.h + universal jni_md.h).
    // relocate.sh creates this directory with headers that work for all targets.
    // Falls back to JAVA_HOME or system paths for local-only builds.
    const jni_headers_dir = b.fmt("{s}/jni-headers", .{jni_dir});
    if (dirExists(jni_headers_dir)) {
        mod.addIncludePath(b.path(jni_headers_dir));
    } else if (std.process.getEnvVarOwned(b.allocator, "JAVA_HOME") catch null) |java_home| {
        mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{java_home}) });
        mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include/{s}", .{ java_home, jni_platform }) });
    } else {
        // Auto-detect from common system paths
        const java_paths = [_][]const u8{
            "/usr/lib/jvm/default/include",
            "/usr/lib/jvm/java-21-openjdk/include",
            "/usr/lib/jvm/java-17-openjdk/include",
        };
        for (java_paths) |path| {
            if (dirExists(path)) {
                mod.addIncludePath(.{ .cwd_relative = path });
                mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/{s}", .{ path, jni_platform }) });
                break;
            }
        }
    }

    // ── Add C++ sources ─────────────────────────────────────────────────

    const base_cpp_flags = [_][]const u8{
        "-O2",
        "-fPIC",
        "-std=c++14",
        "-fmessage-length=0",
        // Suppress warnings from upstream imgui code we don't control
        "-Wno-unused-parameter",
        "-Wno-missing-field-initializers",
        "-Wno-sign-compare",
        "-Wno-deprecated-enum-enum-conversion",
    };

    // On Linux, force-include the glibc compat header into every TU to
    // pin memcpy to GLIBC_2.2.5 (avoids GLIBC_2.14 dependency).
    const glibc_compat_path = b.fmt("{s}/src/glibc_compat.h", .{b.build_root.path orelse "."});
    const glibc_compat_flag = [_][]const u8{ "-include", glibc_compat_path };
    const cpp_flags: []const []const u8 = if (resolved.os.tag == .linux)
        &(glibc_compat_flag ++ base_cpp_flags)
    else
        &base_cpp_flags;

    mod.addCSourceFiles(.{
        .root = jni_path,
        .files = cpp_files.items,
        .flags = cpp_flags,
        .language = null,
    });

    // On Linux, also compile glibc_compat.c to ensure the .symver
    // directive emits a versioned memcpy reference in the final .so.
    if (resolved.os.tag == .linux) {
        mod.addCSourceFiles(.{
            .root = b.path("src"),
            .files = &.{"glibc_compat.c"},
            .flags = &.{"-O2"},
        });
    }

    // ── Platform-specific ───────────────────────────────────────────────

    switch (resolved.os.tag) {
        .windows => {
            mod.linkSystemLibrary("gdi32", .{});
        },
        else => {},
    }

    const lib = b.addLibrary(.{
        .name = lib_name,
        .root_module = mod,
        .linkage = .dynamic,
    });

    // ── Install artifact ────────────────────────────────────────────────

    b.installArtifact(lib);

    // ── "copy-to-bin" step: install into work/imgui-java/bin/ ───────────

    const copy_step = b.step("copy-to-bin", "Copy built library to work/imgui-java/bin/");

    const lib_artifact = lib.getEmittedBin();
    const install_to_bin = b.addInstallFileWithDir(
        lib_artifact,
        .{ .custom = "../work/imgui-java/bin" },
        lib.out_filename,
    );
    copy_step.dependOn(&install_to_bin.step);
}

fn dirExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
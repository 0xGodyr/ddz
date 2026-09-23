//! @file build.zig
//! @brief Zig build configuration for DDZ libraries, CLI utilities, examples, and test suites.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("ddz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });

    const examples = [_][]const u8{
        "persistent_durability",
        "comprehensive",
        "group_access",
        "hello_world",
        "security",
        "qos_durability",
        "qos_deadline",
        "content_filtered_topics",
        "partition_qos",
        "rpc",
        "ownership",
        "multi_topic",
        "lifecycle",
        "dynamic_data",
        "manual_liveliness",
        "builtin_topics",
        "time_based_filter",
        "waitset_status_condition",
        "idl_interop",
    };

    for (examples) |example_name| {
        const root_path = b.fmt("examples/{s}/main.zig", .{example_name});
        const exe = b.addExecutable(.{
            .name = example_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(root_path),
                .target = target,
                .link_libc = true,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "ddz", .module = mod },
                },
            }),
        });

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addPassthruArgs();

        const run_step_name = b.fmt("run-{s}", .{example_name});
        const run_step_desc = b.fmt("Run the {s} example", .{example_name});
        const run_step = b.step(run_step_name, run_step_desc);
        run_step.dependOn(&run_cmd.step);

        if (std.mem.eql(u8, example_name, "comprehensive")) {
            const default_run_step = b.step("run", "Run the comprehensive integration test");
            default_run_step.dependOn(&run_cmd.step);
        }
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const ddz_ping_exe = b.addExecutable(.{
        .name = "ddz_ping",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/ddz_ping/main.zig"),
            .target = target,
            .link_libc = true,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ddz", .module = mod },
            },
        }),
    });
    b.installArtifact(ddz_ping_exe);

    const run_ping_cmd = b.addRunArtifact(ddz_ping_exe);
    run_ping_cmd.step.dependOn(b.getInstallStep());
    run_ping_cmd.addPassthruArgs();
    const run_ping_step = b.step("run-ddz_ping", "Run the ddz_ping tool");
    run_ping_step.dependOn(&run_ping_cmd.step);

    const ddz_spy_exe = b.addExecutable(.{
        .name = "ddz_spy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/ddz_spy/main.zig"),
            .target = target,
            .link_libc = true,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ddz", .module = mod },
            },
        }),
    });
    b.installArtifact(ddz_spy_exe);

    const run_spy_cmd = b.addRunArtifact(ddz_spy_exe);
    run_spy_cmd.step.dependOn(b.getInstallStep());
    run_spy_cmd.addPassthruArgs();
    const run_spy_step = b.step("run-ddz_spy", "Run the ddz_spy tool");
    run_spy_step.dependOn(&run_spy_cmd.step);

    const ddz_gen_exe = b.addExecutable(.{
        .name = "ddz_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/ddz_gen/main.zig"),
            .target = target,
            .link_libc = true,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ddz", .module = mod },
            },
        }),
    });
    b.installArtifact(ddz_gen_exe);

    const run_gen_cmd = b.addRunArtifact(ddz_gen_exe);
    run_gen_cmd.step.dependOn(b.getInstallStep());
    run_gen_cmd.addPassthruArgs();
    const run_gen_step = b.step("run-ddz_gen", "Run the ddz_gen tool");
    run_gen_step.dependOn(&run_gen_cmd.step);

    const ddz_gen_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/ddz_gen/test_all.zig"),
            .target = target,
            .link_libc = true,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ddz", .module = mod },
            },
        }),
    });
    const run_gen_tests = b.addRunArtifact(ddz_gen_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_gen_tests.step);
}

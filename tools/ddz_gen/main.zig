//! @file main.zig
//! @brief CLI driver for ddz_gen: OMG IDL, ROS2 msg/srv, and XMI code generator.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const Ast = @import("ast/ast.zig");
const Diagnostics = @import("diagnostics.zig");
const Options = @import("options.zig").Options;
const Preprocessor = @import("preprocessor/preprocessor.zig").Preprocessor;
const Parser = @import("parser/parser.zig").Parser;
const SymbolTable = @import("sema/symbol_table.zig").SymbolTable;
const TypeValidator = @import("sema/type_validator.zig").TypeValidator;
const ZigEmitter = @import("codegen/zig_emitter.zig").ZigEmitter;
const RpcEmitter = @import("codegen/rpc_emitter.zig").RpcEmitter;
const ReverseEmitter = @import("codegen/reverse_emitter.zig").ReverseEmitter;
const UmlEmitter = @import("codegen/uml_emitter.zig").UmlEmitter;
const MsgParser = @import("ros2/msg_parser.zig").MsgParser;
const ddz = @import("ddz");
const XmiParser = ddz.xml.XmiParser;

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var diag = Diagnostics.DiagnosticEngine.init(allocator);
    defer diag.deinit();

    var opts = Options{};
    defer opts.deinit(allocator);

    var args = try init.args.iterateAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // skip binary name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("ddz_gen version 0.1.0 (OMG IDL 4.2 & ROS 2 Compiler for DDZ)\n", .{});
            return;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--output-dir")) {
            if (args.next()) |dir| {
                opts.output_dir = dir;
            } else {
                std.debug.print("Error: -d requires a directory argument\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "-I") or std.mem.eql(u8, arg, "--include")) {
            if (args.next()) |inc| {
                try opts.include_dirs.append(allocator, inc);
            } else {
                std.debug.print("Error: -I requires a directory argument\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--package")) {
            if (args.next()) |pkg| {
                opts.package_name = pkg;
            }
        } else if (std.mem.eql(u8, arg, "--rpc")) {
            opts.generate_rpc = true;
        } else if (std.mem.eql(u8, arg, "--ros2")) {
            opts.ros2_mode = true;
        } else if (std.mem.eql(u8, arg, "--xmi") or std.mem.eql(u8, arg, "--uml")) {
            opts.xmi_mode = true;
        } else if (std.mem.eql(u8, arg, "--gen-idl")) {
            opts.generate_idl = true;
        } else if (std.mem.eql(u8, arg, "--reverse")) {
            opts.reverse_mode = true;
        } else if (std.mem.eql(u8, arg, "--replace")) {
            opts.replace_existing = true;
        } else if (std.mem.eql(u8, arg, "--no-fmt")) {
            opts.no_fmt = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printHelp();
            std.process.exit(1);
        } else {
            try opts.input_files.append(allocator, arg);
        }
    }

    if (opts.input_files.items.len == 0) {
        std.debug.print("Error: No input files specified.\n\n", .{});
        printHelp();
        std.process.exit(1);
    }

    // Ensure output dir exists
    const io = std.Options.debug_io;
    if (!std.mem.eql(u8, opts.output_dir, ".")) {
        std.Io.Dir.cwd().createDirPath(io, opts.output_dir) catch {};
    }

    for (opts.input_files.items) |input_file| {
        if (opts.verbose) {
            std.debug.print("[ddz_gen] Processing: {s}\n", .{input_file});
        }

        if (opts.reverse_mode) {
            try processReverse(allocator, input_file, opts, &diag);
        } else if (opts.xmi_mode or std.mem.endsWith(u8, input_file, ".xmi") or std.mem.endsWith(u8, input_file, ".xml")) {
            try processXmi(allocator, input_file, opts, &diag);
        } else if (opts.ros2_mode or std.mem.endsWith(u8, input_file, ".msg") or std.mem.endsWith(u8, input_file, ".srv")) {
            try processRos2(allocator, input_file, opts, &diag);
        } else {
            try processIdl(allocator, input_file, opts, &diag);
        }

        if (diag.hasErrors()) {
            std.debug.print("\nCompilation failed with {d} error(s):\n", .{diag.error_count});
            for (diag.diagnostics.items) |d| {
                std.debug.print("{s}:{d}:{d}: {s} {s}\n", .{
                    d.location.file_path,
                    d.location.line,
                    d.location.column,
                    d.severity.prefix(),
                    d.message,
                });
            }
            std.process.exit(1);
        }
    }

    if (opts.verbose) {
        std.debug.print("[ddz_gen] Finished successfully.\n", .{});
    }
}

fn processIdl(allocator: std.mem.Allocator, input_file: []const u8, opts: Options, diag: *Diagnostics.DiagnosticEngine) anyerror!void {
    var pp = Preprocessor.init(allocator, opts.include_dirs.items, diag);
    defer pp.deinit();

    const preprocessed = try pp.processFile(input_file);
    defer allocator.free(preprocessed);

    var parser = Parser.init(allocator, preprocessed, input_file, diag);
    const ast = try parser.parseRoot();

    var sym_tab = SymbolTable.init(allocator, diag);
    defer sym_tab.deinit();
    try sym_tab.populate(ast);

    var validator = TypeValidator.init(&sym_tab, diag);
    try validator.validate(ast);

    if (diag.hasErrors()) return;

    var emitter = ZigEmitter.init(allocator);
    emitter.emit_rpc = opts.generate_rpc;
    const zig_source = try emitter.emitSource(ast);
    defer allocator.free(zig_source);

    const final_code = zig_source;

    // Determine output file path
    const stem = std.fs.path.stem(input_file);
    const out_file_name = try std.fmt.allocPrint(allocator, "{s}.zig", .{stem});
    const out_path = try std.fs.path.join(allocator, &.{ opts.output_dir, out_file_name });

    const io = std.Options.debug_io;
    var file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);
    _ = try file.writeStreamingAll(io, final_code);

    std.debug.print("Generated: {s}\n", .{out_path});
}

fn processRos2(allocator: std.mem.Allocator, input_file: []const u8, opts: Options, diag: *Diagnostics.DiagnosticEngine) anyerror!void {
    const io = std.Options.debug_io;
    var file = std.Io.Dir.cwd().openFile(io, input_file, .{}) catch |err| {
        std.debug.print("Cannot open ROS 2 file '{s}': {}\n", .{ input_file, err });
        return err;
    };
    defer file.close(io);

    const file_size = try file.length(io);
    const content = try allocator.alloc(u8, file_size);
    defer allocator.free(content);
    _ = try file.readPositionalAll(io, content, 0);

    var parser = MsgParser.init(allocator, diag);
    const stem = std.fs.path.stem(input_file);
    const pkg = opts.package_name orelse "msg";

    var emitter = ZigEmitter.init(allocator);

    if (std.mem.endsWith(u8, input_file, ".srv")) {
        const srv = try parser.parseSrv(content, pkg, stem);
        const ast = Ast.AstRoot{
            .declarations = &.{
                .{ .struct_def = srv.request },
                .{ .struct_def = srv.response },
            },
        };
        const code = try emitter.emitSource(ast);
        defer allocator.free(code);
        try writeOutputFile(opts.output_dir, stem, ".zig", code, allocator);
    } else {
        const s = try parser.parseMsg(content, pkg, stem);
        const ast = Ast.AstRoot{
            .declarations = &.{
                .{ .struct_def = s },
            },
        };
        const code = try emitter.emitSource(ast);
        defer allocator.free(code);
        try writeOutputFile(opts.output_dir, stem, ".zig", code, allocator);
    }
}

fn processReverse(allocator: std.mem.Allocator, input_file: []const u8, opts: Options, diag: *Diagnostics.DiagnosticEngine) anyerror!void {
    _ = diag;
    const io = std.Options.debug_io;
    var file = std.Io.Dir.cwd().openFile(io, input_file, .{}) catch |err| {
        std.debug.print("Cannot open Zig source file '{s}': {}\n", .{ input_file, err });
        return err;
    };
    defer file.close(io);

    const file_size = try file.length(io);
    const content = try allocator.alloc(u8, file_size);
    defer allocator.free(content);
    _ = try file.readPositionalAll(io, content, 0);

    var rev = ReverseEmitter.init(allocator);
    const ast = try rev.parseZigStructs(content);
    const stem = std.fs.path.stem(input_file);
    const mod_name = opts.package_name orelse stem;

    const idl_code = try rev.emitIdl(ast, mod_name);
    defer allocator.free(idl_code);

    try writeOutputFile(opts.output_dir, stem, ".idl", idl_code, allocator);
}

fn processXmi(allocator: std.mem.Allocator, file_path: []const u8, opts: Options, diag: *Diagnostics.DiagnosticEngine) !void {
    _ = diag;
    var model = XmiParser.parseFile(allocator, file_path) catch |err| {
        std.debug.print("Error parsing XMI file '{s}': {s}\n", .{ file_path, @errorName(err) });
        std.process.exit(1);
    };
    defer model.deinit();

    const stem = std.fs.path.stem(file_path);
    var emitter = UmlEmitter.init(allocator);

    // 1. Emit Types
    const types_src = try emitter.emitTypes(model);
    defer allocator.free(types_src);
    const types_stem = try std.fmt.allocPrint(allocator, "{s}Types", .{stem});
    defer allocator.free(types_stem);
    try writeOutputFile(opts.output_dir, types_stem, ".zig", types_src, allocator);

    // 2. Emit Topology Scaffolding
    const types_import = try std.fmt.allocPrint(allocator, "{s}.zig", .{types_stem});
    defer allocator.free(types_import);
    const topo_src = try emitter.emitTopology(model, types_import);
    defer allocator.free(topo_src);
    const topo_stem = try std.fmt.allocPrint(allocator, "{s}Topology", .{stem});
    defer allocator.free(topo_stem);
    try writeOutputFile(opts.output_dir, topo_stem, ".zig", topo_src, allocator);

    // 3. Emit IDL 4.2 if requested
    if (opts.generate_idl) {
        const idl_src = try emitter.emitIdl(model);
        defer allocator.free(idl_src);
        try writeOutputFile(opts.output_dir, stem, ".idl", idl_src, allocator);
    }
}

fn writeOutputFile(output_dir: []const u8, stem: []const u8, ext: []const u8, content: []const u8, allocator: std.mem.Allocator) !void {
    const out_file_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, ext });
    const out_path = try std.fs.path.join(allocator, &.{ output_dir, out_file_name });

    const io = std.Options.debug_io;
    var file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);
    _ = try file.writeStreamingAll(io, content);

    std.debug.print("Generated: {s}\n", .{out_path});
}

fn printHelp() void {
    const help =
        \\Usage: ddz_gen [options] <idl-or-msg-files...>
        \\
        \\Options:
        \\  -d, --output-dir <dir>       Directory for generated source files (default: .)
        \\  -I, --include <dir>          Add directory to search path for #include directives
        \\  -p, --package <name>         Package/module namespace override
        \\  --rpc                        Generate DDS-RPC Client Requesters and Server Repliers
        \\  --ros2                       Parse input files as ROS 2 .msg or .srv definitions
        \\  --xmi, --uml                 Parse input files as OMG DDS-UML XMI models
        \\  --gen-idl                    Emit OMG IDL 4.2 schema definition alongside Zig code
        \\  --reverse                    Reverse mode: inspect Zig structs and emit OMG IDL 4.2
        \\  --replace                    Overwrite existing files
        \\  --no-fmt                     Do not invoke 'zig fmt' on output files
        \\  -v, --verbose                Enable verbose compilation output
        \\  -h, --help                   Display this help message and exit
        \\  --version                    Display ddz_gen version
        \\
        \\Examples:
        \\  ddz_gen -d src/generated/ idl/SensorData.idl
        \\  ddz_gen -d src/generated/ --rpc idl/MotorService.idl
        \\  ddz_gen -d src/generated/ --ros2 msg/Twist.msg
        \\  ddz_gen -d src/generated/ --xmi models/VehicleSystem.xmi
        \\  ddz_gen --reverse src/types/Sensor.zig
        \\
    ;
    std.debug.print("{s}", .{help});
}

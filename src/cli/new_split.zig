const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// Direction to split: right, down, left, up, or auto
    direction: [:0]const u8 = "auto",

    /// If set, open the split in a specific window class
    class: ?[:0]const u8 = null,

    /// If `-e` is found in the arguments, this will contain all of the
    /// arguments to pass to Ghostty as the command.
    _arguments: ?[][:0]const u8 = null,

    /// Enable arg parsing diagnostics
    _diagnostics: diagnostics.DiagnosticList = .{},

    /// Manual parse hook, used to deal with `-e`
    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) Allocator.Error!bool {
        // If it's not `-e` continue with the standard argument parsing.
        if (!std.mem.eql(u8, arg, "-e")) return true;

        var arguments: std.ArrayListUnmanaged([:0]const u8) = .empty;
        errdefer {
            for (arguments.items) |argument| alloc.free(argument);
            arguments.deinit(alloc);
        }

        // Otherwise gather up the rest of the arguments to use as the command.
        while (iter.next()) |param| {
            try arguments.append(alloc, try alloc.dupeZ(u8, param));
        }

        self._arguments = try arguments.toOwnedSlice(alloc);

        return false;
    }

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `new-split` command will use platform IPC to create a new split in a
/// running Ghostty window.
///
/// This allows external programs and scripts to programmatically control
/// Ghostty's split functionality. You can specify the split direction and
/// optionally provide a command to run in the new split.
///
/// Flags:
///
///   * `--direction=<dir>`: Split direction: right, down, left, up, or auto
///     (default: auto)
///
///   * `--class=<class>`: Target a specific Ghostty instance by class
///
///   * `-e`: Any arguments after this will be interpreted as a command to
///     execute inside the new split instead of the default shell
///
/// Examples:
///
///   # Create a split to the right with default shell
///   ghostty +new-split --direction=right
///
///   # Create a split and run vim
///   ghostty +new-split --direction=right -e vim file.txt
///
/// Available since: (future version)
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();
    return try runArgs(alloc, &iter);
}

fn runArgs(alloc_gpa: Allocator, argsIter: anytype) !u8 {
    const stderr = std.io.getStdErr().writer();

    var opts: Options = .{};
    defer opts.deinit();

    args.parse(Options, alloc_gpa, &opts, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };

    // Validate direction
    const valid_directions = [_][]const u8{ "right", "down", "left", "up", "auto" };
    var direction_valid = false;
    for (valid_directions) |dir| {
        if (std.mem.eql(u8, opts.direction, dir)) {
            direction_valid = true;
            break;
        }
    }
    if (!direction_valid) {
        try stderr.print("Invalid direction '{}'. Valid options: right, down, left, up, auto\n", .{opts.direction});
        return 1;
    }

    if (opts._arguments) |arguments| {
        if (arguments.len == 0) {
            try stderr.print("The -e flag was specified but no command arguments were provided.\n", .{});
            return 1;
        }
    }

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (apprt.App.performIpc(
        alloc,
        if (opts.class) |class| .{ .class = class } else .detect,
        .new_split,
        .{
            .direction = opts.direction,
            .arguments = opts._arguments,
        },
    ) catch |err| switch (err) {
        error.IPCFailed => {
            // The apprt should have printed a more specific error message
            return 1;
        },
        else => {
            try stderr.print("Sending the IPC failed: {}\n", .{err});
            return 1;
        },
    }) return 0;

    // If we get here, the platform is not supported.
    try stderr.print("+new-split is not supported on this platform.\n", .{});
    return 1;
}
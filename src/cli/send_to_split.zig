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

    /// Target split: index, id, or "focused" for current split
    target: [:0]const u8 = "focused",

    /// If set, target a specific window class
    class: ?[:0]const u8 = null,

    /// The text to send (collected from remaining args)
    _text: ?[:0]const u8 = null,

    /// Enable arg parsing diagnostics
    _diagnostics: diagnostics.DiagnosticList = .{},

    /// Manual parse hook to collect remaining args as text
    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) Allocator.Error!bool {
        // If we've already parsed options, collect remaining as text
        if (std.mem.startsWith(u8, arg, "--")) return true;
        
        var text_parts = std.ArrayList(u8).init(alloc);
        defer text_parts.deinit();
        
        // Add first arg
        try text_parts.appendSlice(arg);
        
        // Add remaining args with spaces
        while (iter.next()) |param| {
            try text_parts.append(' ');
            try text_parts.appendSlice(param);
        }
        
        self._text = try alloc.dupeZ(u8, text_parts.items);
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

/// The `send-to-split` command sends text or keystrokes to a specific split
/// in a running Ghostty window.
///
/// This allows external programs to programmatically send input to specific
/// splits, enabling advanced automation and integration scenarios.
///
/// Flags:
///
///   * `--target=<target>`: Target split - can be:
///     - "focused" (default): Send to the currently focused split
///     - A number: Send to split by index (e.g., "1", "2", etc.)
///     - An ID: Send to split by unique ID
///
///   * `--class=<class>`: Target a specific Ghostty instance by class
///
/// Arguments:
///
///   The text to send follows the options. All remaining arguments are
///   joined with spaces and sent as text to the target split.
///
/// Examples:
///
///   # Send text to the focused split
///   ghostty +send-to-split "echo hello"
///
///   # Send to a specific split
///   ghostty +send-to-split --target=2 "vim file.txt"
///
///   # Send with newline (using echo -e or printf)
///   echo -e "ls -la\n" | xargs ghostty +send-to-split
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

    if (opts._text == null or opts._text.?.len == 0) {
        try stderr.print("No text provided to send to split.\n", .{});
        try stderr.print("Usage: ghostty +send-to-split [--target=<target>] <text>\n", .{});
        return 1;
    }

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (apprt.App.performIpc(
        alloc,
        if (opts.class) |class| .{ .class = class } else .detect,
        .send_to_split,
        .{
            .target = opts.target,
            .text = opts._text.?,
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
    try stderr.print("+send-to-split is not supported on this platform.\n", .{});
    return 1;
}
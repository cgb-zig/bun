//! This file contains Bun's crash handler. In debug builds, we are able to
//! print backtraces that are mapped to source code. In a release mode, we do
//! not have that information in the binary. Bun's solution to this is called
//! a "trace string", a compressed and url-safe encoding of a captured
//! backtrace. Version 1 tracestrings contain the following information:
//!
//! - What version and commit of Bun captured the backtrace.
//! - The platform the backtrace was captured on.
//! - The list of addresses with ASLR removed, ready to be remapped.
//! - If panicking, the message that was panicked with.
//! - List of feature-flags that were marked.
//!
//! These can be demangled using Bun's remapping API, which has cached
//! versions of all debug symbols for all versions of Bun. Hosting this keeps
//! users from having to download symbols, which can be very large.
//!
//! The remapper is open source: https://github.com/oven-sh/bun-report
//!
//! A lot of this handler is based on the Zig Standard Library implementation
//! for std.debug.panicImpl and their code for gathering backtraces.
const std = @import("std");
const bun = @import("root").bun;
const builtin = @import("builtin");
const mimalloc = @import("allocators/mimalloc.zig");
const SourceMap = @import("./sourcemap/sourcemap.zig");
const windows = std.os.windows;
const Output = bun.Output;
const Global = bun.Global;
const Features = bun.Analytics.Features;
const debug = std.debug;

/// Set this to false if you want to disable all uses of this panic handler.
/// This is useful for testing as a crash in here will not 'panicked during a panic'.
pub const enabled = true;

const report_base_url = "https://bun.report/";

/// Only print the `Bun has crashed` message once. Once this is true, control
/// flow is not returned to the main application.
var has_printed_message = false;

/// Non-zero whenever the program triggered a panic.
/// The counter is incremented/decremented atomically.
var panicking = std.atomic.Value(u8).init(0);

// Locked to avoid interleaving panic messages from multiple threads.
var panic_mutex = std.Thread.Mutex{};

/// Counts how many times the panic handler is invoked by this thread.
/// This is used to catch and handle panics triggered by the panic handler.
threadlocal var panic_stage: usize = 0;

/// This structure and formatter must be kept in sync with `bun-report`'s decoder.
pub const CrashReason = union(enum) {
    /// From @panic()
    panic: []const u8,

    /// "reached unreachable code"
    @"unreachable",

    segmentation_fault: usize,
    illegal_instruction: usize,

    /// Posix-only
    bus_error: usize,
    /// Posix-only
    floating_point_error: usize,
    /// Windows-only
    datatype_misalignment,
    /// Windows-only
    stack_overflow,

    /// Either `main` returned an error, or somewhere else in the code a trace string is printed.
    zig_error: anyerror,

    pub fn format(self: CrashReason, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .panic => try writer.print("{s}", .{self.panic}),
            .@"unreachable" => try writer.writeAll("reached unreachable code"),
            .segmentation_fault => |addr| try writer.print("Segmentation fault at address 0x{x}", .{addr}),
            .illegal_instruction => |addr| try writer.print("Illegal instruction at address 0x{x}", .{addr}),
            .bus_error => |addr| try writer.print("Bus error at address 0x{x}", .{addr}),
            .floating_point_error => |addr| try writer.print("Floating point error at address 0x{x}", .{addr}),
            .datatype_misalignment => try writer.writeAll("Unaligned memory access"),
            .stack_overflow => try writer.writeAll("Stack overflow"),
            .zig_error => |err| try writer.print("error.{s}", .{@errorName(err)}),
        }
    }
};

/// This function is invoked when a crash happpens. A crash is classified in `CrashReason`.
pub fn crashHandler(
    reason: CrashReason,
    // TODO: if both of these are specified, what is supposed to happen?
    error_return_trace: ?*std.builtin.StackTrace,
    begin_addr: ?usize,
) noreturn {
    @setCold(true);

    // If a segfault happens while panicking, we want it to actually segfault, not trigger
    // the handler.
    resetSegfaultHandler();

    nosuspend switch (panic_stage) {
        0 => {
            bun.maybeHandlePanicDuringProcessReload();

            panic_stage = 1;
            _ = panicking.fetchAdd(1, .SeqCst);

            {
                panic_mutex.lock();
                defer panic_mutex.unlock();

                const writer = Output.errorWriter();

                // The format of the panic trace is slightly different in debug
                // builds Mainly, we demangle the backtrace immediately instead
                // of using a trace string.
                //
                // To make the release-mode behavior easier to demo, debug mode
                // checks for this CLI flag.
                const debug_trace = bun.Environment.isDebug and check_flag: {
                    for (bun.argv) |arg| {
                        if (bun.strings.eqlComptime(arg, "--debug-crash-handler-use-trace-string")) {
                            break :check_flag false;
                        }
                    }
                    break :check_flag true;
                };

                if (!has_printed_message) {
                    has_printed_message = true;

                    Output.flush();
                    Output.Source.Stdio.restore();

                    writer.writeAll("=" ** 60 ++ "\n") catch std.os.abort();

                    // Omit this blurb in debug builds because it is noise
                    if (!debug_trace) {
                        Output.err("oh no",
                            \\Bun has crashed. This indicates a bug in Bun, and
                            \\should be reported as a GitHub issue.
                            \\
                            \\
                        , .{});
                    }
                    Output.flush();
                    printMetadata(writer) catch std.os.abort();
                }

                if (Output.enable_ansi_colors) {
                    writer.writeAll(Output.prettyFmt("<red>", true)) catch std.os.abort();
                }

                writer.writeAll("panic") catch std.os.abort();
                if (bun.CLI.Cli.is_main_thread) {
                    writer.writeAll("(main thread)") catch std.os.abort();
                } else switch (bun.Environment.os) {
                    .windows => {
                        var name: std.os.windows.PWSTR = undefined;
                        const result = bun.windows.GetThreadDescription(std.os.windows.kernel32.GetCurrentThread(), &name);
                        if (std.os.windows.HRESULT_CODE(result) == .SUCCESS and name[0] != 0) {
                            writer.print("({})", .{bun.fmt.utf16(bun.span(name))}) catch std.os.abort();
                        } else {
                            writer.print("(thread {d})", .{std.os.windows.kernel32.GetCurrentThreadId()}) catch std.os.abort();
                        }
                    },
                    .mac, .linux => {},
                    else => @compileError("TODO"),
                }

                writer.print(": {}", .{reason}) catch std.os.abort();

                if (Output.enable_ansi_colors) {
                    writer.writeAll(Output.prettyFmt("<r>\n", true)) catch std.os.abort();
                } else {
                    writer.writeAll("\n") catch std.os.abort();
                }

                var addr_buf: [32]usize = undefined;
                var trace_buf: std.builtin.StackTrace = undefined;

                // If a trace was not provided, compute one now
                const trace = error_return_trace orelse get_backtrace: {
                    trace_buf = std.builtin.StackTrace{
                        .index = 0,
                        .instruction_addresses = &addr_buf,
                    };
                    std.debug.captureStackTrace(begin_addr orelse @returnAddress(), &trace_buf);
                    break :get_backtrace &trace_buf;
                };

                if (debug_trace) {
                    // TODO: On Windows, there are sometimes issues remapping information here:
                    dumpStackTrace(trace.*);
                } else {
                    writer.writeAll("Please report this panic as a GitHub issue using this link:\n") catch std.os.abort();
                    if (Output.enable_ansi_colors) {
                        writer.print(Output.prettyFmt("<cyan>", true), .{}) catch std.os.abort();
                    }
                }

                encodeTraceString(
                    .{
                        .trace = trace,
                        .reason = reason,
                        .action = .open_issue,
                    },
                    writer,
                ) catch std.os.abort();

                if (Output.enable_ansi_colors) {
                    writer.writeAll(Output.prettyFmt("<r>\n", true)) catch std.os.abort();
                } else {
                    writer.writeAll("\n") catch std.os.abort();
                }

                Output.flush();
            }

            // Be aware that this function only lets one thread return from it.
            // This is important sot hat we do not try to run the reload logic twice.
            waitForOtherThreadToFinishPanicking();

            if (bun.auto_reload_on_crash and
                // Do not reload if the panic arised FROM the reload function.
                !bun.isProcessReloadInProgressOnAnotherThread())
            {
                // attempt to prevent a double panic
                bun.auto_reload_on_crash = false;

                Output.prettyErrorln("<d>--- Bun is auto-restarting due to crash <d>[time: <b>{d}<r><d>] ---<r>", .{
                    @max(std.time.milliTimestamp(), 0),
                });
                Output.flush();

                // It is important to be aware that this function *can* panic.
                bun.reloadProcess(bun.default_allocator, false, true);
            }
        },
        inline 1, 2 => |t| {
            if (t == 1) {
                panic_stage = 2;
                Output.flush();
            }
            panic_stage = 3;

            // A panic happened while trying to print a previous panic message,
            // we're still holding the mutex but that's fine as we're going to
            // call abort()
            const stderr = std.io.getStdErr().writer();
            stderr.print("\npanic: {s}\n", .{reason}) catch std.os.abort();
            stderr.print("panicked during a panic. Aborting.\n", .{}) catch std.os.abort();
        },
        3 => {
            // Panicked while printing "Panicked during a panic."
        },
        else => {
            // Panicked or otherwise looped into the panic handler while trying to exit.
            std.os.abort();
        },
    };

    crash();
}

/// This is called when `main` returns a Zig error.
/// We don't want to treat it as a crash under certain error codes.
pub fn handleRootError(err: anyerror, error_return_trace: ?*std.builtin.StackTrace) noreturn {
    var show_trace = bun.Environment.isDebug;

    switch (err) {
        error.OutOfMemory => bun.outOfMemory(),

        error.InvalidArgument,
        error.@"Invalid Bunfig",
        => if (!show_trace) Global.exit(1),

        error.SyntaxError => {
            Output.err("SyntaxError", "An error occurred while parsing code", .{});
        },

        error.CurrentWorkingDirectoryUnlinked => {
            Output.errGeneric(
                "The current working directory was deleted, so that command didn't work. Please cd into a different directory and try again.",
                .{},
            );
        },

        error.SystemFdQuotaExceeded => {
            if (comptime bun.Environment.isPosix) {
                const limit = if (std.os.getrlimit(.NOFILE)) |limit| limit.cur else |_| null;
                if (comptime bun.Environment.isMac) {
                    Output.prettyError(
                        \\<r><red>error<r>: Your computer ran out of file descriptors <d>(<red>SystemFdQuotaExceeded<r><d>)<r>
                        \\
                        \\<d>Current limit: {d}<r>
                        \\
                        \\To fix this, try running:
                        \\
                        \\  <cyan>sudo launchctl limit maxfiles 2147483646<r>
                        \\  <cyan>ulimit -n 2147483646<r>
                        \\
                        \\That will only work until you reboot.
                        \\
                    ,
                        .{
                            bun.fmt.nullableFallback(limit, "<unknown>"),
                        },
                    );
                } else {
                    Output.prettyError(
                        \\
                        \\<r><red>error<r>: Your computer ran out of file descriptors <d>(<red>SystemFdQuotaExceeded<r><d>)<r>
                        \\
                        \\<d>Current limit: {d}<r>
                        \\
                        \\To fix this, try running:
                        \\
                        \\  <cyan>sudo echo -e "\nfs.file-max=2147483646\n" >> /etc/sysctl.conf<r>
                        \\  <cyan>sudo sysctl -p<r>
                        \\  <cyan>ulimit -n 2147483646<r>
                        \\
                    ,
                        .{
                            bun.fmt.nullableFallback(limit, "<unknown>"),
                        },
                    );

                    if (bun.getenvZ("USER")) |user| {
                        if (user.len > 0) {
                            Output.prettyError(
                                \\
                                \\If that still doesn't work, you may need to add these lines to /etc/security/limits.conf:
                                \\
                                \\ <cyan>{s} soft nofile 2147483646<r>
                                \\ <cyan>{s} hard nofile 2147483646<r>
                                \\
                            ,
                                .{ user, user },
                            );
                        }
                    }
                }
            } else {
                Output.prettyError(
                    \\<r><red>error<r>: Your computer ran out of file descriptors <d>(<red>SystemFdQuotaExceeded<r><d>)<r>
                ,
                    .{},
                );
            }
        },

        error.ProcessFdQuotaExceeded => {
            if (comptime bun.Environment.isPosix) {
                const limit = if (std.os.getrlimit(.NOFILE)) |limit| limit.cur else |_| null;
                if (comptime bun.Environment.isMac) {
                    Output.prettyError(
                        \\
                        \\<r><red>error<r>: bun ran out of file descriptors <d>(<red>ProcessFdQuotaExceeded<r><d>)<r>
                        \\
                        \\<d>Current limit: {d}<r>
                        \\
                        \\To fix this, try running:
                        \\
                        \\  <cyan>ulimit -n 2147483646<r>
                        \\
                        \\You may also need to run:
                        \\
                        \\  <cyan>sudo launchctl limit maxfiles 2147483646<r>
                        \\
                    ,
                        .{
                            bun.fmt.nullableFallback(limit, "<unknown>"),
                        },
                    );
                } else {
                    Output.prettyError(
                        \\
                        \\<r><red>error<r>: bun ran out of file descriptors <d>(<red>ProcessFdQuotaExceeded<r><d>)<r>
                        \\
                        \\<d>Current limit: {d}<r>
                        \\
                        \\To fix this, try running:
                        \\
                        \\  <cyan>ulimit -n 2147483646<r>
                        \\
                        \\That will only work for the current shell. To fix this for the entire system, run:
                        \\
                        \\  <cyan>sudo echo -e "\nfs.file-max=2147483646\n" >> /etc/sysctl.conf<r>
                        \\  <cyan>sudo sysctl -p<r>
                        \\
                    ,
                        .{
                            bun.fmt.nullableFallback(limit, "<unknown>"),
                        },
                    );

                    if (bun.getenvZ("USER")) |user| {
                        if (user.len > 0) {
                            Output.prettyError(
                                \\
                                \\If that still doesn't work, you may need to add these lines to /etc/security/limits.conf:
                                \\
                                \\ <cyan>{s} soft nofile 2147483646<r>
                                \\ <cyan>{s} hard nofile 2147483646<r>
                                \\
                            ,
                                .{ user, user },
                            );
                        }
                    }
                }
            } else {
                Output.prettyErrorln(
                    \\<r><red>error<r>: bun ran out of file descriptors <d>(<red>ProcessFdQuotaExceeded<r><d>)<r>
                ,
                    .{},
                );
            }
        },

        // The usage of `unreachable` in Zig's std.os may cause the file descriptor problem to show up as other errors
        error.NotOpenForReading, error.Unexpected => {
            if (comptime bun.Environment.isPosix) {
                const limit = std.os.getrlimit(.NOFILE) catch std.mem.zeroes(std.os.rlimit);

                if (limit.cur > 0 and limit.cur < (8192 * 2)) {
                    Output.prettyError(
                        \\
                        \\<r><red>error<r>: An unknown error ocurred, possibly due to low max file descriptors <d>(<red>Unexpected<r><d>)<r>
                        \\
                        \\<d>Current limit: {d}<r>
                        \\
                        \\To fix this, try running:
                        \\
                        \\  <cyan>ulimit -n 2147483646<r>
                        \\
                    ,
                        .{
                            limit.cur,
                        },
                    );

                    if (bun.Environment.isLinux) {
                        if (bun.getenvZ("USER")) |user| {
                            if (user.len > 0) {
                                Output.prettyError(
                                    \\
                                    \\If that still doesn't work, you may need to add these lines to /etc/security/limits.conf:
                                    \\
                                    \\ <cyan>{s} soft nofile 2147483646<r>
                                    \\ <cyan>{s} hard nofile 2147483646<r>
                                    \\
                                ,
                                    .{
                                        user,
                                        user,
                                    },
                                );
                            }
                        }
                    } else if (bun.Environment.isMac) {
                        Output.prettyError(
                            \\
                            \\If that still doesn't work, you may need to run:
                            \\
                            \\  <cyan>sudo launchctl limit maxfiles 2147483646<r>
                            \\
                        ,
                            .{},
                        );
                    }
                } else {
                    Output.errGeneric(
                        "An unknown error ocurred <d>(<red>{s}<r><d>)<r>",
                        .{@errorName(err)},
                    );
                    show_trace = true;
                }
            } else {
                Output.errGeneric(
                    \\An unknown error ocurred <d>(<red>{s}<r><d>)<r>
                ,
                    .{@errorName(err)},
                );
                show_trace = true;
            }
        },

        error.ENOENT, error.FileNotFound => {
            Output.err(
                "ENOENT",
                "Bun could not find a file, and the code that produces this error is missing a better error.",
                .{},
            );
        },

        error.MissingPackageJSON => {
            Output.err(
                "MissingPackageJSON",
                "Bun could not find a package.json file.",
                .{},
            );
        },

        else => {
            Output.errGeneric(
                if (bun.Environment.isDebug)
                    "'main' returned <red>error.{s}<r>"
                else
                    "An internal error ocurred (<red>{s}<r>)",
                .{@errorName(err)},
            );
            show_trace = true;
        },
    }

    if (show_trace) {
        handleErrorReturnTraceExtra(err, error_return_trace, true);
    }

    Global.exit(1);
}

pub fn panicImpl(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, begin_addr: ?usize) noreturn {
    @setCold(true);
    crashHandler(
        if (bun.strings.eqlComptime(msg, "reached unreachable code"))
            .{ .@"unreachable" = {} }
        else
            .{ .panic = msg },
        error_return_trace,
        begin_addr orelse @returnAddress(),
    );
}

fn panicBuiltin(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, begin_addr: ?usize) noreturn {
    std.debug.panicImpl(error_return_trace, begin_addr, msg);
}

pub const panic = if (enabled) panicImpl else panicBuiltin;

const arch_display_string = if (bun.Environment.isAarch64)
    if (bun.Environment.isMac) "Silicon" else "arm64"
else
    "x64";

const metadata_version_line = std.fmt.comptimePrint(
    "Bun v{s} {s} {s}{s}\n",
    .{
        Global.package_json_version_with_sha,
        bun.Environment.os.displayString(),
        arch_display_string,
        if (bun.Environment.baseline) " (baseline)" else "",
    },
);

fn handleSegfaultPosix(sig: i32, info: *const std.os.siginfo_t, _: ?*const anyopaque) callconv(.C) noreturn {
    resetSegfaultHandler();

    const addr = switch (bun.Environment.os) {
        .linux => @intFromPtr(info.fields.sigfault.addr),
        .mac => @intFromPtr(info.addr),
        else => unreachable,
    };

    crashHandler(
        switch (sig) {
            std.os.SIG.SEGV => .{ .segmentation_fault = addr },
            std.os.SIG.ILL => .{ .illegal_instruction = addr },
            std.os.SIG.BUS => .{ .bus_error = addr },
            std.os.SIG.FPE => .{ .floating_point_error = addr },

            // we do not register this handler for other signals
            else => unreachable,
        },
        null,
        @returnAddress(),
    );
}

pub fn updatePosixSegfaultHandler(act: ?*const std.os.Sigaction) !void {
    try std.os.sigaction(std.os.SIG.SEGV, act, null);
    try std.os.sigaction(std.os.SIG.ILL, act, null);
    try std.os.sigaction(std.os.SIG.BUS, act, null);
    try std.os.sigaction(std.os.SIG.FPE, act, null);
}

var windows_segfault_handle: ?windows.HANDLE = null;

pub fn init() void {
    if (!enabled) return;
    switch (bun.Environment.os) {
        .windows => {
            windows_segfault_handle = windows.kernel32.AddVectoredExceptionHandler(0, handleSegfaultWindows);
        },
        .mac, .linux => {
            const act = std.os.Sigaction{
                .handler = .{ .sigaction = handleSegfaultPosix },
                .mask = std.os.empty_sigset,
                .flags = (std.os.SA.SIGINFO | std.os.SA.RESTART | std.os.SA.RESETHAND),
            };
            updatePosixSegfaultHandler(&act) catch {};
        },
        else => @compileError("TODO"),
    }
}

pub fn resetSegfaultHandler() void {
    if (bun.Environment.os == .windows) {
        if (windows_segfault_handle) |handle| {
            const rc = windows.kernel32.RemoveVectoredExceptionHandler(handle);
            windows_segfault_handle = null;
            bun.assert(rc != 0);
        }
        return;
    }

    const act = std.os.Sigaction{
        .handler = .{ .handler = std.os.SIG.DFL },
        .mask = std.os.empty_sigset,
        .flags = 0,
    };
    // To avoid a double-panic, do nothing if an error happens here.
    updatePosixSegfaultHandler(&act) catch {};
}

pub fn handleSegfaultWindows(info: windows.EXCEPTION_POINTERS) callconv(windows.WINAPI) c_long {
    resetSegfaultHandler();
    crashHandler(
        switch (info.ExceptionRecord.ExceptionCode) {
            windows.EXCEPTION_DATATYPE_MISALIGNMENT => .{ .datatype_misalignment = {} },
            windows.EXCEPTION_ACCESS_VIOLATION => .{ .segmentation_fault = info.ExceptionRecord.ExceptionInformation[1] },
            windows.EXCEPTION_ILLEGAL_INSTRUCTION => .{ .illegal_instruction = info.ContextRecord.getRegs().ip },
            windows.EXCEPTION_STACK_OVERFLOW => .{ .stack_overflow = {} },
            else => return windows.EXCEPTION_CONTINUE_SEARCH,
        },
        null,
        @intFromPtr(info.ExceptionRecord.ExceptionAddress),
    );
}

pub fn printMetadata(writer: anytype) !void {
    try writer.writeAll(metadata_version_line);
    {
        try writer.print("Args: ", .{});
        var arg_chars_left: usize = 196;
        for (bun.argv, 0..) |arg, i| {
            if (i != 0) try writer.writeAll(", ");
            try bun.fmt.quotedWriter(writer, arg[0..@min(arg.len, arg_chars_left)]);
            arg_chars_left -|= arg.len;
            if (arg_chars_left == 0) {
                try writer.writeAll("...");
                break;
            }
        }
    }
    try writer.print("\n{}", .{bun.Analytics.Features.formatter()});

    if (bun.use_mimalloc) {
        var elapsed_msecs: usize = 0;
        var user_msecs: usize = 0;
        var system_msecs: usize = 0;
        var current_rss: usize = 0;
        var peak_rss: usize = 0;
        var current_commit: usize = 0;
        var peak_commit: usize = 0;
        var page_faults: usize = 0;
        mimalloc.mi_process_info(
            &elapsed_msecs,
            &user_msecs,
            &system_msecs,
            &current_rss,
            &peak_rss,
            &current_commit,
            &peak_commit,
            &page_faults,
        );
        try writer.print("Elapsed: {d}ms | User: {d}ms | Sys: {d}ms\nRSS: {:<3.2} | Peak: {:<3.2} | Commit: {:<3.2} | Faults: {d}\n", .{
            elapsed_msecs,
            user_msecs,
            system_msecs,
            std.fmt.fmtIntSizeDec(current_rss),
            std.fmt.fmtIntSizeDec(peak_rss),
            std.fmt.fmtIntSizeDec(current_commit),
            page_faults,
        });
    }

    try writer.writeAll("\n");
}

fn waitForOtherThreadToFinishPanicking() void {
    if (panicking.fetchSub(1, .SeqCst) != 1) {
        // Another thread is panicking, wait for the last one to finish
        // and call abort()
        if (builtin.single_threaded) unreachable;

        // Sleep forever without hammering the CPU
        var futex = std.atomic.Value(u32).init(0);
        while (true) std.Thread.Futex.wait(&futex, 0);
        comptime unreachable;
    }
}

/// Each platform is encoded is a single character. It is placed right after the
/// slash after the version, so someone just reading the trace string can tell
/// what platform it came from. L, M, and W are for Linux, macOS, and Windows,
/// with capital letters indicating aarch64, lowercase indicating x86_64.
///
/// eg: 'https://bun.report/1.1.3/we04c...
//                                ^ this tells you it is windows x86_64
///
/// Baseline gets a weirder encoding of a mix of b and e.
const Platform = enum(u8) {
    linux_x86_64 = 'l',
    linux_x86_64_baseline = 'B',
    linux_aarch64 = 'L',

    mac_x86_64_baseline = 'b',
    mac_x86_64 = 'm',
    mac_aarch64 = 'M',

    windows_x86_64 = 'w',
    windows_x86_64_baseline = 'e',

    const current = @field(Platform, @tagName(bun.Environment.os) ++
        "_" ++ @tagName(builtin.target.cpu.arch) ++
        (if (bun.Environment.baseline) "_baseline" else ""));
};

const tracestr_version: u8 = '1';

const tracestr_header = std.fmt.comptimePrint(
    "{s}/{c}{s}{c}",
    .{
        bun.Environment.version_string,
        @intFromEnum(Platform.current),
        if (bun.Environment.git_sha.len > 0) bun.Environment.git_sha[0..7] else "unknown",
        tracestr_version,
    },
);

const Address = union(enum) {
    unknown,
    known: struct {
        address: i32,
        // null -> from bun.exe
        object: ?[]const u8,
    },
    javascript,

    pub fn writeEncoded(self: Address, writer: anytype) !void {
        switch (self) {
            .unknown => try writer.writeAll("_"),
            .known => |known| {
                if (known.object) |object| {
                    try SourceMap.encodeVLQ(1).writeTo(writer);
                    try SourceMap.encodeVLQ(@intCast(object.len)).writeTo(writer);
                    try writer.writeAll(object);
                }
                try SourceMap.encodeVLQ(known.address).writeTo(writer);
            },
            .javascript => {
                try writer.writeAll("=");
            },
        }
    }

    pub fn format(self: Address, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .unknown => try writer.print("unknown address", .{}),
            .known => |known| try writer.print("0x{x} @ {s}", .{ known.address, known.object orelse "bun" }),
            .javascript => try writer.print("javascript address", .{}),
        }
    }
};

const TraceString = struct {
    trace: *std.builtin.StackTrace,
    reason: CrashReason,
    action: Action,

    const Action = enum {
        /// Open a pre-filled GitHub issue with the expanded trace
        open_issue,
        /// View the trace with nothing else
        view_trace,
    };

    pub fn format(self: TraceString, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try encodeTraceString(self, writer);
    }
};

fn encodeTraceString(opts: TraceString, writer: anytype) !void {
    try writer.writeAll(report_base_url ++ tracestr_header);

    const image_path = if (bun.Environment.isWindows) bun.windows.exePathW() else null;

    var name_bytes: [512]u16 = undefined;
    var name_bytes_utf8: [1024]u8 = undefined;

    for (opts.trace.instruction_addresses[0..opts.trace.index]) |addr| {
        const address: Address = switch (bun.Environment.os) {
            .windows => addr: {
                const module = bun.windows.getModuleHandleFromAddress(addr) orelse {
                    // TODO: try to figure out of this is a JS stack frame
                    break :addr .{ .unknown = {} };
                };

                const base_address = @intFromPtr(module);
                const name = bun.windows.getModuleNameW(module, &name_bytes) orelse
                    break :addr .{ .unknown = {} };

                break :addr .{
                    .mapped = .{
                        // To remap this, `pdb-addr2line --exe bun.pdb 0x123456`
                        .address = addr - base_address,

                        .object = if (!std.mem.eql(u16, name, image_path)) name: {
                            const basename = name[std.mem.lastIndexOfAny(u16, name, "\\/") orelse 0 ..];
                            break :name bun.strings.convertUTF8toUTF16InBuffer(&name_bytes_utf8, basename);
                        } else null,
                    },
                };
            },
            .mac => addr: {
                // This code is slightly modified from std.debug.DebugInfo.lookupModuleNameDyld
                // https://github.com/ziglang/zig/blob/215de3ee67f75e2405c177b262cb5c1cd8c8e343/lib/std/debug.zig#L1783
                const address = if (addr == 0) 0 else addr - 1;

                const image_count = std.c._dyld_image_count();

                var i: u32 = 0;
                while (i < image_count) : (i += 1) {
                    const header = std.c._dyld_get_image_header(i) orelse continue;
                    const base_address = @intFromPtr(header);
                    if (address < base_address) continue;
                    // This 'slide' is the ASLR offset. Subtract from `address` to get a stable address
                    const vmaddr_slide = std.c._dyld_get_image_vmaddr_slide(i);

                    var it = std.macho.LoadCommandIterator{
                        .ncmds = header.ncmds,
                        .buffer = @alignCast(@as(
                            [*]u8,
                            @ptrFromInt(@intFromPtr(header) + @sizeOf(std.macho.mach_header_64)),
                        )[0..header.sizeofcmds]),
                    };

                    while (it.next()) |cmd| switch (cmd.cmd()) {
                        .SEGMENT_64 => {
                            const segment_cmd = cmd.cast(std.macho.segment_command_64).?;
                            if (!bun.strings.eqlComptime(segment_cmd.segName(), "__TEXT")) continue;

                            const original_address = address - vmaddr_slide;
                            const seg_start = segment_cmd.vmaddr;
                            const seg_end = seg_start + segment_cmd.vmsize;
                            if (original_address >= seg_start and original_address < seg_end) {
                                // Subtract ASLR value for stable address
                                const stable_address: isize = @intCast(address - vmaddr_slide);
                                // Subtract base address for compactness
                                // To remap this, `llvm-symbolizer --obj bun-with-symbols --relative-address 0x123456`
                                const relative_address: i32 = @intCast(stable_address - @as(isize, @intCast(base_address)));

                                if (relative_address < 0) break;

                                const object = if (i == 0)
                                    null // zero is the main binary
                                else
                                    std.fs.path.basename(bun.sliceTo(std.c._dyld_get_image_name(i), 0));

                                break :addr .{ .known = .{
                                    .object = object,
                                    .address = relative_address,
                                } };
                            }
                        },
                        else => {},
                    };
                }

                break :addr .{ .unknown = {} };
            },
            else => addr: {
                // This code is slightly modified from std.debug.DebugInfo.lookupModuleDl
                // https://github.com/ziglang/zig/blob/215de3ee67f75e2405c177b262cb5c1cd8c8e343/lib/std/debug.zig#L2024
                var ctx: struct {
                    // Input
                    address: usize,
                    i: usize = 0,
                    // Output
                    result: Address = .{ .unknown = {} },
                } = .{ .address = addr -| 1 };
                const CtxTy = @TypeOf(ctx);

                std.os.dl_iterate_phdr(&ctx, error{Found}, struct {
                    fn callback(info: *std.os.dl_phdr_info, _: usize, context: *CtxTy) !void {
                        defer context.i += 1;
                        if (context.address < info.dlpi_addr) return;
                        const phdrs = info.dlpi_phdr[0..info.dlpi_phnum];
                        for (phdrs) |*phdr| {
                            if (phdr.p_type != std.elf.PT_LOAD) continue;

                            // Overflowing addition is used to handle the case of VSDOs
                            // having a p_vaddr = 0xffffffffff700000
                            const seg_start = info.dlpi_addr +% phdr.p_vaddr;
                            const seg_end = seg_start + phdr.p_memsz;
                            if (context.address >= seg_start and context.address < seg_end) {
                                const name = bun.sliceTo(info.dlpi_name, 0) orelse "";
                                std.debug.print("\nhi {d}, {s}, base = 0x{x}, ptr = 0x{x}", .{ context.i, name, info.dlpi_addr, context.address });
                                return error.Found;
                            }
                        }
                    }
                }.callback) catch {};

                break :addr ctx.result;
            },
        };

        try address.writeEncoded(writer);
    }

    try writer.writeAll(comptime zero_vlq: {
        const vlq = SourceMap.encodeVLQ(0);
        break :zero_vlq vlq.bytes[0..vlq.len];
    });

    // The following switch must be kept in sync with `bun-report`'s decoder.
    switch (opts.reason) {
        .panic => |message| {
            try writer.writeByte('0');

            var compressed_bytes: [2048]u8 = undefined;
            var len: usize = compressed_bytes.len;
            const ret: bun.zlib.ReturnCode = @enumFromInt(bun.zlib.compress2(&compressed_bytes, &len, message.ptr, message.len, 9));
            const compressed = switch (ret) {
                .Ok => compressed_bytes[0..len],
                // Insufficient memory.
                .MemError => return error.OutOfMemory,
                // The buffer dest was not large enough to hold the compressed data.
                .BufError => return error.NoSpaceLeft,

                // The level was not Z_DEFAULT_LEVEL, or was not between 0 and 9.
                // This is technically possible but impossible because we pass 9.
                .StreamError => return error.Unexpected,
                else => return error.Unexpected,
            };

            var b64_bytes: [2048]u8 = undefined;
            if (bun.base64.encodeLen(compressed) > b64_bytes.len) {
                return error.NoSpaceLeft;
            }
            const b64_len = bun.base64.encode(&b64_bytes, compressed);

            try writer.writeAll(std.mem.trimRight(u8, b64_bytes[0..b64_len], "="));
        },

        .@"unreachable" => try writer.writeByte('1'),

        .segmentation_fault => |addr| {
            try writer.writeByte('2');
            try writeU64AsTwoVLQs(writer, addr);
        },
        .illegal_instruction => |addr| {
            try writer.writeByte('3');
            try writeU64AsTwoVLQs(writer, addr);
        },
        .bus_error => |addr| {
            try writer.writeByte('4');
            try writeU64AsTwoVLQs(writer, addr);
        },
        .floating_point_error => |addr| {
            try writer.writeByte('5');
            try writeU64AsTwoVLQs(writer, addr);
        },

        .datatype_misalignment => try writer.writeByte('6'),
        .stack_overflow => try writer.writeByte('7'),

        .zig_error => |err| {
            try writer.writeByte('8');
            try writer.writeAll(@errorName(err));
        },
    }

    if (opts.action == .view_trace) {
        try writer.writeAll("/view");
    }
}

fn writeU64AsTwoVLQs(writer: anytype, addr: usize) !void {
    const first = SourceMap.encodeVLQ(@intCast((addr & 0xFFFFFFFF00000000) >> 32));
    const second = SourceMap.encodeVLQ(@intCast(addr & 0xFFFFFFFF));
    try first.writeTo(writer);
    try second.writeTo(writer);
}

/// Crash. Make sure segfault handlers are off so that this doesnt trigger the crash handler.
/// This causes a segfault on posix systems to try to get a core dump.
fn crash() noreturn {
    switch (bun.Environment.os) {
        .windows => {
            std.os.abort();
        },
        else => {
            // Parts of this is copied from std.os.abort (linux non libc path) and WTFCrash
            // Cause a segfault to make sure a core dump is generated if such is enabled

            // Only one thread may proceed to the rest of abort().
            const global = struct {
                var abort_entered: bool = false;
            };
            while (@cmpxchgWeak(bool, &global.abort_entered, false, true, .SeqCst, .SeqCst)) |_| {}

            // Install default handler so that the tkill below will terminate.
            const sigact = std.os.Sigaction{ .handler = .{ .handler = std.os.SIG.DFL }, .mask = std.os.empty_sigset, .flags = 0 };
            inline for (.{
                std.os.SIG.SEGV,
                std.os.SIG.ILL,
                std.os.SIG.BUS,
                std.os.SIG.ABRT,
                std.os.SIG.FPE,
                std.os.SIG.HUP,
                std.os.SIG.TERM,
            }) |sig| {
                std.os.sigaction(sig, &sigact, null) catch {};
            }

            @as(*allowzero volatile u8, @ptrFromInt(0xDEADBEEF)).* = 0;
            std.os.raise(std.os.SIG.SEGV) catch {};
            @as(*allowzero volatile u8, @ptrFromInt(0)).* = 0;
            std.c._exit(127);
        },
    }
}

pub var verbose_error_trace = false;

fn handleErrorReturnTraceExtra(err: anyerror, maybe_trace: ?*std.builtin.StackTrace, comptime is_root: bool) void {
    if (!builtin.have_error_return_tracing) return;
    if (!verbose_error_trace and !is_root) return;

    if (maybe_trace) |trace| {
        // The format of the panic trace is slightly different in debug
        // builds Mainly, we demangle the backtrace immediately instead
        // of using a trace string.
        //
        // To make the release-mode behavior easier to demo, debug mode
        // checks for this CLI flag.
        const is_debug = bun.Environment.isDebug and check_flag: {
            for (bun.argv) |arg| {
                if (bun.strings.eqlComptime(arg, "--debug-crash-handler-use-trace-string")) {
                    break :check_flag false;
                }
            }
            break :check_flag true;
        };

        if (is_debug) {
            if (is_root) {
                Output.note(
                    "'main' returned error.{s}.{s}",
                    .{
                        @errorName(err),
                        if (verbose_error_trace)
                            ""
                        else
                            " (release build will not have this trace by default)",
                    },
                );
            } else {
                Output.note(
                    "caught error.{s}:",
                    .{@errorName(err)},
                );
            }
            Output.flush();
            dumpStackTrace(trace.*);
        } else {
            const ts = TraceString{
                .trace = trace,
                .reason = .{ .zig_error = err },
                .action = .view_trace,
            };
            if (is_root) {
                Output.prettyErrorln(
                    \\
                    \\The trace for the above error has been captured as a URL,
                    \\which will direct you to fill out a GitHub issue for Bun.
                    \\This trace only includes functions in Bun, and contains none
                    \\of your code data:
                    \\<cyan>{}<r>
                    \\
                ,
                    .{ts},
                );
            } else {
                Output.prettyErrorln(
                    "<cyan>trace<r>: error.{s}: <d>{}<r>",
                    .{ @errorName(err), ts },
                );
            }
        }
    }
}

/// In many places we catch errors, the trace for them is absorbed and only a
/// single line (the error name) is printed. When this is set, we will print
/// trace strings for those errors (or full stacks in debug builds).
///
/// This can be enabled by passing `--verbose-error-trace` to the CLI.
/// In release builds with error return tracing enabled, this is also exposed.
/// You can test if this feature is available by checking `bun --help` for the flag.
pub inline fn handleErrorReturnTrace(err: anyerror, maybe_trace: ?*std.builtin.StackTrace) void {
    handleErrorReturnTraceExtra(err, maybe_trace, false);
}

const stdDumpStackTrace = debug.dumpStackTrace;

pub fn dumpStackTrace(trace: std.builtin.StackTrace) void {
    if (bun.Environment.isWindows) {
        // TODO: Zig's dump trace for windows is not fully reliable.
    }
    stdDumpStackTrace(trace);
}

// NOTE: You will need to modify some stuff here to make this work for you, like importing your own implementation,
// removing or adding some parameters or changing the use of the API fns in case the signature doesn't match exactly 
// (e.g. you might need to remove the thread_id parameters)

const std = @import("std");

const distro = @import("distribution.zig");

const Mngr = @import("buffer_manager.zig");

const assert = std.debug.assert;

pub const BenchType = union(enum) {
    SingleThreadedSync,
    MultiThreadedSync: struct { thread_count: u64 },
    MultiThreadedAsync: struct { thread_count: u64 },
};

pub fn RunBenchmark(
    comptime memory_capacity: u64,
    comptime disk_capacity: u64,
    comptime page_size: u64,
    comptime bench_type: BenchType,
    comptime verify_served_pages: bool,
    theta: f64,
    total_request_count: u64,
    file_path: []const u8,
    io: std.Io 
) !f64 {
    assert(disk_capacity >= memory_capacity);
    assert(page_size <= memory_capacity);
    assert(@popCount(page_size) == 1);
    assert((disk_capacity % page_size) == 0);
    assert((memory_capacity % page_size) == 0);
    const pfn_cnt = disk_capacity / page_size;

    std.debug.print("\nRunning Benchmark with Parameters:\n\n\tType: {}\n\tMemory Capacity: {Bi}\n\tDisk Capacity: {Bi}\n\tPage Size: {Bi}\n\tTheta: {}\n\tRequest Count: {}\n\n", .{
        bench_type,
        memory_capacity,
        disk_capacity,
        page_size,
        theta,
        total_request_count,
    });

    // NOTE: couple parameters that your impl probably doesn't need
    // const page_table_size = @min(memory_capacity, page_size << 16);
    // const pfn_table_segment_size = 1 << 10;
    // const simd_size = 512;
    const max_in_flight = 128;
    // const thread_count = switch (bench_type) {
    //     .SingleThreadedSync => 1,
    //     .MultiThreadedAsync => |cnt| cnt.thread_count,
    //     .MultiThreadedSync => |cnt| cnt.thread_count,
    // };

    // NOTE: Swap in your own type
    const BufferManager = Mngr.BufferManager(
        page_size,
        // page_table_size,
        // pfn_table_segment_size,
        memory_capacity,
        disk_capacity,
        // simd_size,
        // thread_count,
    );

    std.debug.print("Setting up benchmark...", .{});

    const alloc = std.heap.smp_allocator;

    const seed: u64 = @intCast(std.Io.Clock.awake.now(io).toNanoseconds());
    var prng = std.Random.DefaultPrng.init(seed);
    var rng = prng.random();
    const pfn_requests = try distro.GenScramZipfSequence(0, pfn_cnt, theta, &rng, total_request_count, alloc);
    defer alloc.free(pfn_requests);

    std.debug.print("Initializing BufferManager...", .{});
    var bfr_mngr = try BufferManager.Init(file_path);
    defer bfr_mngr.Deinit();

    std.debug.print("InitPFNs...", .{});
    const verify_shift: u6 = @intCast(rng.int(u8) % 63);
    try InitPFNs(&bfr_mngr, pfn_cnt, verify_served_pages, verify_shift);

    std.debug.print(" Done\n\nBeginning benchmark...", .{});

    const run_time_ns = switch (bench_type) {
        .SingleThreadedSync => try RunSTBench(&bfr_mngr, pfn_requests, verify_served_pages, verify_shift, io),
        .MultiThreadedSync => |cnt| try RunMTBench(&bfr_mngr, pfn_requests, verify_served_pages, verify_shift, cnt.thread_count),
        .MultiThreadedAsync => |cnt| try RunMTAsyncBench(&bfr_mngr, pfn_requests, verify_served_pages, verify_shift, cnt.thread_count, max_in_flight),
    };

    const run_time_s = @as(f64, @floatFromInt(run_time_ns)) / 1000_000_000;
    const ops = @as(f64, @floatFromInt(total_request_count)) / run_time_s;

    std.debug.print(" Done\nTook: {d} ns\nMOPS: {}\n", .{ run_time_ns, ops / 1000_000 });

    return ops;
}

fn InitPFNs(bfr_mngr: anytype, pfn_cnt: u64, comptime init_page: bool, shift: u6) !void {
    for (0..pfn_cnt) |i| {
        const res = try bfr_mngr.AllocPageFrame();
        // NOTE: used later to verify we got the correct page back
        if (init_page) {
            const first_bytes: *u64 = @ptrCast(res.page);
            first_bytes.* = i << shift;
        }
        bfr_mngr.DecrementPinCount(res.pfn);
    }
}

fn RunSTBench(bfr_mngr: anytype, pfn_requests: []u64, comptime verify_served_pages: bool, verify_shift: u6, io: std.Io) !u64 {
    const thread_id = 0;

    var start_signal: bool = undefined;
    @atomicStore(bool, &start_signal, true, .monotonic);
    var bench_success: bool = undefined;
    @atomicStore(bool, &bench_success, true, .monotonic);

    const t_start: u64 = @intCast(std.Io.Clock.awake.now(io).toNanoseconds()); 
    RunBench(bfr_mngr, pfn_requests, verify_served_pages, verify_shift, thread_id, &start_signal, &bench_success);
    const t_end: u64 = @intCast(std.Io.Clock.awake.now(io).toNanoseconds()); 

    if (!@atomicLoad(bool, &bench_success, .monotonic)) return error.BenchmarkFailed;

    return t_end - t_start;
}

fn RunMTBench(bfr_mngr: anytype, pfn_requests: []u64, comptime verify_served_pages: bool, verify_shift: u6, comptime thread_count: u64) !u64 {
    var timer = try std.time.Timer.start();
    var start_signal: bool = undefined;
    var bench_success: bool = undefined;
    @atomicStore(bool, &bench_success, true, .monotonic);

    const pfns_per_thread = pfn_requests.len / thread_count;
    var other_workers: [thread_count - 1]std.Thread = undefined;
    for (&other_workers, 1..) |*worker, thread_id| {
        worker.* = try std.Thread.spawn(.{}, RunBench, .{
            bfr_mngr,
            pfn_requests[(pfns_per_thread * thread_id)..][0..pfns_per_thread],
            verify_served_pages,
            verify_shift,
            thread_id,
            &start_signal,
            &bench_success,
        });
    }

    const t_start = timer.read();

    @atomicStore(bool, &start_signal, true, .monotonic);
    RunBench(
        bfr_mngr,
        pfn_requests[(pfns_per_thread * (thread_count - 1))..],
        verify_served_pages,
        verify_shift,
        0,
        &start_signal,
        &bench_success,
    );

    for (other_workers) |wrkr| wrkr.join();

    const t_end = timer.read();

    if (!@atomicLoad(bool, &bench_success, .monotonic)) return error.BenchmarkFailed;

    return t_end - t_start;
}

fn RunMTAsyncBench(
    bfr_mngr: anytype,
    pfn_requests: []u64,
    comptime verify_served_pages: bool,
    verify_shift: u6,
    comptime thread_count: u64,
    comptime max_in_flight: u64,
) !u64 {
    var timer = try std.time.Timer.start();
    var start_signal: bool = undefined;
    var bench_success: bool = undefined;
    @atomicStore(bool, &bench_success, true, .monotonic);

    const pfns_per_thread = pfn_requests.len / thread_count;
    var other_workers: [thread_count - 1]std.Thread = undefined;
    for (&other_workers, 1..) |*worker, thread_id| {
        worker.* = try std.Thread.spawn(.{}, RunAsyncBench, .{
            bfr_mngr,
            pfn_requests[(pfns_per_thread * thread_id)..][0..pfns_per_thread],
            verify_served_pages,
            verify_shift,
            thread_id,
            &start_signal,
            &bench_success,
            max_in_flight,
        });
    }

    const t_start = timer.read();

    @atomicStore(bool, &start_signal, true, .monotonic);
    RunAsyncBench(
        bfr_mngr,
        pfn_requests[(pfns_per_thread * (thread_count - 1))..],
        verify_served_pages,
        verify_shift,
        0,
        &start_signal,
        &bench_success,
        max_in_flight,
    );

    for (other_workers) |wrkr| wrkr.join();

    const t_end = timer.read();

    if (!@atomicLoad(bool, &bench_success, .monotonic)) return error.BenchmarkFailed;

    return t_end - t_start;
}

fn RunAsyncBench(
    bfr_mngr: anytype,
    pfn_requests: []u64,
    comptime verify_served_pages: bool,
    verify_shift: u6,
    thread_id: u64,
    start_signal: *bool,
    bench_success: *bool,
    comptime max_in_flight: u16,
) void {
    var in_flight_requests: [max_in_flight]?u64 = [_]?u64{null} ** max_in_flight;
    var in_flight_count: u64 = 0;

    while (!@atomicLoad(bool, start_signal, .monotonic)) {}

    for (pfn_requests) |pfn| {
        while (in_flight_count == max_in_flight) {
            RetryInflightRequests(
                bfr_mngr,
                thread_id,
                bench_success,
                max_in_flight,
                &in_flight_count,
                &in_flight_requests,
                verify_served_pages,
                verify_shift,
            );
        }

        const potential_page = bfr_mngr.PFNToPage(pfn, thread_id) catch {
            @atomicStore(bool, bench_success, false, .monotonic);
            return;
        };

        if (potential_page) |page| {
            if (!PageOk(verify_served_pages, @ptrCast(page), pfn, verify_shift, bench_success)) return;

            bfr_mngr.DecrementPinCount(pfn);
        } else {
            for (&in_flight_requests) |*cand_slot| {
                if (cand_slot.* == null) {
                    cand_slot.* = pfn;
                    break;
                }
            } else {
                unreachable;
            }
            in_flight_count += 1;
            continue;
        }
    }

    while (in_flight_count != 0) {
        RetryInflightRequests(
            bfr_mngr,
            thread_id,
            bench_success,
            max_in_flight,
            &in_flight_count,
            &in_flight_requests,
            verify_served_pages,
            verify_shift,
        );
    }
}

fn RunBench(
    bfr_mngr: anytype,
    pfn_requests: []u64,
    comptime verify_served_pages: bool,
    verify_shift: u6,
    thread_id: u64,
    start_signal: *bool,
    bench_success: *bool,
) void {
    while (!@atomicLoad(bool, start_signal, .monotonic)) {}

    for (pfn_requests) |pfn| {
        const page = bfr_mngr.PFNToPage(pfn, thread_id) catch {
            @atomicStore(bool, bench_success, false, .monotonic);
            return;
        };
        if (verify_served_pages) {
            const first_bytes: *u64 = @ptrCast(page);
            if (first_bytes.* != pfn << verify_shift) {
                @atomicStore(bool, bench_success, false, .monotonic);
                return;
            }
        }
        bfr_mngr.DecrementPinCount(pfn);
    }
}

inline fn PageOk(comptime do_verification: bool, mem: *u64, pfn: u64, verify_shift: u6, success_signal: *bool) bool {
    if (do_verification) {
        if (mem.* != pfn << verify_shift) {
            @atomicStore(bool, success_signal, false, .monotonic);
            return false;
        }
    }
    return true;
}

inline fn RetryInflightRequests(
    bfr_mngr: anytype,
    thread_id: u64,
    bench_success: *bool,
    comptime max_in_flight: u16,
    in_flight_count: *u64,
    in_flight_requests: *[max_in_flight]?u64,
    comptime verify_served_pages: bool,
    verify_shift: u6,
) void {
    for (in_flight_requests) |*cand| {
        const pfn = cand.* orelse continue;

        const potential_page = bfr_mngr.PFNToPage(pfn, thread_id) catch {
            @atomicStore(bool, bench_success, false, .monotonic);
            return;
        };

        if (potential_page) |page| {
            if (!PageOk(verify_served_pages, @ptrCast(page), pfn, verify_shift, bench_success)) return;

            bfr_mngr.DecrementPinCount(pfn);
            in_flight_count.* -= 1;
            cand.* = null;
        }
    }
}

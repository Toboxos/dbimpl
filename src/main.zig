const std = @import("std");

const bench = @import("benchmark.zig");

const Scenario = struct {
    mem_capacity: u64,
    disk_capacity: u64,
    theta: f64,
    request_count: u64,
};

pub fn main(init: std.process.Init) !void {
    // NOTE: Feel free to change these based on your system, what you implemented etc.
    const file_path = "bfr_mngr_file";
    const mem_capacity = 1 << 30;
    const thread_count = 16;
    const implemented_variants: enum { OnlySingleThreaded, MultiThreaded, MTAsync } = .OnlySingleThreaded;
    const verify = true;
    const total_request_count = 1 << 24;

    const page_size = 1 << 12;
    const theta_high = 2;
    const theta_low = 0.5;

    const low_mem_capacity = mem_capacity >> 3;

    const disk_capacity_high = low_mem_capacity << 3;
    const disk_capacity_low = mem_capacity << 1;
    const disk_capacity_no_io = mem_capacity;

    const request_count_no_io = total_request_count;
    const request_count_low_io = total_request_count >> 3;
    const request_count_high_io = total_request_count >> 5;

    const scenarios = [_]Scenario{
        .{ .mem_capacity = mem_capacity, .disk_capacity = disk_capacity_no_io, .theta = theta_high, .request_count = request_count_no_io },
        .{ .mem_capacity = mem_capacity, .disk_capacity = disk_capacity_no_io, .theta = theta_low, .request_count = request_count_no_io },

        .{ .mem_capacity = mem_capacity, .disk_capacity = disk_capacity_low, .theta = theta_high, .request_count = request_count_low_io },
        .{ .mem_capacity = mem_capacity, .disk_capacity = disk_capacity_low, .theta = theta_low, .request_count = request_count_low_io },

        .{ .mem_capacity = low_mem_capacity, .disk_capacity = disk_capacity_high, .theta = theta_high, .request_count = request_count_high_io },
        .{ .mem_capacity = low_mem_capacity, .disk_capacity = disk_capacity_high, .theta = theta_low, .request_count = request_count_high_io },
    };

    const bench_types = switch (implemented_variants) {
        .OnlySingleThreaded => [_]bench.BenchType{.SingleThreadedSync},
        .MultiThreaded => [_]bench.BenchType{ .SingleThreadedSync, .{ .MultiThreadedSync = .{ .thread_count = thread_count } } },
        .MTAsync => [_]bench.BenchType{
            .SingleThreadedSync,
            .{ .MultiThreadedSync = .{ .thread_count = thread_count } },
            .{ .MultiThreadedAsync = .{ .thread_count = thread_count } },
        },
    };

    inline for (scenarios) |scenario| {
        inline for (bench_types) |bench_type| {
            _ = try bench.RunBenchmark(
                scenario.mem_capacity,
                scenario.disk_capacity,
                page_size,
                bench_type,
                verify,
                scenario.theta,
                scenario.request_count,
                file_path,
                init.io
            );
        }
    }
}

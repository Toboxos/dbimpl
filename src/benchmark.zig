const std = @import("std");
const zbench = @import("zbench");
const BufferManager = @import("buffer_manager.zig").BufferManager;
const Page = @import("buffer_manager.zig").Page;

var bm: BufferManager = .{};
var setup_done = false;

/// Setup pages for benchmarks
fn setupPages(allocator: std.mem.Allocator, num_pages: usize) ![]u64 {
    const page_ids = try allocator.alloc(u64, num_pages);
    for (page_ids) |*pfn| {
        const result = try bm.allocPageFrame();
        pfn.* = result.pfn;
        bm.decrementPinCount(result.pfn);
    }
    return page_ids;
}

/// Benchmark: Sequential page access (simulates table scan)
fn benchSequentialAccess(allocator: std.mem.Allocator) void {
    const page_ids = setupPages(allocator, 50) catch return;
    defer allocator.free(page_ids);

    for (page_ids) |pfn| {
        const page = bm.pfnToPage(pfn) catch continue;
        var sum: u64 = 0;
        for (page.mem) |byte| {
            sum +%= byte;
        }
        std.mem.doNotOptimizeAway(&sum);
        bm.decrementPinCount(pfn);
    }
}

/// Benchmark: Random access with hot pages (80/20 distribution)
fn benchRandomAccess(allocator: std.mem.Allocator) void {
    const page_ids = setupPages(allocator, 50) catch return;
    defer allocator.free(page_ids);

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const hot_count = page_ids.len / 5;

    // Do 100 random accesses
    for (0..100) |_| {
        const is_hot = random.float(f64) < 0.8;
        const pfn = if (is_hot)
            page_ids[random.intRangeAtMost(usize, 0, hot_count - 1)]
        else
            page_ids[random.intRangeAtMost(usize, 0, page_ids.len - 1)];

        const page = bm.pfnToPage(pfn) catch continue;
        _ = page.mem[0];
        bm.decrementPinCount(pfn);
    }
}

/// Benchmark: Page allocation
fn benchPageAllocation(allocator: std.mem.Allocator) void {
    _ = allocator;
    const result = bm.allocPageFrame() catch return;
    bm.decrementPinCount(result.pfn);
}

/// Benchmark: Page write (mark dirty + read back)
fn benchPageWrite(allocator: std.mem.Allocator) void {
    _ = allocator;
    const result = bm.allocPageFrame() catch return;
    const pfn = result.pfn;

    // Write pattern
    @memset(&result.page.mem, 0xAB);
    bm.markDirty(pfn);
    bm.decrementPinCount(pfn);

    // Read back
    const page = bm.pfnToPage(pfn) catch return;
    _ = page.mem[0];
    bm.decrementPinCount(pfn);
}

/// Benchmark: Index lookup simulation (3-level traversal)
fn benchIndexLookup(allocator: std.mem.Allocator) void {
    _ = allocator;
    // Setup: root + 4 internal + 16 leaf = 21 pages
    const root = bm.allocPageFrame() catch return;
    bm.decrementPinCount(root.pfn);

    var internal_nodes: [4]u64 = undefined;
    for (&internal_nodes) |*pfn| {
        const result = bm.allocPageFrame() catch return;
        pfn.* = result.pfn;
        bm.decrementPinCount(result.pfn);
    }

    var leaf_nodes: [16]u64 = undefined;
    for (&leaf_nodes) |*pfn| {
        const result = bm.allocPageFrame() catch return;
        pfn.* = result.pfn;
        bm.decrementPinCount(result.pfn);
    }

    // Perform one traversal
    var prng = std.Random.DefaultPrng.init(123);
    const random = prng.random();

    _ = bm.pfnToPage(root.pfn) catch return;
    bm.decrementPinCount(root.pfn);

    const internal_idx = random.intRangeAtMost(usize, 0, 3);
    _ = bm.pfnToPage(internal_nodes[internal_idx]) catch return;
    bm.decrementPinCount(internal_nodes[internal_idx]);

    const leaf_idx = random.intRangeAtMost(usize, 0, 15);
    const leaf = bm.pfnToPage(leaf_nodes[leaf_idx]) catch return;
    _ = leaf.mem[0];
    bm.decrementPinCount(leaf_nodes[leaf_idx]);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout = std.Io.File.stdout();
    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{});
    defer bench.deinit();

    try bench.add("Sequential Access (50 pages)", benchSequentialAccess, .{});
    try bench.add("Random Access (80/20, 100 ops)", benchRandomAccess, .{});
    try bench.add("Page Allocation", benchPageAllocation, .{});
    try bench.add("Page Write + Read", benchPageWrite, .{});
    try bench.add("Index Lookup (3-level)", benchIndexLookup, .{});

    try stdout.writeStreamingAll(io, "\n=== Buffer Manager Benchmark ===\n\n");
    try bench.run(io, stdout);
}

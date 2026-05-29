const std = @import("std");
const BufferManager = @import("buffer_manager.zig").BufferManager;
const Page = @import("buffer_manager.zig").Page;

const WorkloadStats = struct {
    page_hits: u64 = 0,
    page_misses: u64 = 0,
    page_evictions: u64 = 0,
    pages_allocated: u64 = 0,
    pages_written: u64 = 0,

    pub fn printStats(self: WorkloadStats, workload_name: []const u8) void {
        const total_accesses = self.page_hits + self.page_misses;
        const hit_rate = if (total_accesses > 0)
            @as(f64, @floatFromInt(self.page_hits)) / @as(f64, @floatFromInt(total_accesses)) * 100.0
            else 0.0;

        std.debug.print("\n=== {s} ===\n", .{workload_name});
        std.debug.print("Pages allocated: {}\n", .{self.pages_allocated});
        std.debug.print("Page hits: {}\n", .{self.page_hits});
        std.debug.print("Page misses: {}\n", .{self.page_misses});
        std.debug.print("Hit rate: {d:.2}%\n", .{hit_rate});
        std.debug.print("Page evictions: {}\n", .{self.page_evictions});
        std.debug.print("Pages written: {}\n", .{self.pages_written});
    }
};

/// Simulates a table scan - sequential access of many pages
/// This is what happens during a full table scan or sequential index scan
pub fn benchmarkTableScan(bm: *BufferManager, num_pages: u64) !WorkloadStats {
    var stats = WorkloadStats{};
    var page_ids = std.ArrayList(u64).init(std.heap.page_allocator);
    defer page_ids.deinit();

    // Phase 1: Create a "table" by allocating sequential pages
    std.debug.print("\n[Table Scan] Creating table with {} pages...\n", .{num_pages});
    for (0..num_pages) |i| {
        const result = try bm.allocPageFrame();
        try page_ids.append(result.pfn);
        stats.pages_allocated += 1;

        // Write some data to simulate table records
        const page_data: []u8 = &result.page.mem;
        for (page_data, 0..) |*byte, j| {
            byte.* = @intCast((i + j) % 256);
        }
        bm.markDirty(result.pfn);
        bm.decrementPinCount(result.pfn);
    }

    // Phase 2: Sequential scan - read all pages in order (simulates SELECT *)
    std.debug.print("[Table Scan] Performing sequential scan...\n", .{});
    for (page_ids.items) |pfn| {
        const page = bm.pfnToPage(pfn) catch {
            stats.page_misses += 1;
            continue;
        };
        stats.page_hits += 1;

        // Simulate reading data
        var sum: u64 = 0;
        for (page.mem) |byte| {
            sum +%= byte;
        }
        _ = sum; // Use the sum to prevent optimization

        bm.decrementPinCount(pfn);
    }

    // Phase 3: Scan again to test caching behavior
    std.debug.print("[Table Scan] Second scan (testing buffer pool)...\n", .{});
    for (page_ids.items) |pfn| {
        const page = bm.pfnToPage(pfn) catch {
            stats.page_misses += 1;
            continue;
        };
        stats.page_hits += 1;
        bm.decrementPinCount(pfn);
    }

    return stats;
}

/// Simulates B-tree index lookups - root page is hot, then traverse down
/// Models point queries that follow index structure
pub fn benchmarkIndexLookups(bm: *BufferManager, num_queries: u64) !WorkloadStats {
    var stats = WorkloadStats{};

    // Create a simple 3-level index structure
    // Root -> 4 internal nodes -> 16 leaf nodes
    std.debug.print("\n[Index Lookups] Creating index structure...\n", .{});

    const root_result = try bm.allocPageFrame();
    const root_pfn = root_result.pfn;
    stats.pages_allocated += 1;
    bm.decrementPinCount(root_pfn);

    var internal_nodes: [4]u64 = undefined;
    for (&internal_nodes) |*pfn| {
        const result = try bm.allocPageFrame();
        pfn.* = result.pfn;
        stats.pages_allocated += 1;
        bm.decrementPinCount(result.pfn);
    }

    var leaf_nodes: [16]u64 = undefined;
    for (&leaf_nodes) |*pfn| {
        const result = try bm.allocPageFrame();
        pfn.* = result.pfn;
        stats.pages_allocated += 1;
        bm.decrementPinCount(result.pfn);
    }

    // Perform index lookups
    std.debug.print("[Index Lookups] Running {} point queries...\n", .{num_queries});
    var prng = std.rand.DefaultPrng.init(42);
    const rand = prng.random();

    for (0..num_queries) |_| {
        // Every lookup starts at root (hot page!)
        const root = bm.pfnToPage(root_pfn) catch {
            stats.page_misses += 1;
            continue;
        };
        stats.page_hits += 1;
        bm.decrementPinCount(root_pfn);

        // Traverse to internal node
        const internal_idx = rand.intRangeAtMost(usize, 0, 3);
        const internal = bm.pfnToPage(internal_nodes[internal_idx]) catch {
            stats.page_misses += 1;
            continue;
        };
        stats.page_hits += 1;
        bm.decrementPinCount(internal_nodes[internal_idx]);

        // Traverse to leaf
        const leaf_idx = rand.intRangeAtMost(usize, 0, 15);
        const leaf = bm.pfnToPage(leaf_nodes[leaf_idx]) catch {
            stats.page_misses += 1;
            continue;
        };
        stats.page_hits += 1;

        // Simulate reading the data
        _ = leaf.mem[0];

        bm.decrementPinCount(leaf_nodes[leaf_idx]);
    }

    return stats;
}

/// Simulates a mixed workload with hot pages (80/20 rule)
/// 80% of accesses go to 20% of pages
pub fn benchmarkHotPages(bm: *BufferManager, num_pages: u64, num_accesses: u64) !WorkloadStats {
    var stats = WorkloadStats{};
    var page_ids = std.ArrayList(u64).init(std.heap.page_allocator);
    defer page_ids.deinit();

    std.debug.print("\n[Hot Pages] Creating {} pages...\n", .{num_pages});
    for (0..num_pages) |_| {
        const result = try bm.allocPageFrame();
        try page_ids.append(result.pfn);
        stats.pages_allocated += 1;
        bm.decrementPinCount(result.pfn);
    }

    // 80/20 rule: 20% of pages get 80% of traffic
    const hot_page_count = num_pages / 5;
    const hot_access_ratio: f64 = 0.8;

    std.debug.print("[Hot Pages] Running {} accesses (80/20 distribution)...\n", .{num_accesses});
    var prng = std.rand.DefaultPrng.init(123);
    const rand = prng.random();

    for (0..num_accesses) |_| {
        const is_hot_access = rand.float(f64) < hot_access_ratio;
        const pfn = if (is_hot_access)
            page_ids.items[rand.intRangeAtMost(usize, 0, hot_page_count - 1)]
        else
            page_ids.items[rand.intRangeAtMost(usize, 0, page_ids.items.len - 1)];

        const page = bm.pfnToPage(pfn) catch {
            stats.page_misses += 1;
            continue;
        };
        stats.page_hits += 1;

        // 30% chance to write
        if (rand.intRangeAtMost(u8, 0, 9) < 3) {
            page.mem[0] = rand.int(u8);
            bm.markDirty(pfn);
        }

        bm.decrementPinCount(pfn);
    }

    return stats;
}

/// Simulates OLTP workload: mix of small reads and writes with transaction-like patterns
pub fn benchmarkOLTP(bm: *BufferManager, num_transactions: u64) !WorkloadStats {
    var stats = WorkloadStats{};
    var page_ids = std.ArrayList(u64).init(std.heap.page_allocator);
    defer page_ids.deinit();

    // Create some initial pages (like table pages)
    std.debug.print("\n[OLTP] Setting up {} data pages...\n", .{50});
    for (0..50) |_| {
        const result = try bm.allocPageFrame();
        try page_ids.append(result.pfn);
        stats.pages_allocated += 1;
        bm.decrementPinCount(result.pfn);
    }

    std.debug.print("[OLTP] Running {} transactions...\n", .{num_transactions});
    var prng = std.rand.DefaultPrng.init(456);
    const rand = prng.random();

    for (0..num_transactions) |_| {
        // Each transaction touches 2-5 pages (typical OLTP pattern)
        const pages_per_txn = rand.intRangeAtMost(usize, 2, 5);

        for (0..pages_per_txn) |_| {
            const idx = rand.intRangeAtMost(usize, 0, page_ids.items.len - 1);
            const pfn = page_ids.items[idx];

            const page = bm.pfnToPage(pfn) catch {
                stats.page_misses += 1;
                continue;
            };
            stats.page_hits += 1;

            // 50% chance to modify (UPDATE/INSERT)
            if (rand.boolean()) {
                const offset = rand.intRangeAtMost(usize, 0, page.mem.len - 8);
                page.mem[offset] = rand.int(u8);
                bm.markDirty(pfn);
            }

            bm.decrementPinCount(pfn);
        }
    }

    return stats;
}

pub fn main() !void {
    std.debug.print("=== Buffer Manager Benchmark ===\n", .{});
    std.debug.print("Simulating realistic database workloads\n", .{});

    var bm = BufferManager{};

    // Benchmark 1: Table Scan (tests sequential access and buffer pool pressure)
    const scan_stats = try benchmarkTableScan(&bm, 200);
    scan_stats.printStats("Table Scan Results");

    // Benchmark 2: Index Lookups (tests hot page behavior)
    const index_stats = try benchmarkIndexLookups(&bm, 1000);
    index_stats.printStats("Index Lookup Results");

    // Benchmark 3: Hot Pages (tests 80/20 rule)
    const hot_stats = try benchmarkHotPages(&bm, 100, 2000);
    hot_stats.printStats("Hot Pages Results");

    // Benchmark 4: OLTP (tests mixed read/write)
    const oltp_stats = try benchmarkOLTP(&bm, 500);
    oltp_stats.printStats("OLTP Workload Results");

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}

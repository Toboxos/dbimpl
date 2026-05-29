const std = @import("std");
const BufferManager = @import("buffer_manager").BufferManager;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var bm = BufferManager{};

    // try my_test(&bm);
    try run_tests(&bm, io);
    // _ = io;
}

fn my_test(bm: *BufferManager) !void {
    for (0..16) |i| {
        const alloc = try bm.allocPageFrame();
        alloc.page.mem[0] = @intCast(i);

        bm.decrementPinCount(alloc.pfn);
    }
}

fn run_tests(bm: *BufferManager, io: std.Io) !void {
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, "=== Buffer Manager Tests ===\n");

    // Test 1: Allocate a page
    try stdout.writeStreamingAll(io, "\nTest 1: Allocate a page\n");
    const alloc1 = try bm.allocPageFrame();
    std.debug.print("  Allocated page with PFN: {}\n", .{alloc1.pfn});

    // Test 2: Allocate another page
    try stdout.writeStreamingAll(io, "\nTest 2: Allocate second page\n");
    const alloc2 = try bm.allocPageFrame();
    std.debug.print("  Allocated page with PFN: {}\n", .{alloc2.pfn});

    // Test 3: Mark page as dirty
    try stdout.writeStreamingAll(io, "\nTest 3: Mark page as dirty\n");
    bm.markDirty(alloc1.pfn);
    std.debug.print("  Marked PFN {} as dirty\n", .{alloc1.pfn});

    // Test 4: Try to free a page with pin count > 0 (should fail)
    try stdout.writeStreamingAll(io, "\nTest 4: Try to free page with pin count > 0 (should fail)\n");
    if (bm.freePageFrame(alloc1.pfn)) {
        try stdout.writeStreamingAll(io, "  ERROR: Should have failed!\n");
    } else |err| {
        std.debug.print("  Got expected error: {}\n", .{err});
    }

    // Test 5: Decrement pin count
    try stdout.writeStreamingAll(io, "\nTest 5: Decrement pin count\n");
    bm.decrementPinCount(alloc1.pfn);
    std.debug.print("  Decremented pin count for PFN {}\n", .{alloc1.pfn});

    // Test 6: Free page with pin count = 0 (should succeed)
    try stdout.writeStreamingAll(io, "\nTest 6: Free page with pin count = 0 (should succeed)\n");
    try bm.freePageFrame(alloc1.pfn);
    std.debug.print("  Successfully freed PFN {}\n", .{alloc1.pfn});

    // Test 7: Allocate pages until frames run out (should fail on 9th allocation)
    try stdout.writeStreamingAll(io, "\nTest 7: Allocate pages until frames run out\n");
    var pfns: [10]u64 = undefined;
    var allocated_count: usize = 0;
    for (0..10) |i| {
        if (bm.allocPageFrame()) |alloc| {
            pfns[i] = alloc.pfn;
            allocated_count = i + 1;
            std.debug.print("  Allocated PFN: {}\n", .{alloc.pfn});
        } else |err| {
            std.debug.print("  Failed to allocate page {} (expected): {}\n", .{ i + 1, err });
            break;
        }
    }

    // Test 8: Unpin one page and allocate again (should succeed via eviction)
    try stdout.writeStreamingAll(io, "\nTest 8: Unpin one page and allocate again\n");
    bm.decrementPinCount(pfns[0]);
    std.debug.print("  Unpinned PFN {}\n", .{pfns[0]});
    const new_alloc = try bm.allocPageFrame();
    std.debug.print("  Successfully allocated PFN {} (evicted a frame)\n", .{new_alloc.pfn});
    pfns[allocated_count] = new_alloc.pfn;
    allocated_count += 1;

    // Test 9: Cleanup - decrement all pin counts
    try stdout.writeStreamingAll(io, "\nTest 9: Cleanup - decrement all pin counts\n");
    for (pfns[0..allocated_count]) |pfn| {
        bm.decrementPinCount(pfn);
    }
    try stdout.writeStreamingAll(io, "  All pin counts decremented\n");

    // Test 10: Reload a page that's in memory
    try stdout.writeStreamingAll(io, "\nTest 10: Reload a page that's in memory\n");
    const test_alloc = try bm.allocPageFrame();
    const test_pfn = test_alloc.pfn;
    // Write some data to the page
    @memset(&test_alloc.page.mem, 0xAB);
    bm.decrementPinCount(test_pfn);
    // Reload the page
    const reloaded = try bm.pfnToPage(test_pfn);
    std.debug.print("  Successfully reloaded PFN {}, first byte: 0x{X}\n", .{ test_pfn, reloaded.mem[0] });
    bm.decrementPinCount(test_pfn);

    // Test 11: Try to reload an evicted page (will fail - disk not implemented)
    try stdout.writeStreamingAll(io, "\nTest 11: Try to reload an evicted page\n");
    const evict_alloc = try bm.allocPageFrame();
    const evict_pfn = evict_alloc.pfn;
    @memset(&evict_alloc.page.mem, 0xCD);
    std.debug.print("  Allocated PFN {} and wrote 0xCD pattern\n", .{evict_pfn});
    bm.decrementPinCount(evict_pfn);

    // Allocate enough pages to evict it
    var evict_pfns: [8]u64 = undefined;
    for (0..8) |i| {
        const alloc = try bm.allocPageFrame();
        evict_pfns[i] = alloc.pfn;
        bm.decrementPinCount(alloc.pfn);
    }
    std.debug.print("  Allocated 8 more pages, PFN {} should be evicted\n", .{evict_pfn});

    // Try to reload the evicted page
    if (bm.pfnToPage(evict_pfn)) |page| {
        std.debug.print("  Reloaded evicted page, first byte: 0x{X}\n", .{page.mem[0]});
        bm.decrementPinCount(evict_pfn);
    } else |err| {
        std.debug.print("  Got expected error (disk not implemented): {}\n", .{err});
    }

    // Cleanup
    for (evict_pfns) |pfn| {
        bm.decrementPinCount(pfn);
    }

    // Test 12: Try to reload a non-existent PFN
    try stdout.writeStreamingAll(io, "\nTest 12: Try to reload non-existent PFN\n");
    const fake_pfn: u64 = 999999;
    if (bm.pfnToPage(fake_pfn)) |_| {
        try stdout.writeStreamingAll(io, "  ERROR: Should have failed!\n");
    } else |err| {
        std.debug.print("  Got expected error: {}\n", .{err});
    }

    // Test 13: Try to reload a freed PFN
    try stdout.writeStreamingAll(io, "\nTest 13: Try to reload a freed PFN\n");
    const to_free = try bm.allocPageFrame();
    const freed_pfn = to_free.pfn;
    bm.decrementPinCount(freed_pfn);
    try bm.freePageFrame(freed_pfn);
    std.debug.print("  Freed PFN {}\n", .{freed_pfn});

    if (bm.pfnToPage(freed_pfn)) |_| {
        try stdout.writeStreamingAll(io, "  ERROR: Should have failed!\n");
    } else |err| {
        std.debug.print("  Got expected error: {}\n", .{err});
    }

    try stdout.writeStreamingAll(io, "\n=== All tests completed ===\n");
}

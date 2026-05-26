const std = @import("std");
const BufferManager = @import("buffer_manager").BufferManager;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout = std.Io.File.stdout();

    var bm = BufferManager{};

    try stdout.writeStreamingAll(io, "=== Buffer Manager Tests ===\n");

    // Test 1: Allocate a page
    try stdout.writeStreamingAll(io,"\nTest 1: Allocate a page\n");
    const alloc1 = try bm.allocPageFrame();
    std.debug.print("  Allocated page with PFN: {}\n", .{alloc1.pfn});

    // Test 2: Allocate another page
    try stdout.writeStreamingAll(io,"\nTest 2: Allocate second page\n");
    const alloc2 = try bm.allocPageFrame();
    std.debug.print("  Allocated page with PFN: {}\n", .{alloc2.pfn});

    // Test 3: Mark page as dirty
    try stdout.writeStreamingAll(io,"\nTest 3: Mark page as dirty\n");
    bm.markDirty(alloc1.pfn);
    std.debug.print("  Marked PFN {} as dirty\n", .{alloc1.pfn});

    // Test 4: Try to free a page with pin count > 0 (should fail)
    try stdout.writeStreamingAll(io,"\nTest 4: Try to free page with pin count > 0 (should fail)\n");
    if (bm.freePageFrame(alloc1.pfn)) {
        try stdout.writeStreamingAll(io,"  ERROR: Should have failed!\n");
    } else |err| {
        std.debug.print("  Got expected error: {}\n", .{err});
    }

    // Test 5: Decrement pin count
    try stdout.writeStreamingAll(io,"\nTest 5: Decrement pin count\n");
    bm.decrementPinCount(alloc1.pfn);
    std.debug.print("  Decremented pin count for PFN {}\n", .{alloc1.pfn});

    // Test 6: Free page with pin count = 0 (should succeed)
    try stdout.writeStreamingAll(io,"\nTest 6: Free page with pin count = 0 (should succeed)\n");
    try bm.freePageFrame(alloc1.pfn);
    std.debug.print("  Successfully freed PFN {}\n", .{alloc1.pfn});

    // Test 7: Allocate pages until frames run out (should fail on 9th allocation)
    try stdout.writeStreamingAll(io,"\nTest 7: Allocate pages until frames run out\n");
    var pfns: [10]u64 = undefined;
    var allocated_count: usize = 0;
    for (0..10) |i| {
        if (bm.allocPageFrame()) |alloc| {
            pfns[i] = alloc.pfn;
            allocated_count = i + 1;
            std.debug.print("  Allocated PFN: {}\n", .{alloc.pfn});
        } else |err| {
            std.debug.print("  Failed to allocate page {} (expected): {}\n", .{i + 1, err});
            break;
        }
    }

    // Test 8: Unpin one page and allocate again (should succeed via eviction)
    try stdout.writeStreamingAll(io,"\nTest 8: Unpin one page and allocate again\n");
    bm.decrementPinCount(pfns[0]);
    std.debug.print("  Unpinned PFN {}\n", .{pfns[0]});
    const new_alloc = try bm.allocPageFrame();
    std.debug.print("  Successfully allocated PFN {} (evicted a frame)\n", .{new_alloc.pfn});
    pfns[allocated_count] = new_alloc.pfn;
    allocated_count += 1;

    // Test 9: Cleanup - decrement all pin counts
    try stdout.writeStreamingAll(io,"\nTest 9: Cleanup - decrement all pin counts\n");
    for (pfns[0..allocated_count]) |pfn| {
        bm.decrementPinCount(pfn);
    }
    try stdout.writeStreamingAll(io,"  All pin counts decremented\n");

    try stdout.writeStreamingAll(io,"\n=== All tests completed ===\n");
}

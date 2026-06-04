const std = @import("std");

pub const FrameMetadata = packed struct {
    pfn: u64,
    pin_count: u8,
    dirty: u1,
    access: u1,
};

pub fn FramePool(comptime page_size: u64, comptime n_frames: u64) type {
    return struct {
        pub const Page = struct { mem: [page_size]u8 align(page_size) };

        /// Number of frames this pool offers.
        pub const num_frames: u64 = n_frames;

        /// Memory region for loaded pages
        frames: []Page,  

        /// Unmanaged Hashtable (linear layout, no allocations) for pfn -> index lookup
        frames_assignment: std.hash_map.AutoHashMapUnmanaged(u64, u64),
    
        // Frame metadata
        frames_metadata: []FrameMetadata,

        pub fn Init(alloc: std.mem.Allocator) !@This() {
            const frames = try alloc.alignedAlloc(Page, null, n_frames); 
            errdefer alloc.free(frames);

            const frames_metadata = try alloc.alloc(FrameMetadata, n_frames);
            errdefer alloc.free(frames_metadata);

            var frames_assignment: std.hash_map.AutoHashMapUnmanaged(u64, u64) = .empty; 
            try frames_assignment.ensureTotalCapacity(alloc, n_frames);
            errdefer frames_assignment.deinit(alloc);

            @memset(frames_metadata, .{.pfn = 0, .pin_count = 0, .dirty = 0, .access = 0});

            const instance = @This(){
               .frames = frames,
               .frames_assignment = frames_assignment,
               .frames_metadata = frames_metadata
            };
            return instance;
        }

        pub fn Deinit(self: *@This(), alloc: std.mem.Allocator) void {
           alloc.free(self.frames);
           alloc.free(self.frames_metadata);

           self.frames_assignment.deinit(alloc);
        }

        pub fn resolveFrame(self: *@This(), pfn: u64) ?u64 {
            return self.frames_assignment.get(pfn);
        }

        pub fn count(self: *@This()) u32 {
            return self.frames_assignment.count();
        }

        pub fn isFull(self: *@This()) bool {
            return self.count() >= num_frames;
        }

        pub fn assignFrame(self: *@This(), pfn: u64, slot: u64) void {
            self.frames_assignment.putAssumeCapacity(pfn, slot);
        }

        pub fn freeFrame(self: *@This(), pfn: u64) bool {
            return self.frames_assignment.remove(pfn);
        }
    };
}

test "FrameMetdata is 2 bytes" {
    try std.testing.expectEqual(2, @sizeOf(FrameMetadata));
}

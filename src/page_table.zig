const std = @import("std");

pub const FrameMetadata = packed struct {
    pfn: u64,
    pin_count: u8,
    dirty: u1,
    access: u1,
    valid: u1,
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

            // capacity is 25% larger so hashtable is only used up to ~80%
            const capacity = @trunc(@as(f64, n_frames) * 1.25); 
            var frames_assignment: std.hash_map.AutoHashMapUnmanaged(u64, u64) = .empty; 
            try frames_assignment.ensureTotalCapacity(alloc, capacity);
            errdefer frames_assignment.deinit(alloc);

            @memset(frames_metadata, .{.pfn = 0, .pin_count = 0, .dirty = 0, .access = 0, .valid = 0});

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

        /// :param hint: Hint where to start linear scan
        pub fn findEmptyFrame(self: *@This(), hint: u64) ?u64 {
            for (self.frames_metadata[hint..], hint..) |*meta, i| {
                if( meta.valid == 0 ) return i;
            } 
            for( self.frames_metadata[0..hint], 0..) |*meta, i| {
                if( meta.valid == 0 ) return i;
            } 
            return null;
        }

        pub fn assignFrame(self: *@This(), pfn: u64, slot: u64) void {
            self.frames_assignment.putAssumeCapacity(pfn, slot);
        }

        pub fn freeFrame(self: *@This(), pfn: u64) bool {
            return self.frames_assignment.remove(pfn);
        }
    };
}


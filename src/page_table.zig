const std = @import("std");

pub const FrameMetadata = packed struct {
    pin_count: u8,
    dirty: u1,
};

pub fn FramePool(comptime page_size: u64, comptime n_frames: u64) type {
    return struct {
        pub const Page = struct { mem: [page_size]u8 align(page_size) };

        /// Number of frames this pool offers.
        pub const num_frames: u64 = n_frames;

        /// Memory region for loaded pages
        frames: []Page,  

        /// Holds the assigned PFN for each frame slot (by index).
        /// 0 = not assigned (special case)
        frames_assignment: []u64,

        frames_metadata: []FrameMetadata,

        pub fn Init(alloc: std.mem.Allocator) !@This() {
            const frames = try alloc.alignedAlloc(Page, null, n_frames); 
            errdefer alloc.free(frames);

            const frames_assignment = try alloc.alloc(u64, n_frames);
            errdefer alloc.free(frames_assignment);

            const frames_metadata = try alloc.alloc(FrameMetadata, n_frames);
            errdefer alloc.free(frames_metadata);

            @memset(frames_assignment, 0);
            @memset(frames_metadata, .{.pin_count = 0, .dirty = 0});

            const instance = @This(){
               .frames = frames,
               .frames_assignment = frames_assignment,
               .frames_metadata = frames_metadata
            };
            return instance;
        }

        pub fn Deinit(self: *@This(), alloc: std.mem.Allocator) void {
           alloc.free(self.frames);
           alloc.free(self.frames_assignment);
           alloc.free(self.frames_metadata);
        }

        pub fn resolveFrame(self: *@This(), pfn: u64) ?u64 {
            return std.mem.findScalar(u64, self.frames_assignment, pfn);
        }
    };
}

test "FrameMetdata is 2 bytes" {
    try std.testing.expectEqual(2, @sizeOf(FrameMetadata));
}

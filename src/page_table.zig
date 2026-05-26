const std = @import("std");

pub const page_size = 1 << 12;
pub const Page = struct { mem: [page_size]u8 align(page_size) };

pub const FrameMetadata = packed struct {
    pin_count: u8,
    dirty: u1,
};

pub const FramePool = struct {
    /// Number of frames this pool offers.O
    /// Fixed for now, maybe runtime in future.
    pub const num_frames: u8 = 8;

    /// Memory region for loaded pages
    frames: [num_frames]Page align(@sizeOf(Page)) = [_]Page{.{ .mem = undefined }} ** num_frames,

    /// Holds the assigned PFN for each frame slot (by index).
    /// Used for fast lookup.
    /// 0 = not assigned (special case)
    frames_assignment: [num_frames]u64 align(8) = .{0} ** num_frames,

    frames_metadata: [num_frames]FrameMetadata align(2) = [_]FrameMetadata{.{
        .pin_count = 0,
        .dirty = 0,
    }} ** num_frames,

    pub fn resolveFrame(self: *FramePool, pfn: u64) ?u8 {
        const index = std.mem.findScalar(u64, &self.frames_assignment, pfn);
        return if (index) |v| @intCast(v) else null;
    }
};

test "FrameMetdata is 2 bytes" {
    try std.testing.expectEqual(2, @sizeOf(FrameMetadata));
}

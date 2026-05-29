const PageTable = @import("page_table");
const std = @import("std");
pub const Page = PageTable.Page;

var threaded: std.Io.Threaded = .init_single_threaded;
const io = threaded.io();

pub const BufferManagerError = error{
    PageInUse,
    AllFramesInUse,
    PageNotFound,
};

pub const BufferManager = struct {
    frame_pool: PageTable.FramePool = .{},

    /// globally increasing counter thats used for enumerating new pages
    pfn_counter: u64 = 1,

    dir: std.Io.Dir = std.Io.Dir.cwd(),

    pub fn allocPageFrame(self: *BufferManager) !struct { pfn: u64, page: *Page } {
        const result = self.frame_pool.resolveFrame(0); // 0 = free frame
        const frame_index = result orelse try self.evictPage();

        const new_pfn = self.pfn_counter;
        self.pfn_counter += 1;

        @memset(&self.frame_pool.frames[frame_index].mem, 0);
        self.frame_pool.frames_metadata[frame_index] = .{
            .pin_count = 1,
            .dirty = 1,
        };
        self.frame_pool.frames_assignment[frame_index] = new_pfn;
        return .{
            .pfn = new_pfn,
            .page = &self.frame_pool.frames[frame_index],
        };
    }

    pub fn freePageFrame(self: *BufferManager, pfn: u64) !void {
        const result = self.frame_pool.resolveFrame(pfn);
        if (result) |frame_index| {
            if (self.frame_pool.frames_metadata[frame_index].pin_count > 0) {
                return error.PageInUse;
            }

            self.frame_pool.frames_assignment[frame_index] = 0;
        }

        var buf: [32]u8 = undefined;
        const filename = try std.fmt.bufPrint(&buf, "page_{x}", .{pfn});

        self.dir.deleteFile(io, filename) catch {};
    }

    pub fn pfnToPage(self: *BufferManager, pfn: u64) !*Page {
        const result = self.frame_pool.resolveFrame(pfn);
        if (result) |frame_index| {
            self.frame_pool.frames_metadata[frame_index].pin_count += 1;
            return &self.frame_pool.frames[frame_index];
        }

        const frame_index = try self.evictPage();

        var buf: [32]u8 = undefined;
        const filename = try std.fmt.bufPrint(&buf, "page_{x}", .{pfn});

        _ = try self.dir.readFile(io, filename, &self.frame_pool.frames[frame_index].mem);
        self.frame_pool.frames_assignment[frame_index] = pfn;
        self.frame_pool.frames_metadata[frame_index] = .{
            .pin_count = 1,
            .dirty = 0,
        };
        return &self.frame_pool.frames[frame_index];
    }

    pub fn markDirty(self: *BufferManager, pfn: u64) void {
        const result = self.frame_pool.resolveFrame(pfn);
        const frame_index = result orelse return;
        self.frame_pool.frames_metadata[frame_index].dirty = 1;
    }

    pub fn flushPage(self: *BufferManager, pfn: u64) !void {
        const frame_index = self.frame_pool.resolveFrame(pfn) orelse return error.PageNotFound;
        if (self.frame_pool.frames_metadata[frame_index].dirty == 0) {
            return;
        }
        return self.flushFrame(frame_index);
    }

    pub fn decrementPinCount(self: *BufferManager, pfn: u64) void {
        const result = self.frame_pool.resolveFrame(pfn);
        const frame_index = result orelse return;
        self.frame_pool.frames_metadata[frame_index].pin_count -= 1;
    }

    fn evictPage(self: *BufferManager) !u8 {
        const evict_index: u8 = try for (self.frame_pool.frames_metadata, 0..) |meta, i| {
            if (meta.pin_count == 0) break @as(u8, @intCast(i));
        } else null orelse error.AllFramesInUse;

        if (self.frame_pool.frames_metadata[evict_index].dirty == 1) {
            try self.flushFrame(evict_index);
        }

        self.frame_pool.frames_assignment[evict_index] = 0;
        return evict_index;
    }

    fn flushFrame(self: *BufferManager, frame_index: u8) !void {
        const pfn = self.frame_pool.frames_assignment[frame_index];

        var buf: [32]u8 = undefined;
        const filename = try std.fmt.bufPrint(&buf, "page_{x}", .{pfn});

        try self.dir.writeFile(io, .{
            .sub_path = filename,
            .data = &self.frame_pool.frames[frame_index].mem,
        });
    }
};

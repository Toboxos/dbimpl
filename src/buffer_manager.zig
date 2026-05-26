const PageTable = @import("page_table");
pub const Page = PageTable.Page;

pub const BufferManagerError = error{
    PageInUse,
    AllFramesInUse,
};

pub const BufferManager = struct {
    frame_pool: PageTable.FramePool = .{},

    /// globally increasing counter thats used for enumerating new pages
    pfn_counter: u64 = 1,

    pub fn init() void {}

    pub fn deinit() void {}

    pub fn allocPageFrame(self: *BufferManager) !struct { pfn: u64, page: *Page } {
        const result = self.frame_pool.resolveFrame(0); // 0 = free frame
        const frame_index = result orelse try self.evictPage();

        const new_pfn = self.pfn_counter;
        self.pfn_counter += 1;

        @memset(&self.frame_pool.frames[frame_index].mem, 0);
        self.frame_pool.frames_metadata[frame_index] = .{
            .pin_count = 1,
            .dirty = 0,
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

        // todo: erase disk
    }

    pub fn pfnToPage(self: *BufferManager, pfn: u64) !*Page {
        const result = self.frame_pool.resolveFrame(pfn);
        if (result) |frame_index| {
            self.frame_pool.frames_metadata[frame_index].pin_count += 1;
            return &self.frame_pool.frames[frame_index];
        }

        // todo: return from disk
    }

    pub fn markDirty(self: *BufferManager, pfn: u64) void {
        const result = self.frame_pool.resolveFrame(pfn);
        const frame_index = result orelse return;
        self.frame_pool.frames_metadata[frame_index].dirty = 1;
    }

    pub fn flushPage(self: *BufferManager, pfn: u64) !void {
        _ = self;
        _ = pfn;
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
            try self.flushPage(self.frame_pool.frames_assignment[evict_index]);
        }

        self.frame_pool.frames_assignment[evict_index] = 0;
        return evict_index;
    }
};

const std = @import("std");
const PageTable = @import("page_table.zig");

var threaded: std.Io.Threaded = .init_single_threaded;
const io = threaded.io();

pub const BufferManagerError = error{
    PageInUse,
    AllFramesInUse,
    PageNotFound,
};

pub fn BufferManager(
    page_size: u64,
    memory_capacity: u64,
    disk_capacity: u64,
) type {
    const num_frames = memory_capacity / page_size;
    _ = disk_capacity;

    return struct {
        pub const FramePool = PageTable.FramePool(page_size, num_frames);

        frame_pool: FramePool,

        /// globally increasing counter thats used for enumerating new pages
        pfn_counter: u64 = 0,

        /// file handle of disk storage
        file: std.Io.File,

        dir: std.Io.Dir = std.Io.Dir.cwd(),

        alloc: std.mem.Allocator,

        pub fn Init(file_path: [] const u8) !@This() {
            const alloc = std.heap.smp_allocator;

            const dir = std.Io.Dir.cwd();
            const file = try dir.createFile(
                io,
                file_path,
                .{ .read = true, }
            );

            const instance = @This(){
                .frame_pool = try FramePool.Init(alloc),
                .file = file,
                .dir = dir,
                .alloc = alloc,
            };
            return instance;
        }

        pub fn Deinit(self: *@This()) void {
            self.frame_pool.Deinit(self.alloc);
            self.file.close(io);
        }

        pub fn AllocPageFrame(self: *@This()) !struct { pfn: u64, page: *FramePool.Page } {
            const free_frame: ?u64 = if (self.frame_pool.isFull()) null else self.frame_pool.findEmptyFrame(self.frame_pool.count());
            const frame_index = free_frame orelse try self.evictPage();
            const new_pfn = self.pfn_counter;
            self.pfn_counter += 1;

            @memset(&self.frame_pool.frames[frame_index].mem, 0);
            self.frame_pool.frames_metadata[frame_index] = .{
                .pfn = new_pfn,
                .pin_count = 1,
                .dirty = 1,
                .access = 1,
                .valid = 1,
            };
            self.frame_pool.assignFrame(new_pfn, frame_index);
            return .{
                .pfn = new_pfn,
                .page = &self.frame_pool.frames[frame_index],
            };
        }

        pub fn FreePageFrame(self: *@This(), pfn: u64) !void {
            const result = self.frame_pool.resolveFrame(pfn);
            if (result) |frame_index| {
                if (self.frame_pool.frames_metadata[frame_index].pin_count > 0) {
                    return error.PageInUse;
                }

                // instead of give up the slot mark it ready for next eviction phase
                self.frame_pool.frames_metadata[frame_index] = .{
                    .pfn = 0,
                    .pin_count = 0,
                    .dirty = 0,
                    .access = 0,
                    .valid = 0,
                };
            }

            // Currently no deletion inside the file.
            // Freed section just become dead space.
            // Could be improved for reuse in future.
        }

        pub fn PFNToPage(self: *@This(), pfn: u64, thread_id: u64) !*FramePool.Page {
            _ = thread_id;
            const result = self.frame_pool.resolveFrame(pfn);
            if (result) |frame_index| {
                self.frame_pool.frames_metadata[frame_index].pin_count += 1;
                return &self.frame_pool.frames[frame_index];
            }
            const frame_index = try self.evictPage();

            const offset = pfn * page_size;

            _ = try self.file.readPositionalAll(io, &self.frame_pool.frames[frame_index].mem, offset);
            self.frame_pool.assignFrame(pfn, frame_index);
            self.frame_pool.frames_metadata[frame_index] = .{
                .pfn = pfn,
                .pin_count = 1,
                .dirty = 0,
                .access = 1,
                .valid = 1,
            };
            return &self.frame_pool.frames[frame_index];
        }

        pub fn MarkDirty(self: *@This(), pfn: u64) void {
            const result = self.frame_pool.resolveFrame(pfn);
            const frame_index = result orelse return;
            self.frame_pool.frames_metadata[frame_index].dirty = 1;
        }

        pub fn FlushPage(self: *@This(), pfn: u64) !void {
            const frame_index = self.frame_pool.resolveFrame(pfn) orelse return error.PageNotFound;
            if (self.frame_pool.frames_metadata[frame_index].dirty == 0) {
                return;
            }
            return self.flushFrame(frame_index);
        }

        pub fn DecrementPinCount(self: *@This(), pfn: u64) void {
            const result = self.frame_pool.resolveFrame(pfn);
            const frame_index = result orelse return;
            self.frame_pool.frames_metadata[frame_index].pin_count -= 1;
        }

        fn evictPage(self: *@This()) !u64 {
            // Two pass clock eviction
            const evict_index = self.clockEviction() orelse self.clockEviction() orelse return error.AllFramesInUse;

            if (self.frame_pool.frames_metadata[evict_index].dirty == 1) {
                try self.flushFrame(evict_index);
            }

            const pfn = self.frame_pool.frames_metadata[evict_index].pfn;
            _ = self.frame_pool.freeFrame(pfn);
            return evict_index;
        }

        fn flushFrame(self: *@This(), frame_index: u64) !void {
            const pfn = self.frame_pool.frames_metadata[frame_index].pfn;
            const offset = pfn * page_size;

            try self.file.writePositionalAll(io, &self.frame_pool.frames[frame_index].mem, offset);
        }
        
        fn clockEviction(self: *@This()) ?u64 {
            for (self.frame_pool.frames_metadata, 0..) |*meta, i| {
                if (meta.pin_count != 0) continue; 
                if (meta.access == 1 ) {
                    meta.access = 0;
                    continue;
                }
                return i;
            }
            
            return null;
        }
    };
}



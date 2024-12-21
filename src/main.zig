const std = @import("std");

const OUT_FILE = "out.txt";
pub fn main() !void {
    const allocator = &std.heap.page_allocator;
    const entries = 128;
    var ring = try std.os.linux.IoUring.init(entries, 0);
    defer ring.deinit();
    const cqes = try allocator.alloc(std.os.linux.io_uring_cqe, entries);
    defer allocator.free(cqes);
    ring.openat(user_data: u64, fd: posix.fd_t, path: [*:0]const u8, flags: linux.O, mode: posix.mode_t)
    std.debug.print("HI\n", .{});
}

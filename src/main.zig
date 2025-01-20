const std = @import("std");

const OUT_FILE = "out.txt";

pub fn main() !void {
    const allocator = &std.heap.page_allocator;
    const entries = 128;
    // submit_and_wait docs say these should be set if a) single thread
    // accessing ring and b) submitting work with `IORING_ENTER_GETEVENTS` as
    // is the case with submit_and_wait(wait_nr) where wait_nr > 0. Both
    // conditions are met in this program. The docs say these flags "will
    // greatly reduce the number of context switches that an application will
    // see waiting on multiple requests."
    const flags: u32 = std.os.linux.IORING_SETUP_SINGLE_ISSUER | std.os.linux.IORING_SETUP_DEFER_TASKRUN;
    var ring = try std.os.linux.IoUring.init(entries, flags);
    defer ring.deinit();
    const buffers_count = 16;
    const buffer_size = 4069;
    var buffers: [buffers_count * buffer_size]u8 = undefined;
    var bg = try std.os.linux.IoUring.BufferGroup.init(&ring, 0, buffers[0..], buffer_size, buffers_count);
    defer bg.deinit();
    const cqes = try allocator.alloc(std.os.linux.io_uring_cqe, entries);
    defer allocator.free(cqes);

    // Make the server
    var address = try std.net.Address.parseIp4("127.0.0.1", 3000);
    var socklen = address.getOsSockLen();
    const socket = try std.posix.socket(address.any.family, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    defer std.posix.close(socket);
    try std.posix.bind(socket, &address.any, socklen);
    const backlog = 4096; // use a large backlog, OS will auto use the max if too large
    try std.posix.listen(socket, backlog);

    // accept connections (will accept endlessly)
    // CLOEXEC: if a child process is made, the client socket fd (returned by
    // accept) will be duplicated (so the parent and child have a separate fd),
    // so the parent needs to close it's fd. This flag automatically does that.
    // Though our program doesn't create child processes, but just following
    // the tigerbeetle clode in what they do for accept.
    _ = try ring.accept_multishot(0, socket, &address.any, &socklen, std.posix.SOCK.CLOEXEC);

    // server loop
    while (true) {
        // submit atleast 1
        const submitted = try ring.submit_and_wait(1);
        std.debug.print("SUBMITTED {d}\n", .{submitted});
        const cqes_ready = try ring.copy_cqes(cqes, 0);
        var i: usize = 0;
        while (i < cqes_ready) : (i += 1) {
            const cqe = cqes[i];
            std.debug.print("cqe {any}\n", .{cqe});
            if (cqe.user_data == 0) {
                std.debug.print("ACCEPTED CONN {d}\n", .{cqe.res});
                // ensure that multishot will still accept connections
                std.debug.assert(cqe.flags & std.os.linux.IORING_CQE_F_MORE > 0);

                // now recv multishot for this conn
                _ = try bg.recv_multishot(@as(u64, @intCast(cqe.res)), cqe.res, 0);
            } else {
                if (cqe.res < 0) {
                    const errno = @as(std.posix.E, @enumFromInt(-cqe.res));
                    std.debug.print("INVALID ERRNO {any}\n", .{errno});
                } else {

                    // If recv 0 bytes, close conn
                    if (cqe.res == 0) {
                        std.posix.close(@as(i32, @intCast(cqe.user_data)));
                    }

                    std.debug.print("RECEIVED {d} ON CONN {b}\n", .{ cqe.res, cqe.user_data });
                    // If recv >0 bytes, and no IORING_CQE_F_MORE flags, resubmit
                    // recv multishot (just crashing for now)
                    std.debug.assert(cqe.flags & std.os.linux.IORING_CQE_F_MORE > 0);
                }
            }
        }
    }
}

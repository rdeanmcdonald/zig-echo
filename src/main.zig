const std = @import("std");

const OUT_FILE = "out.txt";

fn on_accept(bg: *std.os.linux.IoUring.BufferGroup, cqe: std.os.linux.io_uring_cqe) !void {
    std.debug.assert(cqe.res > 0);

    std.debug.print("ACCEPTED CONN {d}\n", .{cqe.res});

    // ensure that multishot will still accept connections
    std.debug.assert(cqe.flags & std.os.linux.IORING_CQE_F_MORE > 0);

    // now recv multishot for this conn
    _ = try bg.recv_multishot(@as(u64, @intCast(cqe.res)), cqe.res, 0);
}

fn on_recv(bg: *std.os.linux.IoUring.BufferGroup, ring: *std.os.linux.IoUring, cqe: std.os.linux.io_uring_cqe) !void {
    // If recv 0 bytes, close conn
    if (cqe.res == 0) {
        std.debug.print("CLOSING CLIENT CONN {d}\n", .{cqe.user_data});
        std.posix.close(@as(i32, @intCast(cqe.user_data)));
        return;
    }

    // Ensure that multishot will still recv data
    std.debug.assert(cqe.flags & std.os.linux.IORING_CQE_F_MORE > 0);

    // cqe os.linux.io_uring_cqe{ .user_data = 5, .res = 5, .flags = 3 }
    std.debug.print("RECEIVED {d} ON CONN {b}\n", .{ cqe.res, cqe.user_data });

    // Get the buffer with the data
    const data = try bg.get_cqe(cqe);
    std.debug.print("GOT DATA: {s}\n", .{data});

    // Write the data back (just prep the sqe)
    var write_sqe = try ring.write(cqe.user_data, @as(i32, @intCast(cqe.user_data)), data, 0);

    // Also, I don't care about success right now, it would mess up my whole
    // logic (trying to use the socket fd in the user_data, rather than a ptr).
    // There's probably some error handling I'm not doing if the write doesn't
    // work, or all the bytes aren't fully written or something. Oh well.
    write_sqe.flags = std.os.linux.IOSQE_CQE_SKIP_SUCCESS;

    // Give the buffer back to io_uring
    // NOTE: This is probably a bug, releasing the buffer before the write? I
    // would love not to copy any data but might need to to avoid a race
    // condition where the prepped write data is overwritten by another recv.
    // NOTE: To avoid the race I'd need to handle the write results to give the
    // buf back to iouring, and would have to move away from the user_data
    // being the raw connection, since I wouldn't be able to tell what was a
    // write result or a recv result.
    _ = try bg.put_cqe(cqe);
}

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
        // submit at least 1
        const submitted = try ring.submit_and_wait(1);
        std.debug.print("SUBMITTED {d}\n", .{submitted});
        const cqes_ready = try ring.copy_cqes(cqes, 0);
        var i: usize = 0;
        while (i < cqes_ready) : (i += 1) {
            const cqe = cqes[i];
            std.debug.print("cqe {any}\n", .{cqe});
            if (cqe.user_data == 0) {
                _ = try on_accept(&bg, cqe);
            } else {
                _ = try on_recv(&bg, &ring, cqe);
            }
        }
    }
}

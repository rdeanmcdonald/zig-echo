const std = @import("std");
const server = @import("server.zig");
const client = @import("client.zig");

const Program = enum { server, client };
pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();
    const program = std.meta.stringToEnum(Program, args.next().?).?;
    switch (program) {
        Program.server => {
            try server.run();
        },
        Program.client => {
            try client.run();
        },
    }
}

const std = @import("std");
const c = @import("../c.zig");
const api = @import("../jellyfin/api.zig");

const gtk = c.gtk;

// Run a function on a background thread with its own HTTP client,
// then post the result back to GTK main thread via done().
pub fn run(allocator: std.mem.Allocator, src_client: *api.Client, task: anytype) void {
    spawn(allocator, src_client, task, true);
}

// Fire-and-forget variant - no main thread callback.
pub fn fire(allocator: std.mem.Allocator, src_client: *api.Client, task: anytype) void {
    spawn(allocator, src_client, task, false);
}

fn spawn(allocator: std.mem.Allocator, src_client: *api.Client, task: anytype, comptime has_done: bool) void {
    const T = @TypeOf(task);
    const Wrapper = struct {
        task: T,
        alloc: std.mem.Allocator,
        base_url: []const u8,
        token: ?[]const u8,
        user_id: ?[]const u8,
        username: ?[]const u8,
        password: ?[]const u8,

        fn threadFn(self: *@This()) void {
            var client = api.Client.init(self.alloc, self.base_url);
            defer client.deinit();
            client.token = self.token;
            client.user_id = self.user_id;
            client.username = self.username;
            client.password = self.password;

            self.task.work(&client);

            if (comptime has_done) {
                _ = gtk.g_idle_add(&mainCb, self);
            } else {
                self.alloc.destroy(self);
            }
        }

        fn mainCb(data: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.task.done();
            self.alloc.destroy(self);
            return 0;
        }
    };

    const w = allocator.create(Wrapper) catch return;
    w.* = .{
        .task = task,
        .alloc = allocator,
        .base_url = src_client.base_url,
        .token = src_client.token,
        .user_id = src_client.user_id,
        .username = src_client.username,
        .password = src_client.password,
    };

    const thread = std.Thread.spawn(.{}, Wrapper.threadFn, .{w}) catch {
        allocator.destroy(w);
        return;
    };
    thread.detach();
}

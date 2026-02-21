const std = @import("std");

pub const Response = struct {
    status_code: u16,
    body: []u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub fn executeRequest(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    uri: []const u8,
    payload: ?[]const u8,
    max_response_bytes: usize,
) !Response {
    if (uri.len == 0) return error.InvalidToolArguments;
    if (max_response_bytes == 0) return error.InvalidToolArguments;

    const parsed_uri = try std.Uri.parse(uri);
    if (!std.ascii.eqlIgnoreCase(parsed_uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(parsed_uri.scheme, "https"))
    {
        return error.UnsupportedUriScheme;
    }

    const response_storage = try allocator.alloc(u8, max_response_bytes);
    defer allocator.free(response_storage);

    var response_writer = std.Io.Writer.fixed(response_storage);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const response = client.fetch(.{
        .location = .{ .uri = parsed_uri },
        .method = method,
        .payload = payload,
        .response_writer = &response_writer,
    }) catch |err| switch (err) {
        error.WriteFailed => return error.StreamTooLong,
        else => |fetch_err| return fetch_err,
    };

    return .{
        .status_code = @intFromEnum(response.status),
        .body = try allocator.dupe(u8, response_writer.buffered()),
    };
}

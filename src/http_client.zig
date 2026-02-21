const std = @import("std");

pub const RequestHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const Response = struct {
    status_code: u16,
    body: []u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const max_request_headers: usize = 64;
pub const max_total_header_bytes: usize = 16 * 1024;

pub fn executeRequest(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    uri: []const u8,
    payload: ?[]const u8,
    headers: []const RequestHeader,
    max_response_bytes: usize,
) !Response {
    if (uri.len == 0) return error.InvalidToolArguments;
    if (max_response_bytes == 0) return error.InvalidToolArguments;
    try validateRequestHeaders(headers);

    const parsed_uri = try std.Uri.parse(uri);
    if (!std.ascii.eqlIgnoreCase(parsed_uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(parsed_uri.scheme, "https"))
    {
        return error.UnsupportedUriScheme;
    }

    var extra_headers = std.ArrayList(std.http.Header).empty;
    defer extra_headers.deinit(allocator);
    try extra_headers.ensureTotalCapacityPrecise(allocator, headers.len);
    for (headers) |header| {
        extra_headers.appendAssumeCapacity(.{
            .name = header.name,
            .value = header.value,
        });
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
        .extra_headers = extra_headers.items,
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

fn validateRequestHeaders(headers: []const RequestHeader) !void {
    if (headers.len > max_request_headers) return error.TooManyHeaders;

    var total_header_bytes: usize = 0;
    for (headers) |header| {
        if (!isValidHeaderName(header.name)) return error.InvalidHeaderName;
        if (!isValidHeaderValue(header.value)) return error.InvalidHeaderValue;
        if (isBlockedHeaderName(header.name)) return error.HeaderNotAllowed;

        total_header_bytes +|= header.name.len + header.value.len;
        if (total_header_bytes > max_total_header_bytes) return error.HeadersTooLarge;
    }
}

fn isValidHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;

    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => continue,
            else => return false,
        }
    }
    return true;
}

fn isValidHeaderValue(value: []const u8) bool {
    for (value) |byte| {
        if (byte == '\r' or byte == '\n' or byte == 0) return false;
    }
    return true;
}

fn isBlockedHeaderName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "host") or
        std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding");
}

test "validateRequestHeaders rejects invalid header names and values" {
    try std.testing.expectError(
        error.InvalidHeaderName,
        validateRequestHeaders(&.{.{ .name = "Bad Name", .value = "ok" }}),
    );

    try std.testing.expectError(
        error.InvalidHeaderValue,
        validateRequestHeaders(&.{.{ .name = "Authorization", .value = "Bearer\r\nbad" }}),
    );
}

test "validateRequestHeaders rejects blocked header names" {
    try std.testing.expectError(
        error.HeaderNotAllowed,
        validateRequestHeaders(&.{.{ .name = "Host", .value = "example.com" }}),
    );
}

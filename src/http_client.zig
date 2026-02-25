const std = @import("std");

pub const RequestHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const ResponseHeader = struct {
    name: []u8,
    value: []u8,
};

pub const Response = struct {
    status_code: u16,
    headers: []ResponseHeader,
    body: []u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        deinitResponseHeaders(allocator, self.headers);
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
    allow_private_destinations: bool,
) !Response {
    if (uri.len == 0) return error.InvalidToolArguments;
    if (max_response_bytes == 0) return error.InvalidToolArguments;
    try validateRequestHeaders(headers);

    try validateUriPolicy(allocator, uri, allow_private_destinations);

    const parsed_uri = try std.Uri.parse(uri);

    var extra_headers = std.ArrayList(std.http.Header).empty;
    defer extra_headers.deinit(allocator);
    try extra_headers.ensureTotalCapacityPrecise(allocator, headers.len);
    for (headers) |header| {
        extra_headers.appendAssumeCapacity(.{
            .name = header.name,
            .value = header.value,
        });
    }

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var request = try client.request(method, parsed_uri, .{
        .redirect_behavior = .unhandled,
        .extra_headers = extra_headers.items,
    });
    defer request.deinit();

    if (payload) |request_payload| {
        request.transfer_encoding = .{ .content_length = request_payload.len };
        var request_body = try request.sendBodyUnflushed(&.{});
        try request_body.writer.writeAll(request_payload);
        try request_body.end();
        try request.connection.?.flush();
    } else {
        try request.sendBodiless();
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    var response_headers = std.ArrayList(ResponseHeader).empty;
    defer response_headers.deinit(allocator);
    errdefer {
        deinitResponseHeaderFields(allocator, response_headers.items);
    }

    var header_it = response.head.iterateHeaders();
    while (header_it.next()) |header| {
        const header_name = try allocLowerHeaderName(allocator, header.name);
        errdefer allocator.free(header_name);

        const header_value = try allocator.dupe(u8, header.value);
        errdefer allocator.free(header_value);

        try response_headers.append(allocator, .{
            .name = header_name,
            .value = header_value,
        });
    }

    const owned_headers = try response_headers.toOwnedSlice(allocator);
    errdefer deinitResponseHeaders(allocator, owned_headers);

    const response_storage = try allocator.alloc(u8, max_response_bytes);
    defer allocator.free(response_storage);
    var response_writer = std.Io.Writer.fixed(response_storage);

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (response.head.content_encoding != .identity) allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const response_reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = response_reader.streamRemaining(&response_writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        error.WriteFailed => return error.StreamTooLong,
        else => |read_err| return read_err,
    };

    return .{
        .status_code = @intFromEnum(response.head.status),
        .headers = owned_headers,
        .body = try allocator.dupe(u8, response_writer.buffered()),
    };
}

fn deinitResponseHeaders(allocator: std.mem.Allocator, headers: []ResponseHeader) void {
    deinitResponseHeaderFields(allocator, headers);
    allocator.free(headers);
}

fn deinitResponseHeaderFields(allocator: std.mem.Allocator, headers: []ResponseHeader) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
}

fn allocLowerHeaderName(allocator: std.mem.Allocator, header_name: []const u8) ![]u8 {
    const lower_name = try allocator.alloc(u8, header_name.len);
    for (header_name, 0..) |byte, index| {
        lower_name[index] = std.ascii.toLower(byte);
    }
    return lower_name;
}

test "allocLowerHeaderName lowercases ASCII bytes" {
    const actual = try allocLowerHeaderName(std.testing.allocator, "ConTent-TYPe");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("content-type", actual);
}

test "response deinit frees owned response headers" {
    var headers = try std.testing.allocator.alloc(ResponseHeader, 1);
    headers[0] = .{
        .name = try std.testing.allocator.dupe(u8, "location"),
        .value = try std.testing.allocator.dupe(u8, "https://example.com"),
    };
    var response = Response{
        .status_code = 301,
        .headers = headers,
        .body = try std.testing.allocator.dupe(u8, ""),
    };
    response.deinit(std.testing.allocator);
}

test "executeRequest rejects blocked localhost destinations" {
    try std.testing.expectError(
        error.DestinationNotAllowed,
        executeRequest(
            std.testing.allocator,
            .GET,
            "http://localhost:8080",
            null,
            &.{},
            1024,
            false,
        ),
    );

    try std.testing.expectError(
        error.DestinationNotAllowed,
        executeRequest(
            std.testing.allocator,
            .GET,
            "http://127.0.0.1:8080",
            null,
            &.{},
            1024,
            false,
        ),
    );
}

pub fn validateUriPolicy(
    allocator: std.mem.Allocator,
    uri: []const u8,
    allow_private_destinations: bool,
) !void {
    if (uri.len == 0) return error.InvalidToolArguments;

    const parsed_uri = try std.Uri.parse(uri);
    if (!std.ascii.eqlIgnoreCase(parsed_uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(parsed_uri.scheme, "https"))
    {
        return error.UnsupportedUriScheme;
    }
    try validateUriDestination(allocator, parsed_uri, allow_private_destinations);
}

fn validateUriDestination(
    allocator: std.mem.Allocator,
    parsed_uri: std.Uri,
    allow_private_destinations: bool,
) !void {
    if (allow_private_destinations) return;

    var host_buffer: [std.Uri.host_name_max]u8 = undefined;
    const host = parsed_uri.getHost(&host_buffer) catch return error.InvalidToolArguments;
    if (isBlockedHostName(host)) return error.DestinationNotAllowed;

    const port = parsed_uri.port orelse if (std.ascii.eqlIgnoreCase(parsed_uri.scheme, "https")) @as(u16, 443) else @as(u16, 80);

    const maybe_ip: ?std.net.Address = std.net.Address.resolveIp(host, port) catch null;
    if (maybe_ip) |ip| {
        if (isBlockedAddress(ip)) return error.DestinationNotAllowed;
        return;
    }

    var addresses = try std.net.getAddressList(allocator, host, port);
    defer addresses.deinit();
    if (addresses.addrs.len == 0) return error.UnknownHostName;

    for (addresses.addrs) |address| {
        if (isBlockedAddress(address)) return error.DestinationNotAllowed;
    }
}

fn isBlockedHostName(host: []const u8) bool {
    var trimmed = host;
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '.') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    if (trimmed.len == 0) return true;

    return std.ascii.eqlIgnoreCase(trimmed, "localhost") or
        (trimmed.len > ".localhost".len and std.ascii.endsWithIgnoreCase(trimmed, ".localhost"));
}

fn isBlockedAddress(address: std.net.Address) bool {
    return switch (address.any.family) {
        std.posix.AF.INET => blk: {
            const bytes = @as(*const [4]u8, @ptrCast(&address.in.sa.addr)).*;
            break :blk isBlockedIpv4(bytes);
        },
        std.posix.AF.INET6 => isBlockedIpv6(address.in6.sa.addr),
        else => true,
    };
}

fn isBlockedIpv4(bytes: [4]u8) bool {
    return bytes[0] == 0 or
        bytes[0] == 10 or
        bytes[0] == 127 or
        (bytes[0] == 169 and bytes[1] == 254) or
        (bytes[0] == 172 and bytes[1] >= 16 and bytes[1] <= 31) or
        (bytes[0] == 192 and bytes[1] == 168);
}

fn isBlockedIpv6(bytes: [16]u8) bool {
    if (isIpv6Unspecified(bytes) or isIpv6Loopback(bytes)) return true;
    if ((bytes[0] & 0xfe) == 0xfc) return true;
    if (bytes[0] == 0xfe and (bytes[1] & 0xc0) == 0x80) return true;
    if (isIpv4MappedIpv6(bytes)) {
        return isBlockedIpv4(.{ bytes[12], bytes[13], bytes[14], bytes[15] });
    }
    return false;
}

fn isIpv6Unspecified(bytes: [16]u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn isIpv6Loopback(bytes: [16]u8) bool {
    for (bytes[0..15]) |byte| {
        if (byte != 0) return false;
    }
    return bytes[15] == 1;
}

fn isIpv4MappedIpv6(bytes: [16]u8) bool {
    for (bytes[0..10]) |byte| {
        if (byte != 0) return false;
    }
    return bytes[10] == 0xff and bytes[11] == 0xff;
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

test "isBlockedHostName recognizes localhost names" {
    try std.testing.expect(isBlockedHostName("localhost"));
    try std.testing.expect(isBlockedHostName("LOCALHOST"));
    try std.testing.expect(isBlockedHostName("api.localhost"));
    try std.testing.expect(isBlockedHostName("localhost."));
    try std.testing.expect(!isBlockedHostName("example.com"));
}

test "isBlockedAddress blocks private and loopback ranges" {
    try std.testing.expect(isBlockedAddress(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 80)));
    try std.testing.expect(isBlockedAddress(std.net.Address.initIp4(.{ 10, 1, 2, 3 }, 80)));
    try std.testing.expect(isBlockedAddress(std.net.Address.initIp4(.{ 172, 16, 0, 1 }, 80)));
    try std.testing.expect(isBlockedAddress(std.net.Address.initIp4(.{ 192, 168, 1, 2 }, 80)));
    try std.testing.expect(!isBlockedAddress(std.net.Address.initIp4(.{ 93, 184, 216, 34 }, 80)));

    var ipv6_loopback = [_]u8{0} ** 16;
    ipv6_loopback[15] = 1;
    try std.testing.expect(isBlockedAddress(std.net.Address.initIp6(ipv6_loopback, 443, 0, 0)));

    const ipv6_ula = [_]u8{ 0xfc, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try std.testing.expect(isBlockedAddress(std.net.Address.initIp6(ipv6_ula, 443, 0, 0)));

    const ipv6_link_local = [_]u8{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try std.testing.expect(isBlockedAddress(std.net.Address.initIp6(ipv6_link_local, 443, 0, 0)));

    const ipv6_mapped_loopback = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 };
    try std.testing.expect(isBlockedAddress(std.net.Address.initIp6(ipv6_mapped_loopback, 443, 0, 0)));
}

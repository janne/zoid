const std = @import("std");

pub const default_model: []const u8 = "gpt-4o-mini";

pub const fallback_models = [_][]const u8{
    "gpt-4o-mini",
    "gpt-4.1-mini",
    "gpt-4.1",
    "gpt-5-mini",
    "gpt-5",
    "o3-mini",
};

const chat_model_prefixes = [_][]const u8{
    "gpt-",
    "chatgpt-",
    "o1",
    "o3",
    "o4",
};

pub fn isChatModelId(model_id: []const u8) bool {
    for (chat_model_prefixes) |prefix| {
        if (std.mem.startsWith(u8, model_id, prefix)) return true;
    }
    return false;
}

test "isChatModelId supports known chat model families" {
    try std.testing.expect(isChatModelId("gpt-4.1"));
    try std.testing.expect(isChatModelId("chatgpt-4o-latest"));
    try std.testing.expect(isChatModelId("o1"));
    try std.testing.expect(isChatModelId("o3-mini"));
    try std.testing.expect(isChatModelId("o4-mini"));
}

test "isChatModelId rejects non-chat model families" {
    try std.testing.expect(!isChatModelId("whisper-1"));
    try std.testing.expect(!isChatModelId("text-embedding-3-small"));
}

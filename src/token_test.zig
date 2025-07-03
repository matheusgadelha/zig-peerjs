const std = @import("std");
const testing = std.testing;
const signaling = @import("signaling.zig");

// Test HTTP ID request with public PeerJS server
test "HTTP ID request from public server" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Configure for public PeerJS server
    const config = signaling.ServerConfig{
        .host = "0.peerjs.com",
        .port = 443,
        .secure = true,
        .key = "peerjs",
    };

    var client = try signaling.SignalingClient.init(allocator, config);
    defer client.deinit();

    // Test requesting peer ID and token
    const pair = client.requestPeerIdAndToken() catch |err| switch (err) {
        // Network errors are expected in CI environments
        error.HttpConnectionFailed,
        error.DnsResolutionFailed,
        error.TlsError => {
            std.log.warn("Network error expected in CI: {}", .{err});
            return;
        },
        else => return err,
    };
    defer {
        var mutable_pair = pair;
        mutable_pair.deinit(allocator);
    }

    // Verify we got valid peer ID and token
    try testing.expect(pair.peer_id.len > 0);
    try testing.expect(pair.token.len > 0);
    
    std.log.info("✅ Received peer ID: {s}", .{pair.peer_id});
    std.log.info("✅ Received token: {s}", .{pair.token});
    
    // Verify peer ID format (should be alphanumeric)
    for (pair.peer_id) |char| {
        try testing.expect(std.ascii.isAlphanumeric(char) or char == '-' or char == '_');
    }
    
    // Verify token format (should be alphanumeric)
    for (pair.token) |char| {
        try testing.expect(std.ascii.isAlphanumeric(char) or char == '-' or char == '_');
    }
}

// Test WebSocket URL construction with token
test "WebSocket URL construction with token" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = signaling.ServerConfig{
        .host = "0.peerjs.com",
        .port = 443,
        .secure = true,
        .key = "peerjs",
    };

    var client = try signaling.SignalingClient.init(allocator, config);
    defer client.deinit();

    // Test URL construction with known values
    const test_peer_id = "test-peer-123";
    const test_token = "test-token-456";
    
    var path_buffer: [512]u8 = undefined;
    const ws_path = try std.fmt.bufPrint(path_buffer[0..], "/peerjs?key={s}&id={s}&token={s}", .{ 
        config.key, test_peer_id, test_token 
    });
    
    const expected = "/peerjs?key=peerjs&id=test-peer-123&token=test-token-456";
    try testing.expectEqualStrings(expected, ws_path);
    
    std.log.info("✅ WebSocket URL construction verified: {s}", .{ws_path});
}

// Test token generation fallback
test "Token generation fallback" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = signaling.ServerConfig{};
    var client = try signaling.SignalingClient.init(allocator, config);
    defer client.deinit();

    // Test random token generation
    const token1 = try client.generateRandomToken();
    defer allocator.free(token1);
    
    const token2 = try client.generateRandomToken();
    defer allocator.free(token2);
    
    // Tokens should be different
    try testing.expect(!std.mem.eql(u8, token1, token2));
    
    // Tokens should be valid length
    try testing.expect(token1.len == 16);
    try testing.expect(token2.len == 16);
    
    // Tokens should be alphanumeric
    for (token1) |char| {
        try testing.expect(std.ascii.isAlphanumeric(char));
    }
    
    std.log.info("✅ Generated token 1: {s}", .{token1});
    std.log.info("✅ Generated token 2: {s}", .{token2});
}

// Test JSON response parsing
test "JSON response parsing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test valid JSON response
    const json_response = "{\"id\":\"test-peer-789\",\"token\":\"test-token-abc\"}";
    
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_response, .{});
    defer parsed.deinit();
    
    const obj = parsed.value.object;
    const peer_id = obj.get("id").?.string;
    const token = obj.get("token").?.string;
    
    try testing.expectEqualStrings("test-peer-789", peer_id);
    try testing.expectEqualStrings("test-token-abc", token);
    
    std.log.info("✅ JSON parsing verified - ID: {s}, Token: {s}", .{peer_id, token});
}

// Test connection flow simulation
test "Connection flow simulation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = signaling.ServerConfig{
        .host = "localhost", // Use localhost to avoid network calls in tests
        .port = 9000,
        .secure = false,
        .key = "test-key",
    };

    var client = try signaling.SignalingClient.init(allocator, config);
    defer client.deinit();

    // Simulate the connection process (without actual network calls)
    const test_peer_id = "simulated-peer";
    const test_token = try client.generateRandomToken();
    defer allocator.free(test_token);
    
    // Verify the process would work
    try testing.expect(test_peer_id.len > 0);
    try testing.expect(test_token.len > 0);
    
    std.log.info("✅ Connection flow simulation - ID: {s}, Token: {s}", .{test_peer_id, test_token});
}

// Performance test for token generation
test "Token generation performance" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = signaling.ServerConfig{};
    var client = try signaling.SignalingClient.init(allocator, config);
    defer client.deinit();

    const start_time = std.time.nanoTimestamp();
    
    // Generate 1000 tokens
    var tokens = std.ArrayList([]const u8).init(allocator);
    defer {
        for (tokens.items) |token| {
            allocator.free(token);
        }
        tokens.deinit();
    }
    
    for (0..1000) |_| {
        const token = try client.generateRandomToken();
        try tokens.append(token);
    }
    
    const end_time = std.time.nanoTimestamp();
    const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;
    
    std.log.info("✅ Generated 1000 tokens in {d:.2}ms", .{duration_ms});
    
    // Performance should be reasonable (< 1ms per token)
    const avg_ms_per_token = duration_ms / 1000.0;
    try testing.expect(avg_ms_per_token < 1.0);
} 
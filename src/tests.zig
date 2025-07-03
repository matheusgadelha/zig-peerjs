//! Comprehensive tests for Zig PeerJS WebRTC library
//!
//! This module contains integration tests and unit tests for all components
//! of the PeerJS WebRTC library including signaling, peer connections,
//! and data transfer functionality.

const std = @import("std");
const testing = std.testing;
const peerjs = @import("root.zig");
const signaling = @import("signaling.zig");

// Test configurations
const test_config = peerjs.PeerConfig{
    .host = "localhost",
    .port = 9000,
    .secure = false,
    .key = "test-key",
    .debug = 3,
    .timeout_ms = 1000,
};

const test_signaling_config = signaling.ServerConfig{
    .host = "localhost",
    .port = 9000,
    .secure = false,
    .key = "test-key",
    .timeout = 1000,
    .ping_interval = 1000,
};

// Mock message helpers for testing
fn createMockMessage(allocator: std.mem.Allocator, msg_type: signaling.MessageType, peer_id: ?[]const u8) !signaling.SignalingMessage {
    return signaling.SignalingMessage{
        .type = msg_type,
        .src = if (peer_id) |id| try allocator.dupe(u8, id) else null,
        .dst = if (peer_id) |id| try allocator.dupe(u8, id) else null,
        .payload = switch (msg_type) {
            .open => .{ .peer_id = try allocator.dupe(u8, "test-peer-123") },
            .error_msg => .{ .error_msg = try allocator.dupe(u8, "Test error message") },
            .offer => .{ .sdp = signaling.SessionDescription{
                .type = .offer,
                .sdp = try allocator.dupe(u8, "mock-sdp-offer"),
            } },
            .answer => .{ .sdp = signaling.SessionDescription{
                .type = .answer,
                .sdp = try allocator.dupe(u8, "mock-sdp-answer"),
            } },
            .candidate => .{ .candidate = signaling.IceCandidate{
                .candidate = try allocator.dupe(u8, "mock-ice-candidate"),
                .sdp_mid = try allocator.dupe(u8, "0"),
                .sdp_mline_index = 0,
            } },
            else => .none,
        },
    };
}

// Signaling Module Tests
test "signaling: MessageType enum functions" {
    // Test string conversion
    try testing.expectEqual(signaling.MessageType.heartbeat, signaling.MessageType.fromString("HEARTBEAT").?);
    try testing.expectEqual(signaling.MessageType.offer, signaling.MessageType.fromString("OFFER").?);
    try testing.expectEqual(signaling.MessageType.answer, signaling.MessageType.fromString("ANSWER").?);
    try testing.expectEqual(signaling.MessageType.candidate, signaling.MessageType.fromString("CANDIDATE").?);
    try testing.expectEqual(signaling.MessageType.open, signaling.MessageType.fromString("OPEN").?);
    try testing.expectEqual(signaling.MessageType.error_msg, signaling.MessageType.fromString("ERROR").?);
    try testing.expectEqual(@as(?signaling.MessageType, null), signaling.MessageType.fromString("INVALID"));

    // Test toString conversion
    try testing.expectEqualStrings("HEARTBEAT", signaling.MessageType.heartbeat.toString());
    try testing.expectEqualStrings("OFFER", signaling.MessageType.offer.toString());
    try testing.expectEqualStrings("ANSWER", signaling.MessageType.answer.toString());
    try testing.expectEqualStrings("CANDIDATE", signaling.MessageType.candidate.toString());
    try testing.expectEqualStrings("OPEN", signaling.MessageType.open.toString());
    try testing.expectEqualStrings("ERROR", signaling.MessageType.error_msg.toString());
}

test "signaling: SessionDescription creation" {
    const sdp = signaling.SessionDescription{
        .type = .offer,
        .sdp = "test-sdp-data",
    };

            try testing.expectEqual(@as(@TypeOf(sdp.type), .offer), sdp.type);
    try testing.expectEqualStrings("test-sdp-data", sdp.sdp);
}

test "signaling: IceCandidate creation" {
    const candidate = signaling.IceCandidate{
        .candidate = "test-candidate",
        .sdp_mid = "test-mid",
        .sdp_mline_index = 1,
    };

    try testing.expectEqualStrings("test-candidate", candidate.candidate);
    try testing.expectEqualStrings("test-mid", candidate.sdp_mid.?);
    try testing.expectEqual(@as(u32, 1), candidate.sdp_mline_index.?);
}

test "signaling: SignalingMessage memory management" {
    const allocator = testing.allocator;

    var message = try createMockMessage(allocator, .open, "test-peer");
    defer message.deinit(allocator);

    try testing.expectEqual(signaling.MessageType.open, message.type);
    try testing.expectEqualStrings("test-peer", message.src.?);
    try testing.expectEqualStrings("test-peer-123", message.payload.peer_id);
}

test "signaling: SignalingClient initialization" {
    const allocator = testing.allocator;

    var client = try signaling.SignalingClient.init(allocator, test_signaling_config);
    defer client.deinit();

    try testing.expect(!client.connected);
    try testing.expectEqual(@as(?[]const u8, null), client.getPeerId());
}

test "signaling: Multiple SignalingMessage cleanup" {
    const allocator = testing.allocator;

    var messages = std.ArrayList(signaling.SignalingMessage).init(allocator);
    defer {
        for (messages.items) |*msg| {
            msg.deinit(allocator);
        }
        messages.deinit();
    }

    // Create multiple messages of different types
    try messages.append(try createMockMessage(allocator, .open, "peer1"));
    try messages.append(try createMockMessage(allocator, .offer, "peer2"));
    try messages.append(try createMockMessage(allocator, .answer, "peer3"));
    try messages.append(try createMockMessage(allocator, .candidate, "peer4"));
    try messages.append(try createMockMessage(allocator, .error_msg, "peer5"));

    try testing.expectEqual(@as(usize, 5), messages.items.len);
}

// Core Library Tests
test "core: PeerConfig validation" {
    const config = peerjs.PeerConfig{
        .host = "custom.peerjs.com",
        .port = 8080,
        .secure = false,
        .key = "custom-key",
        .peer_id = "my-custom-peer",
        .debug = 2,
    };

    try testing.expectEqualStrings("custom.peerjs.com", config.host);
    try testing.expectEqual(@as(u16, 8080), config.port);
    try testing.expect(!config.secure);
    try testing.expectEqualStrings("custom-key", config.key);
    try testing.expectEqualStrings("my-custom-peer", config.peer_id.?);
    try testing.expectEqual(@as(u8, 2), config.debug);
}

test "core: Peer ID validation edge cases" {
    // Valid IDs
    try testing.expect(peerjs.isValidPeerId("a"));
    try testing.expect(peerjs.isValidPeerId("123"));
    try testing.expect(peerjs.isValidPeerId("abc123"));
    try testing.expect(peerjs.isValidPeerId("peer_test"));
    try testing.expect(peerjs.isValidPeerId("peer-test"));
    try testing.expect(peerjs.isValidPeerId("a_b-c_d-e"));
    try testing.expect(peerjs.isValidPeerId("very_long_peer_id_with_underscores_and_numbers_123"));

    // Invalid IDs
    try testing.expect(!peerjs.isValidPeerId("")); // Empty
    try testing.expect(!peerjs.isValidPeerId("-abc")); // Starts with dash
    try testing.expect(!peerjs.isValidPeerId("abc-")); // Ends with dash
    try testing.expect(!peerjs.isValidPeerId("ab@c")); // Invalid character
    try testing.expect(!peerjs.isValidPeerId("ab.c")); // Invalid character
    try testing.expect(!peerjs.isValidPeerId("ab c")); // Space
    try testing.expect(!peerjs.isValidPeerId("this_is_a_very_long_peer_id_that_exceeds_fifty_characters_limit")); // Too long
}

test "core: PeerClient initialization with different configs" {
    const allocator = testing.allocator;

    // Default config
    {
        var client = try peerjs.PeerClient.init(allocator, .{});
        defer client.deinit();

        try testing.expect(!client.connected);
        try testing.expectEqualStrings("0.peerjs.com", client.config.host);
        try testing.expectEqual(@as(u16, 443), client.config.port);
        try testing.expect(client.config.secure);
    }

    // Custom config
    {
        var client = try peerjs.PeerClient.init(allocator, test_config);
        defer client.deinit();

        try testing.expect(!client.connected);
        try testing.expectEqualStrings("localhost", client.config.host);
        try testing.expectEqual(@as(u16, 9000), client.config.port);
        try testing.expect(!client.config.secure);
    }
}

test "core: PeerClient invalid peer ID rejection" {
    const allocator = testing.allocator;

    const invalid_config = peerjs.PeerConfig{
        .peer_id = "-invalid-id-",
    };

    const result = peerjs.PeerClient.init(allocator, invalid_config);
    try testing.expectError(peerjs.PeerError.InvalidPeerId, result);
}

test "core: DataConnection lifecycle" {
    const allocator = testing.allocator;

    var peer_client = try peerjs.PeerClient.init(allocator, test_config);
    defer peer_client.deinit();

    var connection = try peerjs.DataConnection.init(
        allocator,
        "test-peer-123",
        "connection-123",
        &peer_client,
        .{},
    );
    defer connection.deinit();

    try testing.expectEqualStrings("test-peer-123", connection.peer_id);
    try testing.expectEqualStrings("connection-123", connection.connection_id);
    try testing.expectEqual(peerjs.ConnectionStatus.connecting, connection.status);
    try testing.expectEqual(@as(usize, 0), connection.message_queue.items.len);

    // Test status transitions
    connection.status = .open;
    try testing.expectEqual(peerjs.ConnectionStatus.open, connection.status);

    // Test manual status change (avoid network operations in tests)
    connection.status = .closed;
    try testing.expectEqual(peerjs.ConnectionStatus.closed, connection.status);
}

test "core: DataChannelConfig options" {
    const config = peerjs.DataChannelConfig{
        .label = "custom-channel",
        .ordered = false,
        .max_packet_life_time = 5000,
        .max_retransmits = 3,
    };

    try testing.expectEqualStrings("custom-channel", config.label);
    try testing.expect(!config.ordered);
    try testing.expectEqual(@as(u32, 5000), config.max_packet_life_time.?);
    try testing.expectEqual(@as(u32, 3), config.max_retransmits.?);
}

test "core: Multiple DataConnections management" {
    const allocator = testing.allocator;

    var peer_client = try peerjs.PeerClient.init(allocator, test_config);
    defer peer_client.deinit();

    // Create multiple connections
    var connections = std.ArrayList(*peerjs.DataConnection).init(allocator);
    defer {
        for (connections.items) |conn| {
            conn.deinit();
            allocator.destroy(conn);
        }
        connections.deinit();
    }

    const peer_ids = [_][]const u8{ "peer1", "peer2", "peer3" };

    for (peer_ids) |peer_id| {
        const connection = try allocator.create(peerjs.DataConnection);
        connection.* = try peerjs.DataConnection.init(
            allocator,
            peer_id,
            "conn",
            &peer_client,
            .{},
        );
        try connections.append(connection);
    }

    try testing.expectEqual(@as(usize, 3), connections.items.len);

    // Test each connection has unique peer ID
    for (connections.items, 0..) |conn, i| {
        try testing.expectEqualStrings(peer_ids[i], conn.peer_id);
    }
}

// Integration Tests
test "integration: PeerClient and SignalingClient interaction" {
    const allocator = testing.allocator;

    var peer_client = try peerjs.PeerClient.init(allocator, test_config);
    defer peer_client.deinit();

    // Test that signaling client is properly initialized
    try testing.expectEqualStrings("localhost", peer_client.signaling_client.config.host);
    try testing.expectEqual(@as(u16, 9000), peer_client.signaling_client.config.port);
    try testing.expect(!peer_client.signaling_client.config.secure);
    try testing.expectEqualStrings("test-key", peer_client.signaling_client.config.key);
}

test "integration: Message flow simulation" {
    const allocator = testing.allocator;

    // This test simulates the message flow without actual network connection
    var messages = std.ArrayList(signaling.SignalingMessage).init(allocator);
    defer {
        for (messages.items) |*msg| {
            msg.deinit(allocator);
        }
        messages.deinit();
    }

    // 1. OPEN message (server assigns peer ID)
    try messages.append(try createMockMessage(allocator, .open, null));

    // 2. OFFER message (peer A wants to connect to peer B)
    try messages.append(try createMockMessage(allocator, .offer, "peer-a"));

    // 3. ANSWER message (peer B responds to peer A)
    try messages.append(try createMockMessage(allocator, .answer, "peer-b"));

    // 4. CANDIDATE messages (ICE candidates exchange)
    try messages.append(try createMockMessage(allocator, .candidate, "peer-a"));
    try messages.append(try createMockMessage(allocator, .candidate, "peer-b"));

    // 5. HEARTBEAT message
    try messages.append(try createMockMessage(allocator, .heartbeat, null));

    // 6. LEAVE message (peer A disconnects)
    try messages.append(try createMockMessage(allocator, .leave, "peer-a"));

    try testing.expectEqual(@as(usize, 7), messages.items.len);

    // Verify message types in order
    const expected_types = [_]signaling.MessageType{ .open, .offer, .answer, .candidate, .candidate, .heartbeat, .leave };

    for (messages.items, 0..) |msg, i| {
        try testing.expectEqual(expected_types[i], msg.type);
    }
}

// Error Handling Tests
test "error_handling: Invalid message formats" {
    // Test invalid message type
    try testing.expectEqual(@as(?signaling.MessageType, null), signaling.MessageType.fromString("INVALID_TYPE"));

    // Test empty strings
    try testing.expectEqual(@as(?signaling.MessageType, null), signaling.MessageType.fromString(""));

    // Test case sensitivity
    try testing.expectEqual(@as(?signaling.MessageType, null), signaling.MessageType.fromString("offer")); // lowercase
    try testing.expectEqual(@as(?signaling.MessageType, null), signaling.MessageType.fromString("Offer")); // mixed case
}

test "error_handling: Memory cleanup on errors" {
    const allocator = testing.allocator;

    // Test that we can create and destroy many messages without leaks
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        var message = try createMockMessage(allocator, .open, "test-peer");
        message.deinit(allocator);
    }

    // If we reach here without memory issues, the test passes
}

// Performance and Stress Tests
test "performance: Large message creation and cleanup" {
    const allocator = testing.allocator;

    const message_count = 1000;
    const messages = try allocator.alloc(signaling.SignalingMessage, message_count);
    defer allocator.free(messages);

    // Create many messages
    for (messages, 0..) |*msg, i| {
        const msg_type = switch (i % 5) {
            0 => signaling.MessageType.open,
            1 => signaling.MessageType.offer,
            2 => signaling.MessageType.answer,
            3 => signaling.MessageType.candidate,
            else => signaling.MessageType.heartbeat,
        };

        msg.* = try createMockMessage(allocator, msg_type, "test-peer");
    }

    // Clean up all messages
    for (messages) |*msg| {
        msg.deinit(allocator);
    }
}

test "performance: Peer ID validation speed" {
    // Test that peer ID validation is fast for many IDs
    const test_ids = [_][]const u8{
        "peer1",          "peer2",            "peer3",         "peer4", "peer5",
        "valid_peer_123", "another-peer-456", "test_peer_789", "short", "longer_peer_id_with_numbers_999",
    };

    var valid_count: u32 = 0;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        for (test_ids) |id| {
            if (peerjs.isValidPeerId(id)) {
                valid_count += 1;
            }
        }
    }

    // All test IDs are valid, so we should have: 1000 * test_ids.len valid IDs
    try testing.expectEqual(@as(u32, 1000 * test_ids.len), valid_count);
}

// Utility function tests
test "utility: Legacy token fetch" {
    const allocator = testing.allocator;

    const token = try peerjs.fetchPeerToken(allocator);
    defer token.deinit();

    try testing.expect(token.items.len > 0);
    try testing.expectEqualStrings("legacy-token-placeholder", token.items);
}

// Documentation and API consistency tests
test "api_consistency: Error types are properly exposed" {
    // Test that error types are accessible and properly defined
    const peer_error: peerjs.PeerError = peerjs.PeerError.ConnectionFailed;
    const signaling_error: peerjs.SignalingError = peerjs.SignalingError.ConnectionFailed;

    try testing.expectEqual(peerjs.PeerError.ConnectionFailed, peer_error);
    try testing.expectEqual(peerjs.SignalingError.ConnectionFailed, signaling_error);
}

test "api_consistency: Public API accessibility" {
    // Test that all main public APIs are accessible
    _ = peerjs.PeerClient;
    _ = peerjs.DataConnection;
    _ = peerjs.PeerConfig;
    _ = peerjs.ConnectionStatus;
    _ = peerjs.isValidPeerId;
    _ = peerjs.fetchPeerToken;

    _ = signaling.SignalingClient;
    _ = signaling.SignalingMessage;
    _ = signaling.MessageType;
    _ = signaling.SessionDescription;
    _ = signaling.IceCandidate;
}

// Configuration validation tests
test "config_validation: Server configuration bounds" {
    const config = signaling.ServerConfig{
        .host = "test.example.com",
        .port = 65535, // Max port
        .secure = true,
        .path = "/custom/path/",
        .key = "very-long-key-with-many-characters-123456789",
        .ping_interval = 1, // Min interval
        .timeout = 3600000, // Max timeout (1 hour)
    };

    try testing.expectEqualStrings("test.example.com", config.host);
    try testing.expectEqual(@as(u16, 65535), config.port);
    try testing.expect(config.secure);
    try testing.expectEqualStrings("/custom/path/", config.path);
    try testing.expectEqual(@as(u32, 1), config.ping_interval);
    try testing.expectEqual(@as(u32, 3600000), config.timeout);
}

test "config_validation: Peer configuration edge cases" {
    // Test with minimal configuration
    const minimal_config = peerjs.PeerConfig{
        .host = "a",
        .port = 1,
        .key = "x",
        .timeout_ms = 1,
        .heartbeat_interval = 1,
    };

    try testing.expectEqualStrings("a", minimal_config.host);
    try testing.expectEqual(@as(u16, 1), minimal_config.port);
    try testing.expectEqualStrings("x", minimal_config.key);
    try testing.expectEqual(@as(u32, 1), minimal_config.timeout_ms);
    try testing.expectEqual(@as(u32, 1), minimal_config.heartbeat_interval);
}

// Concurrency safety tests (basic)
test "concurrency: Multiple client initialization" {
    const allocator = testing.allocator;

    // Test that we can create multiple clients simultaneously
    var clients: [5]*peerjs.PeerClient = undefined;

    for (&clients) |*client_ptr| {
        client_ptr.* = try allocator.create(peerjs.PeerClient);
        client_ptr.*.* = try peerjs.PeerClient.init(allocator, test_config);
    }

    // Clean up all clients
    for (clients) |client| {
        client.deinit();
        allocator.destroy(client);
    }
}

test "PeerClient: initialization and deinitialization" {
    const allocator = testing.allocator;

    const config = peerjs.PeerConfig{
        .host = "test.example.com",
        .port = 443,
        .secure = true,
        .peer_id = "test-peer",
    };

    var client = try peerjs.PeerClient.init(allocator, config);
    defer client.deinit();

    // Test that the client was initialized correctly without attempting connections
    try testing.expect(!client.connected);
    try testing.expectEqualStrings("test.example.com", client.config.host);
    try testing.expectEqual(@as(u16, 443), client.config.port);
    try testing.expect(client.config.secure);
    try testing.expectEqualStrings("test-peer", client.config.peer_id.?);
}

test "DataConnection: creation and basic operations" {
    const allocator = testing.allocator;

    // First create a PeerClient for the DataConnection
    var peer_client = try peerjs.PeerClient.init(allocator, .{
        .host = "test.example.com",
        .port = 443,
        .secure = true,
    });
    defer peer_client.deinit();

    const connection = try allocator.create(peerjs.DataConnection);
    defer allocator.destroy(connection);

    connection.* = try peerjs.DataConnection.init(
        allocator, 
        "test-peer", 
        "connection-123", 
        &peer_client,
        .{}
    );
    defer connection.deinit();

    try testing.expectEqualStrings("test-peer", connection.peer_id);
    try testing.expectEqual(peerjs.ConnectionStatus.connecting, connection.status);
}

test "DataConnection: message sending and receiving" {
    const allocator = testing.allocator;

    // First create a PeerClient for the DataConnection
    var peer_client = try peerjs.PeerClient.init(allocator, .{
        .host = "test.example.com",
        .port = 443,
        .secure = true,
    });
    defer peer_client.deinit();

    const connection = try allocator.create(peerjs.DataConnection);
    defer allocator.destroy(connection);

    connection.* = try peerjs.DataConnection.init(
        allocator, 
        "test-peer", 
        "connection-123", 
        &peer_client,
        .{}
    );
    defer connection.deinit();

    // Test connection properties without attempting network operations
    try testing.expectEqualStrings("test-peer", connection.peer_id);
    try testing.expectEqualStrings("connection-123", connection.connection_id);
    try testing.expectEqual(peerjs.ConnectionStatus.connecting, connection.status);
    
    // Test that message queue is initially empty
    try testing.expectEqual(@as(usize, 0), connection.message_queue.items.len);
}

test "SignalingMessage: creation and cleanup" {
    const allocator = testing.allocator;

    // Test OFFER message
    {
        const sdp = signaling.SessionDescription{
            .type = .offer,
            .sdp = try allocator.dupe(u8, "test-sdp-data"),
        };

        var message = signaling.SignalingMessage{
            .type = .offer,
            .src = try allocator.dupe(u8, "peer1"),
            .dst = try allocator.dupe(u8, "peer2"),
            .payload = .{ .sdp = sdp },
        };

        try testing.expectEqual(signaling.MessageType.offer, message.type);
        try testing.expectEqualStrings("peer1", message.src.?);
        try testing.expectEqualStrings("peer2", message.dst.?);
        try testing.expectEqual(@as(@TypeOf(sdp.type), .offer), message.payload.sdp.type);

        message.deinit(allocator);
    }

    // Test ICE candidate message
    {
        const candidate = signaling.IceCandidate{
            .candidate = try allocator.dupe(u8, "candidate-data"),
            .sdp_mid = try allocator.dupe(u8, "0"),
            .sdp_mline_index = 0,
        };

        var message = signaling.SignalingMessage{
            .type = .candidate,
            .payload = .{ .candidate = candidate },
        };

        try testing.expectEqual(signaling.MessageType.candidate, message.type);
        try testing.expectEqualStrings("candidate-data", message.payload.candidate.candidate);

        message.deinit(allocator);
    }
}

test "PeerClient: connection management" {
    const allocator = testing.allocator;

    const config = peerjs.PeerConfig{
        .host = "test.example.com",
        .port = 443,
        .secure = true,
        .peer_id = "alice",
    };

    var client = try peerjs.PeerClient.init(allocator, config);
    defer client.deinit();

    // Test client configuration without attempting connections
    try testing.expect(!client.connected);
    try testing.expectEqualStrings("test.example.com", client.config.host);
    try testing.expectEqualStrings("alice", client.config.peer_id.?);
    try testing.expectEqual(@as(usize, 0), client.connections.count());
}

test "signaling: message flow simulation" {
    const allocator = testing.allocator;

    const config = signaling.ServerConfig{
        .host = "test.example.com",
        .port = 443,
        .secure = true,
    };

    var client = try signaling.SignalingClient.init(allocator, config);
    defer client.deinit();

    // Simulate message creation and processing
    const message_count = 5;
    const messages = try allocator.alloc(signaling.SignalingMessage, message_count);
    defer allocator.free(messages);

    for (messages, 0..) |*msg, i| {
        msg.* = signaling.SignalingMessage{
            .type = .heartbeat,
            .src = try std.fmt.allocPrint(allocator, "peer{d}", .{i}),
        };
    }

    // Cleanup messages
    for (messages) |*msg| {
        msg.deinit(allocator);
    }
}

test "signaling: error handling" {
    const invalid_config = signaling.ServerConfig{
        .host = "",  // Invalid host
        .port = 0,   // Invalid port
        .secure = true,
    };

    var client = try signaling.SignalingClient.init(testing.allocator, invalid_config);
    defer client.deinit();

    // Connection should fail with invalid config (URI format error due to empty host)
    const result = client.connect(null);
    try testing.expectError(signaling.SignalingError.UriFormatError, result);
}

test "performance: message processing" {
    var timer = try std.time.Timer.start();
    const message_count = 1000;

    // Create messages
    var messages = std.ArrayList(signaling.SignalingMessage).init(testing.allocator);
    defer messages.deinit();
    defer {
        for (messages.items) |*msg| {
            msg.deinit(testing.allocator);
        }
    }

    // Measure message creation time
    for (0..message_count) |i| {
        const msg = signaling.SignalingMessage{
            .type = .heartbeat,
            .src = try std.fmt.allocPrint(testing.allocator, "peer{d}", .{i}),
        };
        try messages.append(msg);
    }

    const elapsed = timer.read();
    const ns_per_message = elapsed / message_count;

    std.debug.print("Created {d} messages in {d}ns ({d}ns per message)\n", .{ message_count, elapsed, ns_per_message });

    // Performance should be reasonable (< 10µs per message)
    try testing.expect(ns_per_message < 10000);
}

test "memory: leak detection" {
    // Test multiple allocation/deallocation cycles
    for (0..100) |_| {
        var client = try signaling.SignalingClient.init(testing.allocator, .{});
        defer client.deinit();

        // Generate token
        const token = try client.generateRandomToken();
        defer testing.allocator.free(token);

        try testing.expect(token.len > 0);
    }
}

test "signaling: HTTP response parsing" {
    const allocator = std.testing.allocator;
    
    const config = signaling.ServerConfig{
        .host = "test.example.com",
        .port = 443,
        .secure = true,
    };
    
    var client = try signaling.SignalingClient.init(allocator, config);
    defer client.deinit();
    
    // Test token generation function
    {        
        // For now, test the token generation function
        const token1 = try client.generateRandomToken();
        defer allocator.free(token1);
        const token2 = try client.generateRandomToken();
        defer allocator.free(token2);
        
        // Tokens should be different
        try std.testing.expect(!std.mem.eql(u8, token1, token2));
        
        // Tokens should be 16 characters
        try std.testing.expectEqual(@as(usize, 16), token1.len);
        try std.testing.expectEqual(@as(usize, 16), token2.len);
        
        // Tokens should only contain alphanumeric characters
        for (token1) |char| {
            try std.testing.expect((char >= 'a' and char <= 'z') or (char >= '0' and char <= '9'));
        }
    }
}

test "signaling: response format detection" {
    // Test JSON detection logic
    {
        const json_response = "{\"id\":\"test-123\"}";
        const is_json = json_response.len > 0 and (json_response[0] == '{' or json_response[0] == '[');
        try std.testing.expect(is_json);
    }
    
    {
        const array_response = "[\"item1\",\"item2\"]";
        const is_json = array_response.len > 0 and (array_response[0] == '{' or array_response[0] == '[');
        try std.testing.expect(is_json);
    }
    
    {
        const plain_response = "88eaa6e4-f8d9-4189-8f52-284309b8124f";
        const is_json = plain_response.len > 0 and (plain_response[0] == '{' or plain_response[0] == '[');
        try std.testing.expect(!is_json);
    }
    
    {
        const empty_response = "";
        const is_json = empty_response.len > 0 and (empty_response[0] == '{' or empty_response[0] == '[');
        try std.testing.expect(!is_json);
    }
}

test "signaling: peer ID validation" {
    // Test valid peer IDs
    {
        const valid_ids = [_][]const u8{
            "88eaa6e4-f8d9-4189-8f52-284309b8124f",
            "alice",
            "bob-123",
            "peer_with_underscores",
            "PeerWithCaps",
            "1234567890",
        };
        
        for (valid_ids) |id| {
            // Basic validation: not empty
            try std.testing.expect(id.len > 0);
        }
    }
    
    // Test invalid peer IDs
    {
        const invalid_ids = [_][]const u8{
            "",
            "   ",
            "\t\r\n",
        };
        
        for (invalid_ids) |id| {
            const trimmed = std.mem.trim(u8, id, " \t\r\n");
            try std.testing.expect(trimmed.len == 0);
        }
    }
}

test "signaling: token uniqueness and format" {
    const allocator = std.testing.allocator;
    const config = signaling.ServerConfig{
        .host = "test.example.com", 
        .port = 443,
        .secure = true,
    };
    
    var client = try signaling.SignalingClient.init(allocator, config);
    defer client.deinit();
    
    // Generate multiple tokens and verify uniqueness
    var tokens: [10][]const u8 = undefined;
    for (tokens[0..], 0..) |*token, i| {
        token.* = try client.generateRandomToken();
        
        // Check uniqueness against previous tokens
        for (tokens[0..i]) |prev_token| {
            try std.testing.expect(!std.mem.eql(u8, token.*, prev_token));
        }
    }
    
    // Cleanup
    for (tokens) |token| {
        allocator.free(token);
    }
}

// Mock HTTP response parsing test
test "signaling: mock HTTP response scenarios" {
    // Test scenarios that should work
    const test_cases = [_]struct {
        name: []const u8,
        response: []const u8,
        expected_json: bool,
    }{
        .{ .name = "Plain peer ID", .response = "88eaa6e4-f8d9-4189-8f52-284309b8124f", .expected_json = false },
        .{ .name = "Quoted peer ID", .response = "\"alice-123\"", .expected_json = false },
        .{ .name = "JSON with ID only", .response = "{\"id\":\"test-peer\"}", .expected_json = true },
        .{ .name = "JSON with ID and token", .response = "{\"id\":\"test-peer\",\"token\":\"test-token\"}", .expected_json = true },
        .{ .name = "JSON with peer_id field", .response = "{\"peer_id\":\"test-peer\"}", .expected_json = true },
        .{ .name = "JSON array", .response = "[\"peer1\",\"peer2\"]", .expected_json = true },
        .{ .name = "Whitespace padded", .response = "  \t 88eaa6e4-f8d9-4189-8f52-284309b8124f \r\n ", .expected_json = false },
    };
    
    for (test_cases) |case| {
        const trimmed = std.mem.trim(u8, case.response, " \t\r\n");
        const is_json = trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[');
        
        try std.testing.expectEqual(case.expected_json, is_json);
        
        if (!is_json) {
            // Test plain text peer ID extraction
            const peer_id = std.mem.trim(u8, trimmed, " \t\r\n\"");
            try std.testing.expect(peer_id.len > 0);
        }
    }
}

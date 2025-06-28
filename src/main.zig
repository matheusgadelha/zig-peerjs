//! PeerJS Connect - Example Usage
//!
//! This example demonstrates how to use the Zig PeerJS client library
//! to connect with PeerJS servers and establish peer-to-peer connections.

const std = @import("std");
const print = std.debug.print;

/// This imports the PeerJS client library
const peerjs = @import("zig_peerjs_connect_lib");

/// Example demonstrating basic PeerJS client usage
fn basicExample(allocator: std.mem.Allocator) !void {
    print("\n=== Basic PeerJS Client Example ===\n", .{});

    // Initialize client with default configuration
    var client = try peerjs.PeerClient.init(allocator, .{
        .debug = 2, // Enable warnings and info logging
    });
    defer client.deinit();

    // Get our peer ID
    const peer_id = try client.getId();
    print("📱 My peer ID: {s}\n", .{peer_id});

    // Demonstrate connecting to another peer (for demo purposes)
    print("🔗 Attempting to connect to a demo peer...\n", .{});

    // Note: In a real scenario, you'd get the target peer ID from user input
    // or through some other mechanism like a QR code, manual entry, etc.
    const demo_target = "demo-peer-12345";

    if (peerjs.isValidPeerId(demo_target)) {
        var connection = client.connect(demo_target) catch |err| switch (err) {
            peerjs.PeerError.InvalidPeerId => {
                print("❌ Invalid peer ID format\n", .{});
                return;
            },
            peerjs.PeerError.PeerUnavailable => {
                print("❌ Target peer is not available\n", .{});
                return;
            },
            peerjs.PeerError.ConnectionFailed => {
                print("❌ Failed to establish connection\n", .{});
                return;
            },
            else => return err,
        };
        defer connection.deinit();

        print("✅ Connected to peer: {s}\n", .{demo_target});

        // Send a message
        connection.send("Hello from Zig!") catch |err| switch (err) {
            peerjs.PeerError.Disconnected => {
                print("❌ Cannot send: peer disconnected\n", .{});
                return;
            },
            else => return err,
        };

        print("📤 Sent message to peer\n", .{});

        // In a real application, you'd have a loop here to handle incoming messages
        print("📥 Listening for messages... (TODO: implement receive loop)\n", .{});

        // Close connection
        connection.close();
        print("🔒 Connection closed\n", .{});
    } else {
        print("❌ Demo peer ID format is invalid\n", .{});
    }
}

/// Example demonstrating custom configuration
fn configExample(allocator: std.mem.Allocator) !void {
    print("\n=== Custom Configuration Example ===\n", .{});

    // Create client with custom configuration
    var client = try peerjs.PeerClient.init(allocator, .{
        .host = "localhost", // Use local PeerJS server
        .port = 9000, // Custom port
        .secure = false, // Use HTTP instead of HTTPS
        .key = "custom-key", // Custom API key
        .peer_id = "my-custom-id", // Use specific peer ID
        .debug = 3, // Enable all logging
    });
    defer client.deinit();

    print("🔧 Client configured with custom settings\n", .{});

    const peer_id = client.getId() catch |err| switch (err) {
        peerjs.PeerError.ConnectionFailed => {
            print("❌ Cannot connect to custom server (this is expected in demo)\n", .{});
            return;
        },
        peerjs.PeerError.InvalidPeerId => {
            print("❌ Custom peer ID is invalid\n", .{});
            return;
        },
        else => return err,
    };

    print("📱 Custom peer ID: {s}\n", .{peer_id});
}

/// Example demonstrating error handling
fn errorHandlingExample(allocator: std.mem.Allocator) !void {
    print("\n=== Error Handling Example ===\n", .{});

    // Try to create client with invalid configuration
    const invalid_client = peerjs.PeerClient.init(allocator, .{
        .peer_id = "-invalid-id-", // Invalid ID format
    });

    if (invalid_client) |_| {
        print("❌ This should not succeed!\n", .{});
    } else |err| switch (err) {
        peerjs.PeerError.InvalidPeerId => {
            print("✅ Correctly caught invalid peer ID error\n", .{});
        },
        else => {
            print("❌ Unexpected error: {}\n", .{err});
            return err;
        },
    }

    // Test peer ID validation
    print("🧪 Testing peer ID validation:\n", .{});
    const test_ids = [_][]const u8{
        "valid123", // Valid
        "test-peer_01", // Valid
        "", // Invalid: empty
        "-starts-with-dash", // Invalid: starts with dash
        "ends-with-dash-", // Invalid: ends with dash
        "has@special!chars", // Invalid: special characters
    };

    for (test_ids) |id| {
        const is_valid = peerjs.isValidPeerId(id);
        const status = if (is_valid) "✅ VALID" else "❌ INVALID";
        print("  '{s}' -> {s}\n", .{ id, status });
    }
}

/// Compatibility function from original code
pub fn fetchPeerToken(allocator: std.mem.Allocator) !std.ArrayList(u8) {
    return peerjs.fetchPeerToken(allocator);
}

/// Main function demonstrating various PeerJS client features
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("🚀 Zig PeerJS Client Demo\n", .{});
    print("=========================\n", .{});

    // Run basic example
    basicExample(allocator) catch |err| {
        print("❌ Basic example failed: {}\n", .{err});
    };

    // Run configuration example
    configExample(allocator) catch |err| {
        print("❌ Config example failed: {}\n", .{err});
    };

    // Run error handling example
    errorHandlingExample(allocator) catch |err| {
        print("❌ Error handling example failed: {}\n", .{err});
    };

    // Demonstrate original token fetching for compatibility
    print("\n=== Legacy Token Fetch ===\n", .{});
    const token = fetchPeerToken(allocator) catch |err| {
        print("❌ Failed to fetch token: {}\n", .{err});
        return;
    };
    defer token.deinit();

    print("🎫 Fetched token: {s}\n", .{token.items});

    print("\n✨ Demo completed!\n", .{});
}

// Tests
test "main functionality" {
    // Test basic client creation
    var client = try peerjs.PeerClient.init(std.testing.allocator, .{});
    defer client.deinit();

    // Test peer ID validation
    try std.testing.expect(peerjs.isValidPeerId("test123"));
    try std.testing.expect(!peerjs.isValidPeerId(""));
}

test "token fetching compatibility" {
    // This test might fail if network is unavailable, which is expected
    const token = peerjs.fetchPeerToken(std.testing.allocator) catch |err| switch (err) {
        peerjs.PeerError.ConnectionFailed, peerjs.PeerError.NetworkError => {
            // Network errors are expected in testing environment
            return;
        },
        else => return err,
    };
    defer token.deinit();

    try std.testing.expect(token.items.len > 0);
}

test "error handling" {
    // Test invalid peer ID
    const result = peerjs.PeerClient.init(std.testing.allocator, .{
        .peer_id = "-invalid-",
    });

    try std.testing.expectError(peerjs.PeerError.InvalidPeerId, result);
}

test "use other module" {
    // Keep the original test for compatibility
    try std.testing.expectEqual(@as(i32, 150), peerjs.add(100, 50));
}

test "fuzz example" {
    // Keep the original fuzz test
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}

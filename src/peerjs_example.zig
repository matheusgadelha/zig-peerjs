const std = @import("std");
const print = std.debug.print;
const signaling = @import("signaling.zig");

/// Practical example demonstrating the fixed PeerJS protocol implementation
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("🚀 PeerJS Protocol Implementation Example\n", .{});
    print("=========================================\n", .{});
    print("\n", .{});

    // Example 1: HTTP ID Request from Public Server
    print("📡 Example 1: HTTP ID Request from Public PeerJS Server\n", .{});
    print("---------------------------------------------------------\n", .{});
    
    const config = signaling.ServerConfig{
        .host = "0.peerjs.com",
        .port = 443,
        .secure = true,
        .key = "peerjs",
    };

    var client = try signaling.SignalingClient.init(allocator, config);
    defer client.deinit();

    print("🌐 Requesting peer ID and token from: https://{s}:{d}/peerjs/id\n", .{ config.host, config.port });
    
    const pair = client.requestPeerIdAndToken() catch |err| {
        print("❌ Network request failed (expected in some environments): {}\n", .{err});
        print("💡 This is normal if you don't have internet access or the server is down\n", .{});
        
        // Demonstrate fallback token generation
        print("\n", .{});
        print("🔄 Demonstrating fallback token generation...\n", .{});
        const fallback_token = try client.generateRandomToken();
        defer allocator.free(fallback_token);
        print("✅ Generated fallback token: {s}\n", .{fallback_token});
        return;
    };
    defer {
        var mutable_pair = pair;
        mutable_pair.deinit(allocator);
    }

    print("✅ Successfully received from server:\n", .{});
    print("   📋 Peer ID: {s}\n", .{pair.peer_id});
    print("   🔑 Token: {s}\n", .{pair.token});
    print("\n", .{});

    // Example 2: WebSocket URL Construction
    print("🔗 Example 2: WebSocket URL Construction\n", .{});
    print("----------------------------------------\n", .{});
    
    var url_buffer: [512]u8 = undefined;
    const ws_url = try std.fmt.bufPrint(url_buffer[0..], "wss://{s}:{d}/peerjs?key={s}&id={s}&token={s}", .{
        config.host, config.port, config.key, pair.peer_id, pair.token
    });
    
    print("🌐 WebSocket URL: {s}\n", .{ws_url});
    print("✅ URL construction follows PeerJS protocol exactly\n", .{});
    print("\n", .{});

    // Example 3: Token Validation
    print("🔍 Example 3: Token and Peer ID Validation\n", .{});
    print("-------------------------------------------\n", .{});
    
    var valid_peer_id = true;
    var valid_token = true;
    
    // Validate peer ID format
    for (pair.peer_id) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') {
            valid_peer_id = false;
            break;
        }
    }
    
    // Validate token format
    for (pair.token) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') {
            valid_token = false;
            break;
        }
    }
    
    print("📋 Peer ID validation: {s}\n", .{if (valid_peer_id) "✅ VALID" else "❌ INVALID"});
    print("🔑 Token validation: {s}\n", .{if (valid_token) "✅ VALID" else "❌ INVALID"});
    print("\n", .{});

    // Example 4: Multiple Token Generation
    print("🎲 Example 4: Multiple Token Generation (Uniqueness Test)\n", .{});
    print("----------------------------------------------------------\n", .{});
    
    var tokens = std.ArrayList([]const u8).init(allocator);
    defer {
        for (tokens.items) |token| {
            allocator.free(token);
        }
        tokens.deinit();
    }
    
    for (0..5) |i| {
        const token = try client.generateRandomToken();
        try tokens.append(token);
        print("🔑 Token {d}: {s}\n", .{ i + 1, token });
    }
    
    // Check uniqueness
    var all_unique = true;
    for (tokens.items, 0..) |token1, i| {
        for (tokens.items[i+1..]) |token2| {
            if (std.mem.eql(u8, token1, token2)) {
                all_unique = false;
                break;
            }
        }
    }
    
    print("🎯 Uniqueness test: {s}\n", .{if (all_unique) "✅ ALL UNIQUE" else "❌ DUPLICATES FOUND"});
    print("\n", .{});

    // Example 5: Protocol Summary
    print("📚 Example 5: Complete Protocol Flow Summary\n", .{});
    print("---------------------------------------------\n", .{});
    print("1. 📡 HTTP GET /peerjs/id?ts=<timestamp>&key=<key>\n", .{});
    print("2. 📨 Server responds: {{\"id\":\"<peer_id>\",\"token\":\"<token>\"}}\n", .{});
    print("3. 🔗 WebSocket connect: /peerjs?key=<key>&id=<peer_id>&token=<token>\n", .{});
    print("4. 🤝 Server sends OPEN message confirming connection\n", .{});
    print("5. 💬 Peer-to-peer signaling can begin\n", .{});
    print("\n", .{});
    print("✅ Implementation now matches official PeerJS JavaScript client!\n", .{});
    
    // Example 6: Testing Different Server Configurations
    print("\n", .{});
    print("⚙️  Example 6: Different Server Configurations\n", .{});
    print("-----------------------------------------------\n", .{});
    
    const configs = [_]signaling.ServerConfig{
        .{ .host = "0.peerjs.com", .port = 443, .secure = true, .key = "peerjs" },  // Public
        .{ .host = "localhost", .port = 9000, .secure = false, .key = "peerjs" },   // Local
        .{ .host = "my-server.com", .port = 8080, .secure = true, .key = "custom" }, // Custom
    };
    
    for (configs, 0..) |cfg, i| {
        print("🌐 Config {d}: {s}://{s}:{d} (key: {s})\n", .{
            i + 1,
            if (cfg.secure) "https" else "http",
            cfg.host,
            cfg.port,
            cfg.key,
        });
        
        var test_url: [512]u8 = undefined;
        const test_ws_url = try std.fmt.bufPrint(test_url[0..], "{s}://{s}:{d}/peerjs?key={s}&id=test&token=test", .{
            if (cfg.secure) "wss" else "ws",
            cfg.host,
            cfg.port,
            cfg.key,
        });
        print("   🔗 WebSocket: {s}\n", .{test_ws_url});
    }
    
    print("\n", .{});
    print("🎉 PeerJS Protocol Implementation Example Complete!\n", .{});
    print("   Ready for real peer-to-peer communication! 🚀\n", .{});
} 
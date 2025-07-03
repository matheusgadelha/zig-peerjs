const std = @import("std");
const print = std.debug.print;
const peerjs = @import("zig_peerjs_connect_lib");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        print("Usage: {s} <server_id>\n", .{args[0]});
        print("Example: {s} my-server-123\n", .{args[0]});
        return;
    }

    const server_id = args[1];

    print("🖥️  Starting PeerJS Server\n", .{});
    print("========================\n", .{});
    print("Server ID: {s}\n", .{server_id});
    print("Waiting for connections...\n\n", .{});

    // Create PeerJS client with the server ID
    var peer_client = peerjs.PeerClient.init(allocator, .{
        .peer_id = server_id,
        .debug = 2, // Enable warnings and info logging for debugging
    }) catch |err| {
        print("❌ Failed to initialize PeerJS client: {}\n", .{err});
        print("🔍 Debug: Server ID '{s}' may be invalid\n", .{server_id});
        return;
    };
    defer peer_client.deinit();

    // Connect to the PeerJS server
    peer_client.connect() catch |err| {
        print("❌ Failed to connect to PeerJS server: {}\n", .{err});
        print("🔍 Debug: Check internet connection, server: {s}:{d}\n", .{ peer_client.config.host, peer_client.config.port });
        return;
    };

    print("✅ Connected to PeerJS server with ID: {s}\n", .{server_id});
    print("🔗 Listening on PeerJS server: {s}:{d}\n", .{ peer_client.config.host, peer_client.config.port });
    print("📡 Waiting for connections...\n\n", .{});

    // Main loop - check for incoming connections and messages
    var receive_buffer: [1024]u8 = undefined;
    
    while (true) {
        // Process incoming signaling messages to handle new connections
        peer_client.handleIncomingMessages() catch |err| {
            if (err != peerjs.PeerError.NoMessages) {
                print("⚠️  Error processing messages: {}\n", .{err});
            }
        };

        // Check all existing connections for incoming messages
        var connection_iter = peer_client.connections.iterator();
        while (connection_iter.next()) |entry| {
            const connection = entry.value_ptr.*;
            if (connection.status == .open) {
                if (connection.receive(receive_buffer[0..])) |data| {
                    print("📥 Message from {s}: {s}\n", .{ connection.peer_id, data });
                    print("🕐 Received at: {d}\n", .{std.time.timestamp()});
                } else |err| {
                    if (err != peerjs.PeerError.NoMessages) {
                        print("⚠️  Error receiving from {s}: {}\n", .{ connection.peer_id, err });
                    }
                }
            }
        }

        // Sleep for a short time to avoid busy waiting
        std.time.sleep(100 * std.time.ns_per_ms); // 100ms
    }
} 
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

    if (args.len != 3) {
        print("Usage: {s} <client_id> <server_id>\n", .{args[0]});
        print("Example: {s} my-client-456 my-server-123\n", .{args[0]});
        return;
    }

    const client_id = args[1];
    const server_id = args[2];

    print("📱 Starting PeerJS Client\n", .{});
    print("=========================\n", .{});
    print("Client ID: {s}\n", .{client_id});
    print("Server ID: {s}\n", .{server_id});
    print("Connecting to server...\n\n", .{});

    // Create PeerJS client with the client ID
    var peer_client = peerjs.PeerClient.init(allocator, .{
        .peer_id = client_id,
        .debug = 2, // Enable warnings and info logging for debugging
    }) catch |err| {
        print("❌ Failed to initialize PeerJS client: {}\n", .{err});
        print("🔍 Debug: Client ID '{s}' may be invalid\n", .{client_id});
        return;
    };
    defer peer_client.deinit();

    // Connect to the PeerJS server
    peer_client.connect() catch |err| {
        print("❌ Failed to connect to PeerJS server: {}\n", .{err});
        print("🔍 Debug: Check your internet connection and PeerJS server status\n", .{});
        return;
    };
    
    print("✅ Connected to PeerJS server\n", .{});

    // Connect to the server peer
    var connection = peer_client.connectToPeer(server_id) catch |err| switch (err) {
        peerjs.PeerError.InvalidPeerId => {
            print("❌ Invalid server ID format: {s}\n", .{server_id});
            return;
        },
        peerjs.PeerError.PeerUnavailable => {
            print("❌ Server is not available: {s}\n", .{server_id});
            print("💡 Make sure the server is running first\n", .{});
            return;
        },
        peerjs.PeerError.ConnectionFailed => {
            print("❌ Failed to connect to server: {s}\n", .{server_id});
            print("🔍 Debug: Server may not be running or network issues\n", .{});
            return;
        },
        else => return err,
    };
    defer connection.deinit();

    print("✅ Connected to server: {s}\n", .{server_id});
    print("💬 Type messages and press Enter to send (Ctrl+C to quit)\n", .{});
    print("───────────────────────────────────────────────────────\n\n", .{});

    // Wait a moment for connection to stabilize
    std.time.sleep(2 * std.time.ns_per_s);

    // Read input and send messages
    const stdin = std.io.getStdIn().reader();
    var input_buffer: [1024]u8 = undefined;
    var message_count: u32 = 0;

    print("📝 Reading input...\n", .{});
    
    while (true) {
        // Read user input (works with both interactive and piped input)
        if (try stdin.readUntilDelimiterOrEof(input_buffer[0..], '\n')) |input| {
            // Trim whitespace and newline
            const message = std.mem.trim(u8, input, " \t\r\n");
            
            if (message.len == 0) {
                continue; // Skip empty messages
            }

            // Send message to server
            connection.send(message) catch |err| switch (err) {
                peerjs.PeerError.Disconnected => {
                    print("❌ Connection to server lost\n", .{});
                    return;
                },
                else => {
                    print("❌ Error sending message: {}\n", .{err});
                    continue;
                },
            };

            print("📤 Sent: {s}\n", .{message});
            message_count += 1;
            
            // Small delay to ensure message is processed
            std.time.sleep(500 * std.time.ns_per_ms);
        } else {
            // EOF reached - exit gracefully
            break;
        }
    }
    
    if (message_count > 0) {
        print("✅ Sent {d} message(s) successfully\n", .{message_count});
        // Wait a bit more to ensure messages are delivered
        std.time.sleep(2 * std.time.ns_per_s);
    } else {
        print("ℹ️  No messages sent\n", .{});
    }
} 
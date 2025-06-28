//! Zig PeerJS Chat Demo
//!
//! This program demonstrates bidirectional communication between two peers.
//! Run two instances with different peer IDs to see them communicate.
//!
//! Usage:
//!   zig_peerjs_chat [my_peer_id] [target_peer_id]
//!
//! If no arguments provided, it will generate a peer ID and wait for target input.

const std = @import("std");
const print = std.debug.print;
const peerjs = @import("zig_peerjs_connect_lib");

const ChatConfig = struct {
    my_peer_id: ?[]const u8 = null,
    target_peer_id: ?[]const u8 = null,
    debug: bool = false,
};

fn parseArgs(allocator: std.mem.Allocator, args: [][:0]u8) !ChatConfig {
    var config = ChatConfig{};

    if (args.len >= 2) {
        config.my_peer_id = try allocator.dupe(u8, args[1]);
    }
    if (args.len >= 3) {
        config.target_peer_id = try allocator.dupe(u8, args[2]);
    }

    // Check for debug flag
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
            config.debug = true;
        }
    }

    return config;
}

fn printUsage() void {
    print("🗣️  Zig PeerJS Chat Demo\n", .{});
    print("========================\n", .{});
    print("\n", .{});
    print("Usage:\n", .{});
    print("  zig_peerjs_chat [my_peer_id] [target_peer_id] [--debug]\n", .{});
    print("\n", .{});
    print("Examples:\n", .{});
    print("  zig_peerjs_chat                    # Auto-generate ID, ask for target\n", .{});
    print("  zig_peerjs_chat alice bob          # Chat as 'alice' with 'bob'\n", .{});
    print("  zig_peerjs_chat alice bob --debug  # Enable debug logging\n", .{});
    print("\n", .{});
}

fn getUserInput(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    print("{s}", .{prompt});

    const stdin = std.io.getStdIn().reader();
    const input = try stdin.readUntilDelimiterAlloc(allocator, '\n', 256);
    defer allocator.free(input);

    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

fn chatLoop(allocator: std.mem.Allocator, connection: *peerjs.DataConnection, my_id: []const u8, target_id: []const u8) !void {
    print("\n", .{});
    print("🎉 Chat started between {s} and {s}\n", .{ my_id, target_id });
    print("💡 Type messages and press Enter to send\n", .{});
    print("💡 Type 'quit' to exit\n", .{});
    print("💡 Messages from {s} will appear automatically\n", .{target_id});
    print("─────────────────────────────────────────────\n", .{});

    // Main chat loop
    while (true) {
        // Check for incoming messages
        var buffer: [1024]u8 = undefined;
        if (connection.receive(buffer[0..])) |received_data| {
            print("👤 {s}: {s}\n", .{ target_id, received_data });
        } else |err| switch (err) {
            peerjs.PeerError.NoMessages => {
                // No messages, that's fine
            },
            peerjs.PeerError.Disconnected => {
                print("❌ Connection lost!\n", .{});
                break;
            },
            else => {
                print("❌ Error receiving message: {}\n", .{err});
            },
        }

        // Check if stdin has data available (non-blocking)
        // For simplicity, we'll use a timeout-based approach
        std.time.sleep(100 * std.time.ns_per_ms); // 100ms

        // Try to read input (this is a simplified approach)
        // In a real application, you might want to use proper async I/O
        const stdin = std.io.getStdIn();
        var poll_fd = [_]std.posix.pollfd{
            .{ .fd = stdin.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };

        const poll_result = std.posix.poll(&poll_fd, 0) catch continue;
        if (poll_result > 0 and (poll_fd[0].revents & std.posix.POLL.IN) != 0) {
            // Input available, read it
            const input = getUserInput(allocator, "") catch |err| {
                print("❌ Input error: {}\n", .{err});
                continue;
            };
            defer allocator.free(input);

            if (input.len == 0) continue;

            if (std.mem.eql(u8, input, "quit")) {
                print("👋 Goodbye!\n", .{});
                break;
            }

            // Send message
            connection.send(input) catch |err| {
                print("❌ Failed to send message: {}\n", .{err});
                continue;
            };

            print("✅ {s}: {s}\n", .{ my_id, input });
        }
    }
}

// Simpler version without polling for better compatibility
fn simpleChatLoop(allocator: std.mem.Allocator, connection: *peerjs.DataConnection, my_id: []const u8, target_id: []const u8) !void {
    print("\n", .{});
    print("🎉 Chat started between {s} and {s}\n", .{ my_id, target_id });
    print("💡 Type messages and press Enter to send\n", .{});
    print("💡 Type 'quit' to exit\n", .{});
    print("💡 Type 'check' to check for new messages\n", .{});
    print("─────────────────────────────────────────────\n", .{});

    while (true) {
        const input = getUserInput(allocator, "💬 Message (or 'check'/'quit'): ") catch |err| {
            print("❌ Input error: {}\n", .{err});
            continue;
        };
        defer allocator.free(input);

        if (input.len == 0) continue;

        if (std.mem.eql(u8, input, "quit")) {
            print("👋 Goodbye!\n", .{});
            break;
        }

        if (std.mem.eql(u8, input, "check")) {
            // Check for messages
            var buffer: [1024]u8 = undefined;
            var message_count: u32 = 0;

            while (true) {
                if (connection.receive(buffer[0..])) |received_data| {
                    print("📨 {s}: {s}\n", .{ target_id, received_data });
                    message_count += 1;
                } else |err| switch (err) {
                    peerjs.PeerError.NoMessages => break,
                    else => {
                        print("❌ Error receiving: {}\n", .{err});
                        break;
                    },
                }
            }

            if (message_count == 0) {
                print("📭 No new messages\n", .{});
            } else {
                print("📬 Received {d} message(s)\n", .{message_count});
            }
            continue;
        }

        // Send message
        connection.send(input) catch |err| {
            print("❌ Failed to send message: {}\n", .{err});
            continue;
        };

        print("✅ You: {s}\n", .{input});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = parseArgs(allocator, args) catch {
        printUsage();
        return;
    };
    defer {
        if (config.my_peer_id) |id| allocator.free(id);
        if (config.target_peer_id) |id| allocator.free(id);
    }

    printUsage();

    // Create PeerJS client
    var client = try peerjs.PeerClient.init(allocator, .{
        .peer_id = config.my_peer_id,
        .debug = if (config.debug) 3 else 1,
    });
    defer client.deinit();

    // Get our peer ID
    const my_id = try client.getId();
    print("🆔 Your peer ID: {s}\n", .{my_id});

    // Get target peer ID
    const target_id: []u8 = if (config.target_peer_id) |provided_target|
        try allocator.dupe(u8, provided_target)
    else
        try getUserInput(allocator, "🎯 Enter target peer ID: ");
    defer allocator.free(target_id);

    if (target_id.len == 0 or std.mem.eql(u8, target_id, my_id)) {
        print("❌ Invalid target peer ID\n", .{});
        return;
    }

    print("🔗 Connecting to {s}...\n", .{target_id});

    // Connect to target peer
    var connection = client.connect(target_id) catch |err| {
        print("❌ Failed to connect to {s}: {}\n", .{ target_id, err });
        return;
    };
    defer connection.deinit();

    print("✅ Connected to {s}\n", .{target_id});

    // Send initial hello message
    const hello_msg = try std.fmt.allocPrint(allocator, "Hello from {s}! 👋", .{my_id});
    defer allocator.free(hello_msg);

    connection.send(hello_msg) catch |err| {
        print("❌ Failed to send hello message: {}\n", .{err});
    };

    // Start chat loop
    try simpleChatLoop(allocator, connection, my_id, target_id);
}

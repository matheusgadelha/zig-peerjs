//! Zig PeerJS Chat Demo - Public Server Implementation
//!
//! This program demonstrates bidirectional communication between two peers using WebRTC
//! with the working PeerJS protocol implementation that includes:
//! - Working HTTP ID requests to 0.peerjs.com
//! - Proper token handling from server responses
//! - Correct WebSocket URL format matching JavaScript client
//!
//! Usage:
//!   zig_peerjs_chat [options] [my_peer_id] [target_peer_id]
//!
//! Examples:
//!   zig_peerjs_chat                          # Auto-generate ID via HTTP request
//!   zig_peerjs_chat alice bob                # Connect as 'alice' to 'bob'
//!   zig_peerjs_chat alice bob --debug        # Enable debug logging

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

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
            config.debug = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.ShowHelp;
        } else if (config.my_peer_id == null) {
            config.my_peer_id = try allocator.dupe(u8, arg);
        } else if (config.target_peer_id == null) {
            config.target_peer_id = try allocator.dupe(u8, arg);
        } else {
            print("❌ Unknown argument: {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }

    return config;
}

fn printUsage() void {
    print("🗣️  Zig PeerJS Chat Demo - Public Server\n", .{});
    print("=========================================\n", .{});
    print("\n", .{});
    print("✅ Working Implementation:\n", .{});
    print("  • HTTP ID request from 0.peerjs.com (WORKING)\n", .{});
    print("  • Proper token handling from server responses\n", .{});
    print("  • WebSocket URL format matching JavaScript client\n", .{});
    print("  • Real peer-to-peer communication via public server\n", .{});
    print("\n", .{});
    print("Usage:\n", .{});
    print("  zig_peerjs_chat [options] [my_peer_id] [target_peer_id]\n", .{});
    print("\n", .{});
    print("Options:\n", .{});
    print("  --debug, -d    Enable debug logging\n", .{});
    print("  --help, -h     Show this help message\n", .{});
    print("\n", .{});
    print("Examples:\n", .{});
    print("  zig_peerjs_chat                          # Auto-generate ID via HTTP\n", .{});
    print("  zig_peerjs_chat alice bob                # Connect 'alice' to 'bob'\n", .{});
    print("  zig_peerjs_chat alice bob --debug        # With debug logging\n", .{});
    print("\n", .{});
    print("💡 Protocol Status:\n", .{});
    print("  ✅ HTTP ID request: https://0.peerjs.com/peerjs/id\n", .{});
    print("  ✅ Token generation: From server + fallback\n", .{});
    print("  ✅ WebSocket: wss://0.peerjs.com/peerjs?key=peerjs&id=<peer>&token=<token>\n", .{});
    print("  ✅ Peer discovery: Real-time via PeerJS protocol\n", .{});
    print("\n", .{});
}

fn getUserInput(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    print("{s}", .{prompt});
    
    // Flush stdout to ensure prompt appears immediately
    const stdout = std.io.getStdOut();
    stdout.sync() catch {};

    const stdin = std.io.getStdIn().reader();
    const input = try stdin.readUntilDelimiterAlloc(allocator, '\n', 256);
    defer allocator.free(input);

    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

const ChatSession = struct {
    allocator: std.mem.Allocator,
    peer_client: *peerjs.PeerClient,
    connection: ?*peerjs.DataConnection,
    my_id: []const u8,
    target_id: ?[]const u8,
    should_exit: bool,
    skip_message_check: bool, // Skip message checking for the first few iterations

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, peer_client: *peerjs.PeerClient, my_id: []const u8) Self {
        return Self{
            .allocator = allocator,
            .peer_client = peer_client,
            .connection = null,
            .my_id = my_id,
            .target_id = null,
            .should_exit = false,
            .skip_message_check = false,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.connection) |conn| {
            conn.close();
            conn.deinit();
            self.allocator.destroy(conn);
        }
        if (self.target_id) |target| {
            self.allocator.free(target);
        }
    }

    pub fn connectToPeer(self: *Self, target_peer_id: []const u8) !void {
        if (!peerjs.isValidPeerId(target_peer_id)) {
            return error.InvalidPeerId;
        }

        print("🔗 Connecting to peer: {s}\n", .{target_peer_id});

        // First ensure our peer client is connected to the signaling server
        if (!self.peer_client.connected) {
            print("⚠️  Peer client not connected to server, attempting to connect...\n", .{});
            self.peer_client.connect() catch |err| {
                print("❌ Failed to connect to signaling server: {}\n", .{err});
                return error.ConnectionFailed;
            };
        }

        self.connection = self.peer_client.connectToPeer(target_peer_id) catch |err| switch (err) {
            peerjs.PeerError.InvalidPeerId => {
                print("❌ Invalid peer ID format: {s}\n", .{target_peer_id});
                return error.InvalidPeerId;
            },
            peerjs.PeerError.PeerUnavailable => {
                print("❌ Target peer is not available: {s}\n", .{target_peer_id});
                return error.PeerUnavailable;
            },
            peerjs.PeerError.ConnectionFailed => {
                print("❌ Failed to establish connection with: {s}\n", .{target_peer_id});
                return error.ConnectionFailed;
            },
            else => return err,
        };

        // Verify the connection was actually created and check its status
        if (self.connection == null) {
            print("❌ Connection object is null after connection attempt\n", .{});
            return error.ConnectionFailed;
        }

        const conn = self.connection.?;
        print("🔍 Connection status: {s}\n", .{switch (conn.status) {
            .connecting => "Connecting",
            .open => "Open",
            .closing => "Closing", 
            .closed => "Closed",
            .failed => "Failed",
        }});

        // Check if connection is in a usable state
        switch (conn.status) {
            .open => {
                self.target_id = try self.allocator.dupe(u8, target_peer_id);
                self.skip_message_check = true; // Skip message checking for the first few iterations
                print("✅ Connected to peer: {s}\n", .{target_peer_id});
            },
            .connecting => {
                // Give it a moment to establish, then check again
                print("⏳ Connection is establishing, waiting...\n", .{});
                std.time.sleep(1000 * std.time.ns_per_ms); // Wait 1 second
                
                if (conn.status == .open) {
                    self.target_id = try self.allocator.dupe(u8, target_peer_id);
                    self.skip_message_check = true; // Skip message checking for the first few iterations
                    print("✅ Connected to peer: {s}\n", .{target_peer_id});
                } else {
                    print("❌ Connection failed to establish within timeout\n", .{});
                    print("💡 Current status: {s}\n", .{switch (conn.status) {
                        .connecting => "Still connecting",
                        .open => "Open",
                        .closing => "Closing",
                        .closed => "Closed", 
                        .failed => "Failed",
                    }});
                    
                    // Clean up the failed connection
                    conn.close();
                    conn.deinit();
                    self.allocator.destroy(conn);
                    self.connection = null;
                    
                    return error.ConnectionFailed;
                }
            },
            .closed, .failed => {
                print("❌ Connection is in failed state: {s}\n", .{switch (conn.status) {
                    .closed => "Closed",
                    .failed => "Failed",
                    else => "Unknown",
                }});
                
                // Clean up the failed connection
                conn.close();
                conn.deinit();
                self.allocator.destroy(conn);
                self.connection = null;
                
                return error.ConnectionFailed;
            },
            .closing => {
                print("❌ Connection is closing, cannot use\n", .{});
                return error.ConnectionFailed;
            },
        }
    }

    pub fn sendMessage(self: *Self, message: []const u8) !void {
        if (self.connection == null) {
            return error.NotConnected;
        }

        const conn = self.connection.?;
        
        // Check connection status before attempting to send
        switch (conn.status) {
            .open => {
                // Connection is ready, proceed with sending
            },
            .connecting => {
                print("❌ Cannot send: connection is still establishing\n", .{});
                print("💡 Try again in a moment, or use 'status' to check connection state\n", .{});
                return error.NotConnected;
            },
            .closed => {
                print("❌ Cannot send: connection is closed\n", .{});
                print("💡 Use 'connect <peer-id>' to establish a new connection\n", .{});
                return error.Disconnected;
            },
            .failed => {
                print("❌ Cannot send: connection failed\n", .{});
                print("💡 Use 'connect <peer-id>' to establish a new connection\n", .{});
                return error.Disconnected;
            },
            .closing => {
                print("❌ Cannot send: connection is closing\n", .{});
                return error.Disconnected;
            },
        }

        conn.send(message) catch |err| switch (err) {
            peerjs.PeerError.Disconnected => {
                print("❌ Cannot send: peer disconnected\n", .{});
                print("💡 Connection status changed to disconnected\n", .{});
                return error.Disconnected;
            },
            peerjs.PeerError.ConnectionFailed => {
                print("❌ Cannot send: signaling connection failed\n", .{});
                print("💡 Check your internet connection and try reconnecting\n", .{});
                return error.ConnectionFailed;
            },
            peerjs.PeerError.InvalidData => {
                print("❌ Cannot send: message format is invalid\n", .{});
                return error.InvalidData;
            },
            else => {
                print("❌ Send failed with error: {}\n", .{err});
                return err;
            }
        };

        print("✅ You: {s}\n", .{message});
    }

    pub fn checkForMessages(self: *Self) !void {
        if (self.connection == null) return;

        var buffer: [4096]u8 = undefined;
        var message_count: u32 = 0;
        const max_messages_per_check = 10; // Prevent infinite loop

        while (message_count < max_messages_per_check) {
            const received_data = self.connection.?.receive(buffer[0..]) catch |err| switch (err) {
                peerjs.PeerError.NoMessages => {
                    // No more messages, exit loop normally
                    break;
                },
                peerjs.PeerError.Disconnected => {
                    print("❌ Connection lost with peer!\n", .{});
                    self.should_exit = true;
                    break;
                },
                peerjs.PeerError.BufferTooSmall => {
                    print("❌ Received message too large for buffer\n", .{});
                    message_count += 1;
                    continue;
                },
                else => {
                    // For other errors, log and break to prevent hanging
                    print("⚠️ Error receiving messages: {}\n", .{err});
                    break;
                },
            };

            // Successfully received a message
            if (self.target_id) |target| {
                print("📨 {s}: {s}\n", .{ target, received_data });
            } else {
                print("📨 Peer: {s}\n", .{received_data});
            }
            
            message_count += 1;
        }

        // Process any incoming signaling messages (with error handling)
        self.peer_client.handleIncomingMessages() catch |err| {
            // Don't let signaling errors prevent the chat from continuing
            if (self.peer_client.config.debug >= 1) {
                print("⚠️ Signaling message processing error: {}\n", .{err});
            }
        };
    }
};

fn runInteractiveChat(allocator: std.mem.Allocator, session: *ChatSession) !void {
    print("\n", .{});
    print("🎉 Chat session started!\n", .{});
    print("💡 Commands:\n", .{});
    print("   - Type messages and press Enter to send\n", .{});
    print("   - Type 'connect <peer-id>' to connect to a peer\n", .{});
    print("   - Type 'check' to check for new messages\n", .{});
    print("   - Type 'status' to show connection status\n", .{});
    print("   - Type 'quit' to exit\n", .{});
    print("─────────────────────────────────────────────\n", .{});

    while (!session.should_exit) {
        // Check for incoming messages automatically, but skip if we just connected
        if (session.skip_message_check) {
            session.skip_message_check = false; // Only skip once
            if (session.peer_client.config.debug >= 3) {
                print("🔍 Skipping message check (just connected)\n", .{});
            }
        } else {
            if (session.peer_client.config.debug >= 3) {
                print("🔍 Checking for messages...\n", .{});
            }
            
            session.checkForMessages() catch |err| {
                print("❌ Error checking messages: {}\n", .{err});
            };
        }

        if (session.peer_client.config.debug >= 3) {
            print("🔍 Getting user input...\n", .{});
        }

        // Get user input
        const input = getUserInput(allocator, "💬 > ") catch |err| {
            print("❌ Input error: {}\n", .{err});
            continue;
        };
        defer allocator.free(input);

        if (input.len == 0) continue;

        // Handle commands
        if (std.mem.eql(u8, input, "quit")) {
            print("👋 Goodbye!\n", .{});
            break;
        } else if (std.mem.eql(u8, input, "check")) {
            print("🔍 Manually checking for messages...\n", .{});
            session.checkForMessages() catch |err| {
                print("❌ Error checking messages: {}\n", .{err});
            };
        } else if (std.mem.eql(u8, input, "status")) {
            print("📊 Status:\n", .{});
            print("   My ID: {s}\n", .{session.my_id});
            
            // Show signaling server connection status
            const signaling_status = if (session.peer_client.connected) "✅ Connected" else "❌ Disconnected";
            print("   Signaling server: {s}\n", .{signaling_status});
            
            if (session.target_id) |target| {
                print("   Target peer: {s}\n", .{target});
                if (session.connection) |conn| {
                    const status_str = switch (conn.status) {
                        .connecting => "🔄 Connecting",
                        .open => "✅ Open",
                        .closing => "🔄 Closing",
                        .closed => "❌ Closed",
                        .failed => "❌ Failed",
                    };
                    print("   Peer connection: {s}\n", .{status_str});
                    
                    // Show additional details for non-open connections
                    switch (conn.status) {
                        .open => print("   📶 Ready to send/receive messages\n", .{}),
                        .connecting => print("   ⏳ Still establishing connection...\n", .{}),
                        .closed => print("   💡 Use 'connect <peer-id>' to reconnect\n", .{}),
                        .failed => print("   💡 Connection failed, try reconnecting\n", .{}),
                        .closing => print("   ⚠️  Connection is shutting down\n", .{}),
                    }
                } else {
                    print("   Peer connection: ❌ No connection object\n", .{});
                }
            } else {
                print("   No target peer set\n", .{});
                print("   💡 Use 'connect <peer-id>' to connect to a peer\n", .{});
            }
        } else if (std.mem.startsWith(u8, input, "connect ")) {
            const target_peer_id = input[8..];
            if (target_peer_id.len == 0) {
                print("❌ Usage: connect <peer-id>\n", .{});
                continue;
            }

            session.connectToPeer(target_peer_id) catch |err| {
                print("❌ Failed to connect to {s}: {}\n", .{ target_peer_id, err });
            };
        } else {
            // Send as message
            if (session.connection == null) {
                print("❌ Not connected to any peer. Use 'connect <peer-id>' first.\n", .{});
                continue;
            }

            session.sendMessage(input) catch |err| {
                print("❌ Failed to send message: {}\n", .{err});
            };
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = parseArgs(allocator, args) catch |err| switch (err) {
        error.ShowHelp => {
            printUsage();
            return;
        },
        else => {
            printUsage();
            return;
        },
    };
    defer {
        if (config.my_peer_id) |id| allocator.free(id);
        if (config.target_peer_id) |id| allocator.free(id);
    }

    print("🚀 Zig PeerJS Chat Demo - Public Server\n", .{});
    print("========================================\n", .{});
    print("Server: https://0.peerjs.com:443\n", .{});
    print("\n", .{});

    // Create PeerJS client (always use public server)
    const peer_config = peerjs.PeerConfig{
        .host = "0.peerjs.com",
        .port = 443,
        .secure = true,
        .peer_id = config.my_peer_id,
        .debug = if (config.debug) 3 else 1,
    };

    var peer_client = peerjs.PeerClient.init(allocator, peer_config) catch |err| {
        print("❌ Failed to initialize PeerJS client: {}\n", .{err});
        return;
    };
    defer peer_client.deinit();

    // Connect to server and get peer ID
    print("🔗 Connecting to PeerJS server...\n", .{});
    if (config.my_peer_id == null) {
        print("📡 Requesting peer ID via HTTP from server...\n", .{});
    }
    
    const my_peer_id = peer_client.getId() catch |err| switch (err) {
        peerjs.PeerError.ConnectionFailed => {
            print("❌ Failed to connect to server. Possible causes:\n", .{});
            print("   • No internet connection\n", .{});
            print("   • Server is down\n", .{});
            print("   • Firewall blocking WebSocket connections\n", .{});
            return;
        },
        peerjs.PeerError.InvalidPeerId => {
            print("❌ The specified peer ID is invalid or already taken.\n", .{});
            print("💡 Try a different peer ID or let the server generate one.\n", .{});
            return;
        },
        peerjs.PeerError.HttpRequestFailed => {
            print("❌ HTTP ID request failed. Check your internet connection.\n", .{});
            print("💡 The server might be temporarily unavailable.\n", .{});
            return;
        },
        else => {
            print("❌ Unexpected error: {}\n", .{err});
            return;
        },
    };

    print("✅ Connected! Your peer ID: {s}\n", .{my_peer_id});
    
    if (config.my_peer_id == null) {
        print("🆔 This ID was generated via HTTP request to the server\n", .{});
    }

    // Initialize chat session
    var session = ChatSession.init(allocator, &peer_client, my_peer_id);
    defer session.deinit();

    // If target peer ID was provided, connect to it
    if (config.target_peer_id) |target_id| {
        print("🎯 Attempting to connect to target peer: {s}\n", .{target_id});
        session.connectToPeer(target_id) catch |err| {
            print("❌ Failed to connect to {s}: {}\n", .{ target_id, err });
            print("💡 Continuing in listen mode. You can connect later using 'connect <peer-id>'\n", .{});
        };
    } else {
        print("💡 No target peer specified. Use 'connect <peer-id>' to connect to another peer\n", .{});
        print("📋 Share your peer ID ({s}) with others to let them connect to you\n", .{my_peer_id});
    }

    // Run interactive chat
    runInteractiveChat(allocator, &session) catch |err| {
        print("❌ Chat error: {}\n", .{err});
    };

    print("✨ Chat demo completed!\n", .{});
}

// Tests
test "chat demo: argument parsing" {
    const allocator = std.testing.allocator;

    // Test default config
    {
        var args = [_][:0]u8{"program"};
        const config = try parseArgs(allocator, &args);
        defer {
            if (config.my_peer_id) |id| allocator.free(id);
            if (config.target_peer_id) |id| allocator.free(id);
        }

        try std.testing.expectEqual(@as(?[]const u8, null), config.my_peer_id);
        try std.testing.expectEqual(@as(?[]const u8, null), config.target_peer_id);
        try std.testing.expect(!config.debug);
    }

    // Test with peer IDs
    {
        var peer1 = "alice".*;
        var peer2 = "bob".*;
        var args = [_][:0]u8{ "program", &peer1, &peer2 };
        const config = try parseArgs(allocator, &args);
        defer {
            if (config.my_peer_id) |id| allocator.free(id);
            if (config.target_peer_id) |id| allocator.free(id);
        }

        try std.testing.expectEqualStrings("alice", config.my_peer_id.?);
        try std.testing.expectEqualStrings("bob", config.target_peer_id.?);
    }

    // Test with debug flag
    {
        var debug_flag = "--debug".*;
        var args = [_][:0]u8{ "program", &debug_flag };
        const config = try parseArgs(allocator, &args);
        defer {
            if (config.my_peer_id) |id| allocator.free(id);
            if (config.target_peer_id) |id| allocator.free(id);
        }

        try std.testing.expect(config.debug);
    }
}

test "chat demo: ChatSession lifecycle" {
    const allocator = std.testing.allocator;

    var peer_client = try peerjs.PeerClient.init(allocator, .{ .debug = 0 });
    defer peer_client.deinit();

    var session = ChatSession.init(allocator, &peer_client, "test-peer");
    defer session.deinit();

    try std.testing.expectEqualStrings("test-peer", session.my_id);
    try std.testing.expectEqual(@as(?*peerjs.DataConnection, null), session.connection);
    try std.testing.expect(!session.should_exit);
}

//! PeerJS client library for Zig
//!
//! This library provides a Zig interface to connect with PeerJS servers
//! and establish peer-to-peer connections for data transfer using WebRTC.
//!
//! Example usage:
//! ```zig
//! var peer = try PeerClient.init(allocator, .{});
//! defer peer.deinit();
//!
//! const peer_id = try peer.getId();
//! std.log.info("My peer ID: {s}", .{peer_id});
//!
//! var conn = try peer.connect("dest-peer-id");
//! defer conn.deinit();
//!
//! try conn.send("Hello!");
//! ```

const std = @import("std");
const testing = std.testing;
const json = std.json;
const http = std.http;
const net = std.net;
const websocket = @import("websocket");

// Import our signaling module
const signaling = @import("signaling.zig");

/// Re-export signaling types for convenience
pub const SignalingError = signaling.SignalingError;
pub const MessageType = signaling.MessageType;
pub const SessionDescription = signaling.SessionDescription;
pub const IceCandidate = signaling.IceCandidate;
pub const SignalingMessage = signaling.SignalingMessage;
pub const SignalingClient = signaling.SignalingClient;

/// Errors that can occur during PeerJS operations
pub const PeerError = error{
    /// Failed to connect to PeerJS server
    ConnectionFailed,
    /// Invalid peer ID format
    InvalidPeerId,
    /// Peer is not available or doesn't exist
    PeerUnavailable,
    /// Network error during communication
    NetworkError,
    /// Invalid server response
    InvalidResponse,
    /// Connection timeout
    Timeout,
    /// Peer is disconnected
    Disconnected,
    /// Invalid data format
    InvalidData,
    /// Buffer too small
    BufferTooSmall,
    /// No messages available
    NoMessages,
} || std.mem.Allocator.Error || SignalingError || std.fmt.BufPrintError;

/// Configuration options for PeerClient
pub const PeerConfig = struct {
    /// PeerJS server host (default: "0.peerjs.com")
    host: []const u8 = "0.peerjs.com",
    /// PeerJS server port (default: 443)
    port: u16 = 443,
    /// Whether to use secure connection (default: true)
    secure: bool = true,
    /// API key for cloud PeerServer (default: "peerjs")
    key: []const u8 = "peerjs",
    /// Server path (default: "/")
    path: []const u8 = "/",
    /// Custom peer ID (if null, server will generate one)
    peer_id: ?[]const u8 = null,
    /// Connection timeout in milliseconds (default: 30000)
    timeout_ms: u32 = 30000,
    /// Debug level (0=none, 1=errors, 2=warnings, 3=all)
    debug: u8 = 0,
    /// Heartbeat interval in milliseconds (default: 5000)
    heartbeat_interval: u32 = 5000,
};

/// Status of a peer connection
pub const ConnectionStatus = enum {
    /// Connection is being established
    connecting,
    /// Connection is open and ready
    open,
    /// Connection is closing
    closing,
    /// Connection is closed
    closed,
    /// Connection failed
    failed,
};

/// WebRTC data channel configuration
pub const DataChannelConfig = struct {
    /// Channel label
    label: []const u8 = "data",
    /// Ordered delivery
    ordered: bool = true,
    /// Maximum packet lifetime (ms)
    max_packet_life_time: ?u32 = null,
    /// Maximum retransmits
    max_retransmits: ?u32 = null,
};

/// Represents a data connection to another peer
pub const DataConnection = struct {
    allocator: std.mem.Allocator,
    peer_id: []const u8,
    connection_id: []const u8,
    status: ConnectionStatus,
    peer_client: *PeerClient,
    message_queue: std.ArrayList([]u8),
    config: DataChannelConfig,

    const Self = @This();

    /// Initialize a new data connection
    pub fn init(
        allocator: std.mem.Allocator,
        peer_id: []const u8,
        connection_id: []const u8,
        peer_client: *PeerClient,
        config: DataChannelConfig,
    ) PeerError!Self {
        return Self{
            .allocator = allocator,
            .peer_id = try allocator.dupe(u8, peer_id),
            .connection_id = try allocator.dupe(u8, connection_id),
            .status = .connecting,
            .peer_client = peer_client,
            .message_queue = std.ArrayList([]u8).init(allocator),
            .config = config,
        };
    }

    /// Send data to the connected peer
    pub fn send(self: *Self, data: []const u8) PeerError!void {
        if (self.status != .open) {
            return PeerError.Disconnected;
        }

        // Create signaling message for data transfer - use OFFER type for compatibility
        var message = SignalingMessage{
            .type = .offer, // Use OFFER type - PeerJS routes these properly  
            .src = if (self.peer_client.getPeerId()) |id| try self.allocator.dupe(u8, id) else null,
            .dst = try self.allocator.dupe(u8, self.peer_id),
            .payload = .{ .data = try self.allocator.dupe(u8, data) },
        };
        defer message.deinit(self.allocator);

        // Send via signaling channel
        self.peer_client.signaling_client.sendMessage(message) catch |err| {
            std.log.err("Failed to send data message: {}", .{err});
            return PeerError.ConnectionFailed;
        };

        if (self.peer_client.config.debug >= 2) {
            std.log.info("Sent data to peer {s}: {s}", .{ self.peer_id, data });
        }
    }

    /// Receive data from the connected peer (non-blocking)
    pub fn receive(self: *Self, buffer: []u8) PeerError![]const u8 {
        if (self.status != .open) {
            return PeerError.Disconnected;
        }

        // Check local message queue first
        if (self.message_queue.items.len > 0) {
            const message = self.message_queue.orderedRemove(0);
            defer self.allocator.free(message);

            if (message.len > buffer.len) {
                return PeerError.BufferTooSmall;
            }

            @memcpy(buffer[0..message.len], message);
            return buffer[0..message.len];
        }

        // Check for new messages from signaling
        if (self.peer_client.signaling_client.receiveMessage() catch null) |msg| {
            defer {
                var mutable_msg = msg;
                mutable_msg.deinit(self.allocator);
            }

            // Check if message is for this connection
            if (msg.src != null and std.mem.eql(u8, msg.src.?, self.peer_id)) {
                switch (msg.payload) {
                    .data => |data| {
                        if (data.len > buffer.len) {
                            return PeerError.BufferTooSmall;
                        }
                        @memcpy(buffer[0..data.len], data);
                        return buffer[0..data.len];
                    },
                    else => {},
                }
            }
        }

        return PeerError.NoMessages;
    }

    /// Close the connection
    pub fn close(self: *Self) void {
        if (self.status == .closed) return;

        self.status = .closing;

        // Send leave message
        var leave_msg = SignalingMessage{
            .type = .leave,
            .src = if (self.peer_client.getPeerId()) |id| self.allocator.dupe(u8, id) catch return else null,
            .dst = self.allocator.dupe(u8, self.peer_id) catch return,
        };
        defer leave_msg.deinit(self.allocator);

        self.peer_client.signaling_client.sendMessage(leave_msg) catch |err| {
            std.log.err("Failed to send leave message: {}", .{err});
        };

        self.status = .closed;

        if (self.peer_client.config.debug >= 1) {
            std.log.info("Closed connection to peer: {s}", .{self.peer_id});
        }
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        if (self.status == .open) {
            self.close();
        }

        // Clean up message queue
        for (self.message_queue.items) |message| {
            self.allocator.free(message);
        }
        self.message_queue.deinit();

        self.allocator.free(self.peer_id);
        self.allocator.free(self.connection_id);
    }
};

/// Main PeerJS client
pub const PeerClient = struct {
    allocator: std.mem.Allocator,
    config: PeerConfig,
    signaling_client: SignalingClient,
    connections: std.HashMap([]const u8, *DataConnection, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    connected: bool,

    const Self = @This();

    /// Initialize a new PeerClient
    pub fn init(allocator: std.mem.Allocator, config: PeerConfig) PeerError!Self {
        // Validate peer ID if provided
        if (config.peer_id) |id| {
            if (!isValidPeerId(id)) {
                return PeerError.InvalidPeerId;
            }
        }

        // Create signaling client
        const signaling_config = signaling.ServerConfig{
            .host = config.host,
            .port = config.port,
            .secure = config.secure,
            .key = config.key,
            .path = config.path,
            .timeout = config.timeout_ms,
            .ping_interval = config.heartbeat_interval,
        };

        const signaling_client = SignalingClient.init(allocator, signaling_config) catch |err| {
            std.log.err("Failed to create signaling client: {}", .{err});
            return PeerError.ConnectionFailed;
        };

        return Self{
            .allocator = allocator,
            .config = config,
            .signaling_client = signaling_client,
            .connections = std.HashMap([]const u8, *DataConnection, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .connected = false,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.disconnect();

        // Clean up connections
        var iterator = self.connections.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.connections.deinit();

        self.signaling_client.deinit();
    }

    /// Connect to the PeerJS server
    pub fn connect(self: *Self) PeerError!void {
        if (self.connected) return;

        self.signaling_client.connect(self.config.peer_id) catch |err| {
            std.log.err("Failed to connect to signaling server: {}", .{err});
            return PeerError.ConnectionFailed;
        };

        self.connected = true;

        if (self.config.debug >= 1) {
            const peer_id = self.getPeerId() orelse "unknown";
            std.log.info("Connected to PeerJS server with ID: {s}", .{peer_id});
        }
    }

    /// Disconnect from the PeerJS server
    pub fn disconnect(self: *Self) void {
        if (!self.connected) return;

        // Close all connections
        var iterator = self.connections.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.close();
        }

        self.signaling_client.disconnect();
        self.connected = false;
    }

    /// Get the peer ID assigned by the server
    pub fn getId(self: *Self) PeerError![]const u8 {
        if (!self.connected) {
            try self.connect();
        }

        return self.getPeerId() orelse PeerError.ConnectionFailed;
    }

    /// Get the current peer ID (returns null if not connected)
    pub fn getPeerId(self: *Self) ?[]const u8 {
        return self.signaling_client.getPeerId();
    }

    /// Establish a data connection to another peer
    pub fn connectToPeer(self: *Self, peer_id: []const u8) PeerError!*DataConnection {
        if (!isValidPeerId(peer_id)) {
            return PeerError.InvalidPeerId;
        }

        if (!self.connected) {
            try self.connect();
        }

        // Check if we already have a connection to this peer
        if (self.connections.get(peer_id)) |existing| {
            return existing;
        }

        // Generate connection ID
        var connection_id_buffer: [64]u8 = undefined;
        const connection_id = try std.fmt.bufPrint(connection_id_buffer[0..], "dc_{s}_{d}", .{ peer_id, std.time.timestamp() });

        // Create new connection
        var connection = try self.allocator.create(DataConnection);
        connection.* = try DataConnection.init(
            self.allocator,
            peer_id,
            connection_id,
            self,
            .{}, // Default config
        );

        // Store connection
        const peer_id_copy = try self.allocator.dupe(u8, peer_id);
        try self.connections.put(peer_id_copy, connection);

        // Send connection offer
        var offer_msg = SignalingMessage{
            .type = .offer,
            .src = if (self.getPeerId()) |id| try self.allocator.dupe(u8, id) else null,
            .dst = try self.allocator.dupe(u8, peer_id),
            .payload = .{ .connection_id = try self.allocator.dupe(u8, connection_id) },
        };
        defer offer_msg.deinit(self.allocator);

        self.signaling_client.sendMessage(offer_msg) catch |err| {
            std.log.err("Failed to send connection offer: {}", .{err});
            connection.deinit();
            self.allocator.destroy(connection);
            _ = self.connections.remove(peer_id);
            self.allocator.free(peer_id_copy);
            return PeerError.ConnectionFailed;
        };

        // Mark as open (simplified - in real WebRTC this would wait for answer)
        connection.status = .open;

        if (self.config.debug >= 1) {
            std.log.info("Connected to peer: {s}", .{peer_id});
        }

        return connection;
    }

    /// Process incoming signaling messages
    pub fn handleIncomingMessages(self: *Self) PeerError!void {
        if (!self.connected) return;

        // Send heartbeat if needed
        if (self.signaling_client.shouldSendHeartbeat()) {
            self.signaling_client.sendHeartbeat() catch |err| {
                std.log.err("Failed to send heartbeat: {}", .{err});
            };
        }

        // Process incoming messages
        while (self.signaling_client.receiveMessage() catch null) |msg| {
            defer {
                var mutable_msg = msg;
                mutable_msg.deinit(self.allocator);
            }

            if (self.config.debug >= 2) {
                std.log.info("Processing signaling message type: {s}", .{msg.type.toString()});
            }

            try self.processSignalingMessage(msg);
        }
    }

    // Private helper methods

    fn processSignalingMessage(self: *Self, message: SignalingMessage) PeerError!void {
        switch (message.type) {
            .offer => {
                // Handle both connection offers and data messages sent as offers
                if (message.src) |src_peer| {
                    // Check if this is a data message or connection establishment
                    if (message.payload == .data) {
                        // This is a data message
                        if (self.config.debug >= 2) {
                            std.log.info("Received data message from: {s}", .{src_peer});
                        }
                        
                        if (self.connections.get(src_peer)) |connection| {
                            // Store data in connection's message queue
                            const data_copy = try self.allocator.dupe(u8, message.payload.data);
                            try connection.message_queue.append(data_copy);
                            
                            if (self.config.debug >= 2) {
                                std.log.info("Stored data from {s}: {s}", .{ src_peer, message.payload.data });
                            }
                        } else {
                            if (self.config.debug >= 1) {
                                std.log.err("No connection found for data from peer: {s}", .{src_peer});
                            }
                        }
                    } else {
                        // This is a connection establishment offer
                        if (self.config.debug >= 2) {
                            std.log.info("Received connection offer from: {s}", .{src_peer});
                        }

                        // Auto-accept for now (in real implementation, this would be user-controlled)
                        try self.acceptConnection(src_peer, message);
                    }
                }
            },
            .data => {
                // Handle incoming data message
                if (message.src) |src_peer| {
                    if (self.config.debug >= 2) {
                        std.log.info("Processing DATA message from: {s}", .{src_peer});
                    }
                    if (self.connections.get(src_peer)) |connection| {
                        if (message.payload == .data) {
                            // Store data in connection's message queue
                            const data_copy = try self.allocator.dupe(u8, message.payload.data);
                            try connection.message_queue.append(data_copy);
                            
                            if (self.config.debug >= 2) {
                                std.log.info("Stored data from {s}: {s}", .{ src_peer, message.payload.data });
                            }
                        }
                    } else {
                        if (self.config.debug >= 1) {
                            std.log.err("No connection found for peer: {s}", .{src_peer});
                        }
                    }
                } else {
                    if (self.config.debug >= 1) {
                        std.log.err("DATA message missing source peer", .{});
                    }
                }
            },
            .answer => {
                // Handle connection answer
                if (message.src) |src_peer| {
                    if (self.connections.get(src_peer)) |connection| {
                        connection.status = .open;
                        if (self.config.debug >= 2) {
                            std.log.info("Connection established with: {s}", .{src_peer});
                        }
                    }
                }
            },
            .leave => {
                // Handle peer disconnect
                if (message.src) |src_peer| {
                    if (self.connections.get(src_peer)) |connection| {
                        connection.status = .closed;
                        if (self.config.debug >= 1) {
                            std.log.info("Peer disconnected: {s}", .{src_peer});
                        }
                    }
                }
            },
            else => {
                // Handle other message types
                if (self.config.debug >= 3) {
                    std.log.info("Received signaling message: {s}", .{message.type.toString()});
                }
            },
        }
    }

    fn acceptConnection(self: *Self, peer_id: []const u8, offer_message: SignalingMessage) PeerError!void {
        _ = offer_message; // TODO: Use offer_message for WebRTC negotiation

        // Generate connection ID
        var connection_id_buffer: [64]u8 = undefined;
        const connection_id = try std.fmt.bufPrint(connection_id_buffer[0..], "dc_{s}_{d}", .{ peer_id, std.time.timestamp() });

        // Create new connection
        var connection = try self.allocator.create(DataConnection);
        connection.* = try DataConnection.init(
            self.allocator,
            peer_id,
            connection_id,
            self,
            .{}, // Default config
        );

        // Store connection
        const peer_id_copy = try self.allocator.dupe(u8, peer_id);
        try self.connections.put(peer_id_copy, connection);

        // Send answer
        var answer_msg = SignalingMessage{
            .type = .answer,
            .src = if (self.getPeerId()) |id| try self.allocator.dupe(u8, id) else null,
            .dst = try self.allocator.dupe(u8, peer_id),
            .payload = .{ .connection_id = try self.allocator.dupe(u8, connection_id) },
        };
        defer answer_msg.deinit(self.allocator);

        self.signaling_client.sendMessage(answer_msg) catch |err| {
            std.log.err("Failed to send connection answer: {}", .{err});
            connection.deinit();
            self.allocator.destroy(connection);
            _ = self.connections.remove(peer_id);
            self.allocator.free(peer_id_copy);
            return PeerError.ConnectionFailed;
        };

        connection.status = .open;

        if (self.config.debug >= 1) {
            std.log.info("Accepted connection from peer: {s}", .{peer_id});
        }
    }
};

/// Validate a peer ID according to PeerJS rules
pub fn isValidPeerId(peer_id: []const u8) bool {
    if (peer_id.len == 0 or peer_id.len > 50) return false;
    if (peer_id[0] == '-' or peer_id[peer_id.len - 1] == '-') return false;

    for (peer_id) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') {
            return false;
        }
    }

    return true;
}

/// Legacy compatibility: Fetch a peer token (placeholder implementation)
pub fn fetchPeerToken(allocator: std.mem.Allocator) PeerError!std.ArrayList(u8) {
    var token = std.ArrayList(u8).init(allocator);
    try token.appendSlice("legacy-token-placeholder");
    return token;
}

// Tests
test "peer ID validation" {
    try testing.expect(isValidPeerId("test123"));
    try testing.expect(isValidPeerId("peer_with_underscore"));
    try testing.expect(isValidPeerId("peer-with-dash"));

    try testing.expect(!isValidPeerId(""));
    try testing.expect(!isValidPeerId("-starts-with-dash"));
    try testing.expect(!isValidPeerId("ends-with-dash-"));
    try testing.expect(!isValidPeerId("has@special!chars"));
}

test "PeerClient initialization" {
    const allocator = testing.allocator;

    var client = try PeerClient.init(allocator, .{});
    defer client.deinit();

    try testing.expect(!client.connected);
}

test "DataConnection creation" {
    const allocator = testing.allocator;

    var peer_client = try PeerClient.init(allocator, .{});
    defer peer_client.deinit();

    var connection = try DataConnection.init(
        allocator,
        "test-peer",
        "test-connection",
        &peer_client,
        .{},
    );
    defer connection.deinit();

    try testing.expectEqualStrings("test-peer", connection.peer_id);
    try testing.expectEqual(ConnectionStatus.connecting, connection.status);
}

test "legacy token fetch" {
    const allocator = testing.allocator;

    const token = try fetchPeerToken(allocator);
    defer token.deinit();

    try testing.expect(token.items.len > 0);
    try testing.expectEqualStrings("legacy-token-placeholder", token.items);
}

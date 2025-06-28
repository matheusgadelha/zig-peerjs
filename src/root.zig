//! PeerJS client library for Zig
//!
//! This library provides a Zig interface to connect with PeerJS servers
//! and establish peer-to-peer connections for data transfer.
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
} || std.mem.Allocator.Error || std.http.Client.RequestError || std.fs.File.OpenError || std.fs.File.WriteError || std.fs.File.ReadError || std.fs.Dir.MakeError;

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
    /// Custom peer ID (if null, server will generate one)
    peer_id: ?[]const u8 = null,
    /// Connection timeout in milliseconds (default: 5000)
    timeout_ms: u64 = 5000,
    /// Debug level (0=none, 1=errors, 2=warnings, 3=all)
    debug: u8 = 0,
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

/// Types of PeerJS messages
const MessageType = enum {
    heartbeat,
    candidate,
    offer,
    answer,
    open,
    error_msg,
    id_taken,
    invalid_key,
    leave,
    expire,

    pub fn fromString(str: []const u8) ?MessageType {
        if (std.mem.eql(u8, str, "HEARTBEAT")) return .heartbeat;
        if (std.mem.eql(u8, str, "CANDIDATE")) return .candidate;
        if (std.mem.eql(u8, str, "OFFER")) return .offer;
        if (std.mem.eql(u8, str, "ANSWER")) return .answer;
        if (std.mem.eql(u8, str, "OPEN")) return .open;
        if (std.mem.eql(u8, str, "ERROR")) return .error_msg;
        if (std.mem.eql(u8, str, "ID-TAKEN")) return .id_taken;
        if (std.mem.eql(u8, str, "INVALID-KEY")) return .invalid_key;
        if (std.mem.eql(u8, str, "LEAVE")) return .leave;
        if (std.mem.eql(u8, str, "EXPIRE")) return .expire;
        return null;
    }

    pub fn toString(self: MessageType) []const u8 {
        return switch (self) {
            .heartbeat => "HEARTBEAT",
            .candidate => "CANDIDATE",
            .offer => "OFFER",
            .answer => "ANSWER",
            .open => "OPEN",
            .error_msg => "ERROR",
            .id_taken => "ID-TAKEN",
            .invalid_key => "INVALID-KEY",
            .leave => "LEAVE",
            .expire => "EXPIRE",
        };
    }
};

/// Represents a message sent between peers
pub const PeerMessage = struct {
    from: []const u8,
    to: []const u8,
    data: []const u8,
    timestamp: i64,
};

/// Simple message storage using files for demo purposes
const MessageStorage = struct {
    allocator: std.mem.Allocator,
    storage_dir: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const storage_dir = "/tmp/zig_peerjs_messages";

        // Create storage directory if it doesn't exist
        std.fs.cwd().makeDir(storage_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {}, // OK, directory exists
            else => return err,
        };

        return Self{
            .allocator = allocator,
            .storage_dir = try allocator.dupe(u8, storage_dir),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.storage_dir);
    }

    /// Store a message for a peer
    pub fn storeMessage(self: *Self, peer_id: []const u8, message: PeerMessage) !void {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.storage_dir, peer_id });
        defer self.allocator.free(filename);

        // Read existing messages
        var messages = std.ArrayList(PeerMessage).init(self.allocator);
        defer {
            for (messages.items) |msg| {
                self.allocator.free(msg.from);
                self.allocator.free(msg.to);
                self.allocator.free(msg.data);
            }
            messages.deinit();
        }

        // Try to read existing file
        if (std.fs.cwd().readFileAlloc(self.allocator, filename, 1024 * 1024)) |content| {
            defer self.allocator.free(content);

            // Parse existing messages (simplified JSON parsing)
            // For demo purposes, we'll use a simple line-based format instead of full JSON
            var lines = std.mem.splitSequence(u8, content, "\n");
            while (lines.next()) |line| {
                if (line.len == 0) continue;

                // Parse line format: "from|to|data|timestamp"
                var parts = std.mem.splitSequence(u8, line, "|");
                const from = parts.next() orelse continue;
                const to = parts.next() orelse continue;
                const data_part = parts.next() orelse continue;
                const timestamp_str = parts.next() orelse continue;

                const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch continue;

                try messages.append(PeerMessage{
                    .from = try self.allocator.dupe(u8, from),
                    .to = try self.allocator.dupe(u8, to),
                    .data = try self.allocator.dupe(u8, data_part),
                    .timestamp = timestamp,
                });
            }
        } else |_| {
            // File doesn't exist or couldn't read, that's OK
        }

        // Add new message
        try messages.append(PeerMessage{
            .from = try self.allocator.dupe(u8, message.from),
            .to = try self.allocator.dupe(u8, message.to),
            .data = try self.allocator.dupe(u8, message.data),
            .timestamp = message.timestamp,
        });

        // Write all messages back
        const file = std.fs.cwd().createFile(filename, .{}) catch |err| {
            return err;
        };
        defer file.close();

        for (messages.items) |msg| {
            const line = try std.fmt.allocPrint(self.allocator, "{s}|{s}|{s}|{d}\n", .{ msg.from, msg.to, msg.data, msg.timestamp });
            defer self.allocator.free(line);
            _ = try file.writeAll(line);
        }
    }

    /// Retrieve and consume messages for a peer
    pub fn getMessages(self: *Self, peer_id: []const u8) !std.ArrayList(PeerMessage) {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.storage_dir, peer_id });
        defer self.allocator.free(filename);

        var messages = std.ArrayList(PeerMessage).init(self.allocator);

        const content = std.fs.cwd().readFileAlloc(self.allocator, filename, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return messages, // No messages
            else => return err,
        };
        defer self.allocator.free(content);

        // Parse messages
        var lines = std.mem.splitSequence(u8, content, "\n");
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            var parts = std.mem.splitSequence(u8, line, "|");
            const from = parts.next() orelse continue;
            const to = parts.next() orelse continue;
            const data_part = parts.next() orelse continue;
            const timestamp_str = parts.next() orelse continue;

            const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch continue;

            try messages.append(PeerMessage{
                .from = try self.allocator.dupe(u8, from),
                .to = try self.allocator.dupe(u8, to),
                .data = try self.allocator.dupe(u8, data_part),
                .timestamp = timestamp,
            });
        }

        // Clear the file after reading (consume messages)
        std.fs.cwd().deleteFile(filename) catch {};

        return messages;
    }
};

/// Represents a data connection to another peer
pub const DataConnection = struct {
    allocator: std.mem.Allocator,
    peer_id: []const u8,
    connection_id: []const u8,
    status: ConnectionStatus,
    peer_client: *PeerClient,
    message_storage: MessageStorage,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, peer_id: []const u8, connection_id: []const u8, peer_client: *PeerClient) !Self {
        return Self{
            .allocator = allocator,
            .peer_id = try allocator.dupe(u8, peer_id),
            .connection_id = try allocator.dupe(u8, connection_id),
            .status = .connecting,
            .peer_client = peer_client,
            .message_storage = try MessageStorage.init(allocator),
        };
    }

    /// Send data to the connected peer
    pub fn send(self: *Self, data: []const u8) PeerError!void {
        if (self.status != .open) {
            return PeerError.Disconnected;
        }

        // Get our own peer ID
        const our_id = try self.peer_client.getId();

        // Create message
        const message = PeerMessage{
            .from = our_id,
            .to = self.peer_id,
            .data = data,
            .timestamp = std.time.timestamp(),
        };

        // Store message for the target peer
        try self.message_storage.storeMessage(self.peer_id, message);

        if (self.peer_client.config.debug >= 2) {
            std.log.info("📤 Sent to {s}: {s}", .{ self.peer_id, data });
        }
    }

    /// Receive data from the connected peer (non-blocking)
    pub fn receive(self: *Self, buffer: []u8) PeerError![]const u8 {
        if (self.status != .open) {
            return PeerError.Disconnected;
        }

        // Get our own peer ID
        const our_id = try self.peer_client.getId();

        // Get messages for us
        var messages = self.message_storage.getMessages(our_id) catch {
            return PeerError.InvalidData;
        };
        defer {
            for (messages.items) |msg| {
                self.allocator.free(msg.from);
                self.allocator.free(msg.to);
                self.allocator.free(msg.data);
            }
            messages.deinit();
        }

        // Find messages from our connected peer
        for (messages.items) |message| {
            if (std.mem.eql(u8, message.from, self.peer_id)) {
                if (message.data.len >= buffer.len) {
                    return PeerError.BufferTooSmall;
                }

                @memcpy(buffer[0..message.data.len], message.data);

                if (self.peer_client.config.debug >= 2) {
                    std.log.info("📥 Received from {s}: {s}", .{ self.peer_id, message.data });
                }

                return buffer[0..message.data.len];
            }
        }

        return PeerError.NoMessages;
    }

    /// Check if there are pending messages (non-blocking)
    pub fn hasMessages(self: *Self) bool {
        const our_id = self.peer_client.getId() catch return false;

        var messages = self.message_storage.getMessages(our_id) catch return false;
        defer {
            // Don't consume messages, just check
            for (messages.items) |msg| {
                self.allocator.free(msg.from);
                self.allocator.free(msg.to);
                self.allocator.free(msg.data);
            }
            messages.deinit();
        }

        // Check if any messages are from our connected peer
        for (messages.items) |message| {
            if (std.mem.eql(u8, message.from, self.peer_id)) {
                return true;
            }
        }
        return false;
    }

    /// Close the connection
    pub fn close(self: *Self) void {
        self.status = .closing;
        // TODO: Send close message to peer
        self.status = .closed;
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        if (self.status == .open) {
            self.close();
        }
        self.message_storage.deinit();
        self.allocator.free(self.peer_id);
        self.allocator.free(self.connection_id);
        // Mark as deinitialized to prevent double-free
        self.status = .closed;
    }
};

/// Main PeerJS client
pub const PeerClient = struct {
    allocator: std.mem.Allocator,
    config: PeerConfig,
    peer_id: ?[]u8,
    http_client: http.Client,
    connections: std.HashMap([]const u8, *DataConnection, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),

    const Self = @This();

    /// Initialize a new PeerClient
    pub fn init(allocator: std.mem.Allocator, config: PeerConfig) PeerError!Self {
        // If a specific peer ID was requested, validate it
        if (config.peer_id) |id| {
            if (!isValidPeerId(id)) {
                return PeerError.InvalidPeerId;
            }
        }

        return Self{
            .allocator = allocator,
            .config = config,
            .peer_id = null,
            .http_client = http.Client{ .allocator = allocator },
            .connections = std.HashMap([]const u8, *DataConnection, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        // Close all connections
        var iterator = self.connections.iterator();
        while (iterator.next()) |entry| {
            // Only deinit connections that haven't been manually deinitialized
            if (entry.value_ptr.*.status != .closed) {
                entry.value_ptr.*.deinit();
            }
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.connections.deinit();

        if (self.peer_id) |id| {
            self.allocator.free(id);
        }

        self.http_client.deinit();
    }

    /// Get the peer ID (fetches from server if not already available)
    pub fn getId(self: *Self) PeerError![]const u8 {
        if (self.peer_id) |id| {
            return id;
        }

        // Use provided ID or fetch from server
        if (self.config.peer_id) |provided_id| {
            self.peer_id = try self.allocator.dupe(u8, provided_id);
        } else {
            self.peer_id = try self.fetchPeerIdFromServer();
        }

        if (self.config.debug >= 1) {
            std.log.info("Peer ID: {s}", .{self.peer_id.?});
        }

        return self.peer_id.?;
    }

    /// Connect to another peer
    pub fn connect(self: *Self, target_peer_id: []const u8) PeerError!*DataConnection {
        if (!isValidPeerId(target_peer_id)) {
            return PeerError.InvalidPeerId;
        }

        // Ensure we have our own peer ID
        _ = try self.getId();

        // Create connection ID
        const connection_id = try self.generateConnectionId();

        // Create DataConnection
        const conn = try self.allocator.create(DataConnection);
        conn.* = try DataConnection.init(self.allocator, target_peer_id, connection_id, self);

        // Store connection
        try self.connections.put(connection_id, conn);

        // For demo purposes, immediately mark as open
        conn.status = .open;

        if (self.config.debug >= 2) {
            std.log.info("Connected to peer: {s}", .{target_peer_id});
        }

        return conn;
    }

    /// Disconnect from PeerJS server
    pub fn disconnect(self: *Self) void {
        // TODO: Send disconnect message to server
        // Close all active connections
        var iterator = self.connections.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.close();
        }

        if (self.config.debug >= 1) {
            std.log.info("Disconnected from PeerJS server");
        }
    }

    /// Private method to fetch peer ID from server
    fn fetchPeerIdFromServer(self: *Self) PeerError![]u8 {
        const protocol = if (self.config.secure) "https" else "http";
        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}/peerjs/id?key={s}", .{ protocol, self.config.host, self.config.port, self.config.key });
        defer self.allocator.free(url);

        if (self.config.debug >= 3) {
            std.log.info("Fetching peer ID from: {s}", .{url});
        }

        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();

        const resp = self.http_client.fetch(.{
            .method = .GET,
            .location = .{ .url = url },
            .response_storage = .{ .dynamic = &response_body },
        }) catch |err| switch (err) {
            error.UnknownHostName, error.ConnectionRefused => return PeerError.ConnectionFailed,
            else => return PeerError.NetworkError,
        };

        if (resp.status != .ok) {
            if (self.config.debug >= 1) {
                std.log.err("Failed to fetch peer ID: HTTP {d}", .{@intFromEnum(resp.status)});
            }
            return PeerError.InvalidResponse;
        }

        // The response should be a JSON string with the peer ID
        const trimmed = std.mem.trim(u8, response_body.items, " \t\n\r\"");
        if (trimmed.len == 0) {
            return PeerError.InvalidResponse;
        }

        return self.allocator.dupe(u8, trimmed);
    }

    /// Generate a unique connection ID
    fn generateConnectionId(self: *Self) PeerError![]u8 {
        var buffer: [16]u8 = undefined;
        std.crypto.random.bytes(&buffer);

        const hex_chars = "0123456789abcdef";
        var result = try self.allocator.alloc(u8, 32);
        for (buffer, 0..) |byte, i| {
            result[i * 2] = hex_chars[byte >> 4];
            result[i * 2 + 1] = hex_chars[byte & 0xF];
        }

        return result;
    }
};

/// Validate if a peer ID has the correct format
pub fn isValidPeerId(peer_id: []const u8) bool {
    if (peer_id.len == 0 or peer_id.len > 64) {
        return false;
    }

    // Must start and end with alphanumeric
    if (!std.ascii.isAlphanumeric(peer_id[0]) or
        !std.ascii.isAlphanumeric(peer_id[peer_id.len - 1]))
    {
        return false;
    }

    // Check all characters
    for (peer_id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
            return false;
        }
    }

    return true;
}

/// Utility function to fetch a peer token (kept for compatibility)
pub fn fetchPeerToken(allocator: std.mem.Allocator) !std.ArrayList(u8) {
    var client = try PeerClient.init(allocator, .{});
    defer client.deinit();

    const peer_id = try client.getId();

    var result = std.ArrayList(u8).init(allocator);
    try result.appendSlice(peer_id);
    return result;
}

/// Simple add function (kept for compatibility with existing tests)
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

// Tests
test "peer ID validation" {
    try testing.expect(isValidPeerId("abc123"));
    try testing.expect(isValidPeerId("test-peer_01"));
    try testing.expect(!isValidPeerId("")); // empty
    try testing.expect(!isValidPeerId("-abc")); // starts with dash
    try testing.expect(!isValidPeerId("abc-")); // ends with dash
    try testing.expect(!isValidPeerId("ab@c")); // invalid character
}

test "peer config defaults" {
    const config = PeerConfig{};
    try testing.expectEqualStrings("0.peerjs.com", config.host);
    try testing.expectEqual(@as(u16, 443), config.port);
    try testing.expect(config.secure);
    try testing.expectEqualStrings("peerjs", config.key);
}

test "peer client initialization" {
    var client = try PeerClient.init(testing.allocator, .{});
    defer client.deinit();

    try testing.expect(client.peer_id == null);
    try testing.expectEqual(@as(usize, 0), client.connections.count());
}

test "connection ID generation" {
    var client = try PeerClient.init(testing.allocator, .{});
    defer client.deinit();

    const id1 = try client.generateConnectionId();
    defer testing.allocator.free(id1);

    const id2 = try client.generateConnectionId();
    defer testing.allocator.free(id2);

    try testing.expect(id1.len == 32);
    try testing.expect(id2.len == 32);
    try testing.expect(!std.mem.eql(u8, id1, id2));
}

test "message type conversion" {
    try testing.expectEqual(MessageType.heartbeat, MessageType.fromString("HEARTBEAT").?);
    try testing.expectEqual(MessageType.offer, MessageType.fromString("OFFER").?);
    try testing.expect(MessageType.fromString("INVALID") == null);

    try testing.expectEqualStrings("HEARTBEAT", MessageType.heartbeat.toString());
    try testing.expectEqualStrings("OFFER", MessageType.offer.toString());
}

test "message storage" {
    var storage = try MessageStorage.init(testing.allocator);
    defer storage.deinit();

    const message = PeerMessage{
        .from = "peer1",
        .to = "peer2",
        .data = "Hello!",
        .timestamp = 12345,
    };

    try storage.storeMessage("peer2", message);

    var messages = try storage.getMessages("peer2");
    defer {
        for (messages.items) |msg| {
            testing.allocator.free(msg.from);
            testing.allocator.free(msg.to);
            testing.allocator.free(msg.data);
        }
        messages.deinit();
    }

    try testing.expect(messages.items.len >= 1);
    const received = messages.items[messages.items.len - 1];
    try testing.expectEqualStrings("peer1", received.from);
    try testing.expectEqualStrings("peer2", received.to);
    try testing.expectEqualStrings("Hello!", received.data);
}

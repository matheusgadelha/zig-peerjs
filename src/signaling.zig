//! PeerJS WebSocket Signaling Layer
//!
//! This module handles WebSocket communication with PeerJS servers for WebRTC signaling.
//! It implements the PeerJS protocol for peer discovery, connection establishment,
//! and signaling message exchange.

const std = @import("std");
const websocket = @import("websocket");
const json = std.json;
const http = std.http;

/// Errors that can occur during signaling operations
pub const SignalingError = error{
    /// Connection to signaling server failed
    ConnectionFailed,
    /// Invalid message format
    InvalidMessage,
    /// Server rejected the connection
    ServerRejected,
    /// Network timeout
    Timeout,
    /// Peer is not available
    PeerUnavailable,
    /// Invalid peer ID
    InvalidPeerId,
    /// Server error
    ServerError,
    /// HTTP request failed
    HttpRequestFailed,
    /// URI parsing failed
    InvalidUri,
    /// URI format error
    UriFormatError,
    /// Invalid port
    InvalidPort,
    /// HTTP connection errors
    HttpConnectionFailed,
    /// DNS resolution failed
    DnsResolutionFailed,
    /// TLS errors
    TlsError,
    /// Invalid server response
    InvalidResponse,
} || std.mem.Allocator.Error || std.fmt.BufPrintError;

/// PeerJS message types used in signaling
pub const MessageType = enum {
    // Client -> Server messages
    heartbeat,
    offer,
    answer,
    candidate,
    leave,
    data, // Custom type for data messages

    // Server -> Client messages
    open,
    error_msg,
    id_taken,
    invalid_key,
    expire,

    pub fn fromString(str: []const u8) ?MessageType {
        if (std.mem.eql(u8, str, "HEARTBEAT")) return .heartbeat;
        if (std.mem.eql(u8, str, "OFFER")) return .offer;
        if (std.mem.eql(u8, str, "ANSWER")) return .answer;
        if (std.mem.eql(u8, str, "CANDIDATE")) return .candidate;
        if (std.mem.eql(u8, str, "LEAVE")) return .leave;
        if (std.mem.eql(u8, str, "DATA")) return .data;
        if (std.mem.eql(u8, str, "OPEN")) return .open;
        if (std.mem.eql(u8, str, "ERROR")) return .error_msg;
        if (std.mem.eql(u8, str, "ID-TAKEN")) return .id_taken;
        if (std.mem.eql(u8, str, "INVALID-KEY")) return .invalid_key;
        if (std.mem.eql(u8, str, "EXPIRE")) return .expire;
        return null;
    }

    pub fn toString(self: MessageType) []const u8 {
        return switch (self) {
            .heartbeat => "HEARTBEAT",
            .offer => "OFFER",
            .answer => "ANSWER",
            .candidate => "CANDIDATE",
            .leave => "LEAVE",
            .data => "DATA",
            .open => "OPEN",
            .error_msg => "ERROR",
            .id_taken => "ID-TAKEN",
            .invalid_key => "INVALID-KEY",
            .expire => "EXPIRE",
        };
    }
};

/// PeerJS server configuration
pub const ServerConfig = struct {
    host: []const u8 = "0.peerjs.com",
    port: u16 = 443,
    secure: bool = true,
    path: []const u8 = "/",
    key: []const u8 = "peerjs",
    ping_interval: u32 = 5000, // milliseconds
    timeout: u32 = 30000, // milliseconds
};

/// Peer ID and token pair from HTTP request
pub const PeerIdTokenPair = struct {
    peer_id: []const u8,
    token: []const u8,
    
    pub fn deinit(self: *PeerIdTokenPair, allocator: std.mem.Allocator) void {
        allocator.free(self.peer_id);
        allocator.free(self.token);
    }
};

/// WebRTC session description
pub const SessionDescription = struct {
    type: enum { offer, answer },
    sdp: []const u8,
};

/// ICE candidate information
pub const IceCandidate = struct {
    candidate: []const u8,
    sdp_mid: ?[]const u8 = null,
    sdp_mline_index: ?u32 = null,
};

/// PeerJS signaling message
pub const SignalingMessage = struct {
    type: MessageType,
    src: ?[]const u8 = null,
    dst: ?[]const u8 = null,
    payload: union(enum) {
        none: void,
        peer_id: []const u8,
        error_msg: []const u8,
        sdp: SessionDescription,
        candidate: IceCandidate,
        connection_id: []const u8,
        data: []const u8,
    } = .none,

    pub fn deinit(self: *SignalingMessage, allocator: std.mem.Allocator) void {
        if (self.src) |src| allocator.free(src);
        if (self.dst) |dst| allocator.free(dst);

        switch (self.payload) {
            .peer_id => |id| allocator.free(id),
            .error_msg => |msg| allocator.free(msg),
            .sdp => |sdp| allocator.free(sdp.sdp),
            .candidate => |candidate| {
                allocator.free(candidate.candidate);
                if (candidate.sdp_mid) |mid| allocator.free(mid);
            },
            .connection_id => |id| allocator.free(id),
            .data => |data| allocator.free(data),
            .none => {},
        }
    }
};

/// WebSocket client wrapper for PeerJS signaling
pub const SignalingClient = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,
    client: ?websocket.Client,
    peer_id: ?[]u8,
    connected: bool,
    message_queue: std.ArrayList(SignalingMessage),
    heartbeat_timer: ?std.time.Timer,

    const Self = @This();

    /// Initialize a new signaling client
    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) SignalingError!Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .client = null,
            .peer_id = null,
            .connected = false,
            .message_queue = std.ArrayList(SignalingMessage).init(allocator),
            .heartbeat_timer = null,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.disconnect();

        // Clean up message queue
        for (self.message_queue.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.message_queue.deinit();

        if (self.peer_id) |id| {
            self.allocator.free(id);
        }
    }

    /// Connect to the PeerJS signaling server
    pub fn connect(self: *Self, peer_id: ?[]const u8) SignalingError!void {
        if (self.connected) return;

        var actual_peer_id: []const u8 = undefined;
        var actual_token: []const u8 = undefined;
        var peer_id_owned: bool = false;
        var token_owned: bool = false;

        // If no peer ID provided, request one from the server via HTTP (with token)
        if (peer_id == null) {
            const pair = try self.requestPeerIdAndToken();
            actual_peer_id = pair.peer_id;
            actual_token = pair.token;
            peer_id_owned = true;
            token_owned = true;
        } else {
            actual_peer_id = peer_id.?;
            // Still need to get a token from server for existing peer ID
            // For now, generate locally - TODO: implement token request for existing peer ID
            actual_token = try self.generateRandomToken();
            token_owned = true;
        }

        defer {
            if (peer_id_owned) self.allocator.free(actual_peer_id);
            if (token_owned) self.allocator.free(actual_token);
        }

        // Initialize WebSocket client
        std.log.info("Connecting to PeerJS server at {s}:{d}", .{ self.config.host, self.config.port });
        var client = websocket.Client.init(self.allocator, .{
            .host = self.config.host,
            .port = self.config.port,
            .tls = self.config.secure,
        }) catch |err| {
            std.log.err("Failed to initialize WebSocket client: {}", .{err});
            return SignalingError.ConnectionFailed;
        };

        // Build WebSocket URL path - format: {path}peerjs?key={key}&id={id}&token={token}
        var path_buffer: [512]u8 = undefined;
        const ws_path = blk: {
            if (std.mem.eql(u8, self.config.path, "/")) {
                break :blk try std.fmt.bufPrint(path_buffer[0..], "/peerjs?key={s}&id={s}&token={s}", .{ self.config.key, actual_peer_id, actual_token });
            } else {
                // Remove trailing slash from path if present
                const clean_path = if (std.mem.endsWith(u8, self.config.path, "/")) 
                    self.config.path[0..self.config.path.len-1] 
                else 
                    self.config.path;
                break :blk try std.fmt.bufPrint(path_buffer[0..], "{s}/peerjs?key={s}&id={s}&token={s}", .{ clean_path, self.config.key, actual_peer_id, actual_token });
            }
        };

        std.log.info("WebSocket path: {s}", .{ws_path});

        // Build headers for WebSocket handshake
        var headers_buffer: [256]u8 = undefined;
        const headers = try std.fmt.bufPrint(headers_buffer[0..], "Host: {s}:{d}", .{ self.config.host, self.config.port });

        std.log.info("WebSocket headers: {s}", .{headers});

        // Perform WebSocket handshake
        client.handshake(ws_path, .{
            .timeout_ms = self.config.timeout,
            .headers = headers,
        }) catch |err| {
            client.deinit();
            std.log.err("WebSocket handshake failed: {}", .{err});
            return SignalingError.ConnectionFailed;
        };

        self.client = client;
        self.connected = true;

        // Start heartbeat timer
        self.heartbeat_timer = std.time.Timer.start() catch null;

        // Wait for OPEN message from server
        try self.waitForOpen(actual_peer_id);

        std.log.info("Connected to PeerJS server with peer ID: {s}", .{self.peer_id.?});
    }

    /// Request a peer ID and token from the server via HTTP
    pub fn requestPeerIdAndToken(self: *Self) SignalingError!PeerIdTokenPair {
        var http_client = http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        // Build HTTP URL - format: {protocol}://{host}:{port}{path}peerjs/id?ts={timestamp}&key={key}
        var url_buffer: [512]u8 = undefined;
        const timestamp = std.time.timestamp();
        const protocol = if (self.config.secure) "https" else "http";
        
        const url = blk: {
            if (std.mem.eql(u8, self.config.path, "/")) {
                break :blk try std.fmt.bufPrint(url_buffer[0..], "{s}://{s}:{d}/peerjs/id?ts={d}&key={s}", .{ protocol, self.config.host, self.config.port, timestamp, self.config.key });
            } else {
                // Remove trailing slash from path if present
                const clean_path = if (std.mem.endsWith(u8, self.config.path, "/")) 
                    self.config.path[0..self.config.path.len-1] 
                else 
                    self.config.path;
                break :blk try std.fmt.bufPrint(url_buffer[0..], "{s}://{s}:{d}{s}/peerjs/id?ts={d}&key={s}", .{ protocol, self.config.host, self.config.port, clean_path, timestamp, self.config.key });
            }
        };

        std.log.info("Requesting peer ID and token from: {s}", .{url});

        const uri = std.Uri.parse(url) catch |err| switch (err) {
            error.InvalidPort => return SignalingError.InvalidPort,
            error.UnexpectedCharacter => return SignalingError.InvalidUri,
            error.InvalidFormat => return SignalingError.UriFormatError,
        };
        
        var server_header_buffer: [8192]u8 = undefined;
        var request = http_client.open(.GET, uri, .{
            .server_header_buffer = &server_header_buffer,
        }) catch |err| {
            std.log.err("HTTP open failed: {}", .{err});
            return SignalingError.HttpConnectionFailed;
        };
        defer request.deinit();

        request.send() catch |err| {
            std.log.err("HTTP send failed: {}", .{err});
            return SignalingError.HttpRequestFailed;
        };
        
        request.finish() catch |err| {
            std.log.err("HTTP finish failed: {}", .{err});
            return SignalingError.HttpRequestFailed;
        };
        
        request.wait() catch |err| {
            std.log.err("HTTP wait failed: {}", .{err});
            return SignalingError.HttpRequestFailed;
        };

        if (request.response.status != .ok) {
            std.log.err("HTTP request failed with status: {}", .{request.response.status});
            return SignalingError.HttpRequestFailed;
        }

        // Read the response (should be JSON with peer ID and token)
        var response_buffer: [1024]u8 = undefined;
        const response_len = request.readAll(response_buffer[0..]) catch |err| {
            std.log.err("HTTP read failed: {}", .{err});
            return SignalingError.HttpRequestFailed;
        };
        
        const response_data = std.mem.trim(u8, response_buffer[0..response_len], " \t\r\n");
        std.log.info("Received response from server: {s}", .{response_data});

        // Check if response looks like JSON (starts with '{' or '[')
        const is_json = response_data.len > 0 and (response_data[0] == '{' or response_data[0] == '[');
        
        if (is_json) {
            // Parse JSON response
            const parsed = json.parseFromSlice(json.Value, self.allocator, response_data, .{}) catch |err| {
                std.log.err("Failed to parse JSON response: {}", .{err});
                // Fallback to plain text parsing
                const peer_id = std.mem.trim(u8, response_data, " \t\r\n\"");
                const token = try self.generateRandomToken();
                std.log.info("Using fallback: peer_id={s}, generated_token={s}", .{ peer_id, token });
                return PeerIdTokenPair{
                    .peer_id = try self.allocator.dupe(u8, peer_id),
                    .token = token,
                };
            };
            defer parsed.deinit();

            // Extract peer ID and token from JSON
            const obj = parsed.value.object;
            const peer_id = obj.get("id") orelse obj.get("peer_id") orelse {
                std.log.err("No peer ID found in JSON response", .{});
                return SignalingError.InvalidResponse;
            };
            
            const token_obj = obj.get("token");
            const token = if (token_obj) |tok| 
                try self.allocator.dupe(u8, tok.string)
            else 
                try self.generateRandomToken();

            std.log.info("Parsed JSON: peer_id={s}, token={s}", .{ peer_id.string, token });
            return PeerIdTokenPair{
                .peer_id = try self.allocator.dupe(u8, peer_id.string),
                .token = token,
            };
        } else {
            // Response is plain text peer ID
            const peer_id = std.mem.trim(u8, response_data, " \t\r\n\"");
            
            // Validate that it looks like a peer ID (basic validation)
            if (peer_id.len == 0) {
                std.log.err("Empty peer ID received from server", .{});
                return SignalingError.InvalidResponse;
            }
            
            const token = try self.generateRandomToken();
            std.log.info("Parsed plain text: peer_id={s}, generated_token={s}", .{ peer_id, token });
            return PeerIdTokenPair{
                .peer_id = try self.allocator.dupe(u8, peer_id),
                .token = token,
            };
        }
    }

    /// Generate a random token for WebSocket connection
    pub fn generateRandomToken(self: *Self) SignalingError![]const u8 {
        var buffer: [16]u8 = undefined;
        // Use nanoseconds for better entropy  
        var rng = std.Random.DefaultPrng.init(@truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));
        
        for (buffer[0..]) |*byte| {
            byte.* = rng.random().int(u8);
        }

        // Convert to alphanumeric string
        var token_buffer: [32]u8 = undefined;
        const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
        
        for (buffer, 0..) |byte, i| {
            token_buffer[i] = chars[byte % chars.len];
        }

        return try self.allocator.dupe(u8, token_buffer[0..16]);
    }

    /// Disconnect from the signaling server
    pub fn disconnect(self: *Self) void {
        if (!self.connected) return;

        if (self.client) |*client| {
            client.close(.{}) catch {};
            client.deinit();
            self.client = null;
        }

        self.connected = false;
        std.log.info("Disconnected from PeerJS server", .{});
    }

    /// Send a signaling message to a peer
    pub fn sendMessage(self: *Self, message: SignalingMessage) SignalingError!void {
        if (!self.connected or self.client == null) {
            return SignalingError.ConnectionFailed;
        }

        // Create JSON object manually to match PeerJS format exactly
        var json_buffer: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(json_buffer[0..]);
        const writer = stream.writer();

        try writer.writeAll("{");
        try writer.print("\"type\":\"{s}\"", .{message.type.toString()});

        if (message.src) |src| {
            try writer.print(",\"src\":\"{s}\"", .{src});
        }

        if (message.dst) |dst| {
            try writer.print(",\"dst\":\"{s}\"", .{dst});
        }

        switch (message.payload) {
            .none => {},
            .peer_id => |id| try writer.print(",\"payload\":\"{s}\"", .{id}),
            .error_msg => |msg| try writer.print(",\"payload\":\"{s}\"", .{msg}),
            .connection_id => |id| try writer.print(",\"payload\":\"{s}\"", .{id}),
            .data => |data| try writer.print(",\"payload\":\"{s}\"", .{data}),
            .sdp => |sdp| {
                try writer.print(",\"payload\":{{\"type\":\"{s}\",\"sdp\":\"{s}\"}}", .{ @tagName(sdp.type), sdp.sdp });
            },
            .candidate => |candidate| {
                try writer.print(",\"payload\":{{\"candidate\":\"{s}\"", .{candidate.candidate});
                if (candidate.sdp_mid) |mid| {
                    try writer.print(",\"sdpMid\":\"{s}\"", .{mid});
                }
                if (candidate.sdp_mline_index) |idx| {
                    try writer.print(",\"sdpMLineIndex\":{d}", .{idx});
                }
                try writer.writeAll("}");
            },
        }

        try writer.writeAll("}");
        
        const json_data = stream.getWritten();

        // Send via WebSocket (websocket library requires mutable data for masking)
        const mutable_data = try self.allocator.dupe(u8, json_data);
        defer self.allocator.free(mutable_data);

        self.client.?.write(mutable_data) catch |err| {
            std.log.err("Failed to send WebSocket message: {}", .{err});
            return SignalingError.ConnectionFailed;
        };

        std.log.debug("Sent signaling message: {s}", .{json_data});
    }

    /// Receive a signaling message (non-blocking)
    pub fn receiveMessage(self: *Self) SignalingError!?SignalingMessage {
        if (!self.connected or self.client == null) {
            return SignalingError.ConnectionFailed;
        }

        // Check for incoming messages
        const message = self.client.?.read() catch |err| {
            // Handle timeout as no message available
            const err_name = @errorName(err);
            if (std.mem.eql(u8, err_name, "Timeout")) {
                return null;
            }
            std.log.err("Failed to receive WebSocket message: {}", .{err});
            return SignalingError.ConnectionFailed;
        };

        if (message) |msg| {
            std.log.debug("Received raw message: {s}", .{msg.data});

            // Parse JSON message
            const parsed = json.parseFromSlice(json.Value, self.allocator, msg.data, .{}) catch |err| {
                std.log.err("Failed to parse JSON message: {}", .{err});
                return SignalingError.InvalidMessage;
            };
            defer parsed.deinit();

            return try self.parseMessage(parsed.value);
        }

        return null;
    }

    /// Send heartbeat to keep connection alive
    pub fn sendHeartbeat(self: *Self) SignalingError!void {
        const heartbeat_msg = SignalingMessage{
            .type = .heartbeat,
        };

        try self.sendMessage(heartbeat_msg);
    }

    /// Check if heartbeat should be sent
    pub fn shouldSendHeartbeat(self: *Self) bool {
        if (self.heartbeat_timer) |*timer| {
            const elapsed = timer.read() / std.time.ns_per_ms;
            return elapsed >= self.config.ping_interval;
        }
        return false;
    }

    /// Get the current peer ID
    pub fn getPeerId(self: *Self) ?[]const u8 {
        return self.peer_id;
    }

    // Private helper methods

    fn waitForOpen(self: *Self, peer_id: []const u8) SignalingError!void {
        var attempts: u32 = 0;
        const max_attempts = self.config.timeout / 100; // Check every 100ms

        while (attempts < max_attempts) {
            if (self.receiveMessage() catch null) |msg| {
                defer {
                    var mutable_msg = msg;
                    mutable_msg.deinit(self.allocator);
                }

                switch (msg.type) {
                    .open => {
                        // OPEN message just confirms connection is ready
                        // The peer ID is already known from the HTTP request
                        self.peer_id = try self.allocator.dupe(u8, peer_id);
                        std.log.info("WebSocket connection opened successfully", .{});
                        return;
                    },
                    .error_msg => {
                        std.log.err("Server error: {s}", .{msg.payload.error_msg});
                        return SignalingError.ServerError;
                    },
                    .id_taken => {
                        std.log.err("Peer ID already taken", .{});
                        return SignalingError.InvalidPeerId;
                    },
                    .invalid_key => {
                        std.log.err("Invalid API key", .{});
                        return SignalingError.ServerRejected;
                    },
                    else => {
                        // Unexpected message type, continue waiting
                        std.log.debug("Waiting for OPEN, got: {s}", .{@tagName(msg.type)});
                    },
                }
            }

            std.time.sleep(100 * std.time.ns_per_ms);
            attempts += 1;
        }

        return SignalingError.Timeout;
    }

    fn parseMessage(self: *Self, json_value: json.Value) SignalingError!SignalingMessage {
        const obj = json_value.object;

        // Parse message type
        const type_str = obj.get("type").?.string;
        const msg_type = MessageType.fromString(type_str) orelse {
            std.log.err("Unknown message type: {s}", .{type_str});
            return SignalingError.InvalidMessage;
        };

        var message = SignalingMessage{ .type = msg_type };

        // Parse optional fields
        if (obj.get("src")) |src| {
            message.src = try self.allocator.dupe(u8, src.string);
        }

        if (obj.get("dst")) |dst| {
            message.dst = try self.allocator.dupe(u8, dst.string);
        }

        // Parse payload based on message type
        if (obj.get("payload")) |payload_obj| {
            message.payload = switch (msg_type) {
                .open => .{ .peer_id = try self.allocator.dupe(u8, payload_obj.string) },
                .error_msg => .{ .error_msg = try self.allocator.dupe(u8, payload_obj.string) },
                .offer, .answer => blk: {
                    // Check if payload is string or object
                    if (payload_obj == .string) {
                        const payload_str = payload_obj.string;
                        // Check if this looks like a connection ID or data message
                        if (std.mem.startsWith(u8, payload_str, "dc_")) {
                            // Connection establishment message
                            break :blk .{ .connection_id = try self.allocator.dupe(u8, payload_str) };
                        } else {
                            // Data message  
                            break :blk .{ .data = try self.allocator.dupe(u8, payload_str) };
                        }
                    } else {
                        // WebRTC SDP message
                        const sdp_obj = payload_obj.object;
                        break :blk .{ .sdp = SessionDescription{
                            .type = if (msg_type == .offer) .offer else .answer,
                            .sdp = try self.allocator.dupe(u8, sdp_obj.get("sdp").?.string),
                        } };
                    }
                },
                .data => .{ .data = try self.allocator.dupe(u8, payload_obj.string) },
                .candidate => blk: {
                    const candidate_obj = payload_obj.object;
                    var candidate = IceCandidate{
                        .candidate = try self.allocator.dupe(u8, candidate_obj.get("candidate").?.string),
                    };

                    if (candidate_obj.get("sdpMid")) |mid| {
                        candidate.sdp_mid = try self.allocator.dupe(u8, mid.string);
                    }

                    if (candidate_obj.get("sdpMLineIndex")) |idx| {
                        candidate.sdp_mline_index = @intCast(idx.integer);
                    }

                    break :blk .{ .candidate = candidate };
                },
                else => .none,
            };
        }

        return message;
    }
};

// Tests
test "MessageType serialization" {
    try std.testing.expectEqual(MessageType.heartbeat, MessageType.fromString("HEARTBEAT").?);
    try std.testing.expectEqualStrings("HEARTBEAT", MessageType.heartbeat.toString());
    try std.testing.expectEqual(@as(?MessageType, null), MessageType.fromString("INVALID"));
}

test "SignalingClient creation" {
    const allocator = std.testing.allocator;

    var client = try SignalingClient.init(allocator, .{});
    defer client.deinit();

    try std.testing.expect(!client.connected);
    try std.testing.expectEqual(@as(?[]const u8, null), client.getPeerId());
}

test "SignalingMessage cleanup" {
    const allocator = std.testing.allocator;

    var message = SignalingMessage{
        .type = .open,
        .src = try allocator.dupe(u8, "test-src"),
        .dst = try allocator.dupe(u8, "test-dst"),
        .payload = .{ .peer_id = try allocator.dupe(u8, "test-peer") },
    };

    message.deinit(allocator);
    // If we reach here without memory leaks, the test passes
}

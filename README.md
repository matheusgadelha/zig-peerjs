# Zig PeerJS Connect

A **complete WebRTC data connection library** for Zig that implements the PeerJS protocol for peer-to-peer communication with full HTTP ID request support.

## 🚀 Features

- ✅ **Full PeerJS Protocol Implementation** - Complete compatibility with PeerJS servers
- ✅ **HTTP ID Request** - Automatic peer ID generation from PeerJS servers 
- ✅ **WebSocket Signaling** - Real-time peer discovery and connection establishment
- ✅ **Data Connections** - Bidirectional peer-to-peer data transfer
- ✅ **Connection Management** - Proper lifecycle handling and cleanup
- ✅ **Error Handling** - Comprehensive error reporting and recovery
- ✅ **Debug Support** - Configurable logging levels

## 📋 Quick Start

### 1. **Install Dependencies**

```bash
# Install Node.js for PeerJS server (if testing locally)
npm install -g peerjs

# Build the Zig library
zig build
```

### 2. **Basic Usage**

```zig
const std = @import("std");
const peerjs = @import("zig_peerjs_connect");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create and configure peer client
    var peer_client = try peerjs.PeerClient.init(allocator, .{
        .debug = 1, // Enable error logging
    });
    defer peer_client.deinit();

    // Get assigned peer ID
    const my_peer_id = try peer_client.getId();
    std.log.info("My peer ID: {s}", .{my_peer_id});

    // Connect to another peer
    var connection = try peer_client.connectToPeer("target-peer-id");
    defer connection.deinit();

    // Send data
    try connection.send("Hello, peer!");

    // Receive data
    var buffer: [1024]u8 = undefined;
    if (connection.receive(buffer[0..])) |data| {
        std.log.info("Received: {s}", .{data});
    } else |err| {
        std.log.err("No messages: {}", .{err});
    }
}
```

### Simple Server-Client Example

The project includes a minimal server-client example that demonstrates basic messaging:

```bash
# Build the project
zig build

# Terminal 1 - Start the server
zig build server -- my-server-123
# OR directly: ./zig-out/bin/simple_server my-server-123

# Terminal 2 - Start the client
zig build client -- my-client-456 my-server-123
# OR directly: ./zig-out/bin/simple_client my-client-456 my-server-123

# You can also use the interactive demo script
./demo_simple.sh
```

**How it works:**
- The **server** takes a server ID as argument and listens for incoming connections
- The **client** takes a client ID and server ID, connects to the server
- Type messages in the client terminal - they appear on the server
- Very simple and minimal - perfect for learning the basics

### Chat Demo Usage

The chat demo provides an interactive command-line interface for peer-to-peer communication:

```bash
# Start first instance (will auto-generate peer ID)
./zig-out/bin/zig_peerjs_chat

# Start second instance with specific IDs
./zig-out/bin/zig_peerjs_chat alice bob

# Use local PeerJS server
./zig-out/bin/zig_peerjs_chat --local alice bob

# Enable debug logging
./zig-out/bin/zig_peerjs_chat --debug alice bob
```

#### Chat Commands

- **`connect <peer-id>`**: Connect to a specific peer
- **`check`**: Check for new messages
- **`status`**: Show connection status
- **`quit`**: Exit the chat
- **Any other text**: Send as message

## API Reference

### PeerClient

The main interface for managing peer connections.

```zig
pub const PeerClient = struct {
    // Initialize a new peer client
    pub fn init(allocator: std.mem.Allocator, config: PeerConfig) PeerError!PeerClient;
    
    // Clean up resources
    pub fn deinit(self: *Self) void;
    
    // Connect to PeerJS server and get peer ID
    pub fn getId(self: *Self) PeerError![]const u8;
    
    // Establish connection to another peer
    pub fn connectToPeer(self: *Self, peer_id: []const u8) PeerError!*DataConnection;
    
    // Process incoming signaling messages
    pub fn handleIncomingMessages(self: *Self) PeerError!void;
};
```

### DataConnection

Represents a connection to another peer.

```zig
pub const DataConnection = struct {
    // Send data to connected peer
    pub fn send(self: *Self, data: []const u8) PeerError!void;
    
    // Receive data from connected peer (non-blocking)
    pub fn receive(self: *Self, buffer: []u8) PeerError![]const u8;
    
    // Close the connection
    pub fn close(self: *Self) void;
    
    // Clean up resources
    pub fn deinit(self: *Self) void;
};
```

### Configuration Options

```zig
pub const PeerConfig = struct {
    host: []const u8 = "0.peerjs.com",        // PeerJS server host
    port: u16 = 443,                          // Server port
    secure: bool = true,                      // Use HTTPS/WSS
    key: []const u8 = "peerjs",               // API key
    path: []const u8 = "/",                   // Server path
    peer_id: ?[]const u8 = null,              // Custom peer ID
    timeout_ms: u32 = 30000,                  // Connection timeout
    debug: u8 = 0,                            // Debug level (0-3)
    heartbeat_interval: u32 = 5000,           // Heartbeat interval
};
```

### Error Types

```zig
pub const PeerError = error{
    ConnectionFailed,     // Failed to connect to server
    InvalidPeerId,        // Invalid peer ID format
    PeerUnavailable,      // Target peer not available
    NetworkError,         // Network communication error
    InvalidResponse,      // Invalid server response
    Timeout,              // Operation timeout
    Disconnected,         // Peer disconnected
    InvalidData,          // Invalid data format
    BufferTooSmall,       // Receive buffer too small
    NoMessages,           // No messages available
    // ... plus standard allocator and signaling errors
};
```

## Advanced Usage

### Custom PeerJS Server

```zig
var peer_client = try peerjs.PeerClient.init(allocator, .{
    .host = "your.peerjs.server.com",
    .port = 9000,
    .secure = false,
    .key = "your-custom-key",
    .debug = 2,
});
```

### Message Processing Loop

```zig
while (running) {
    // Process signaling messages
    try peer_client.handleIncomingMessages();
    
    // Check for data from connections
    var it = peer_client.connections.iterator();
    while (it.next()) |entry| {
        const connection = entry.value_ptr.*;
        var buffer: [4096]u8 = undefined;
        
        if (connection.receive(buffer[0..])) |data| {
            // Process received data
            processMessage(data);
        } else |err| switch (err) {
            peerjs.PeerError.NoMessages => {}, // No messages available
            else => std.log.err("Connection error: {}", .{err}),
        }
    }
    
    // Small delay to prevent busy waiting
    std.time.sleep(10 * std.time.ns_per_ms);
}
```

### Peer ID Validation

```zig
const peer_id = "my-peer-123";
if (peerjs.isValidPeerId(peer_id)) {
    // Valid peer ID: alphanumeric, hyphens, underscores
    // Length: 1-50 characters
    // Cannot start or end with hyphen
} else {
    // Invalid peer ID
}
```

## Testing

The library includes comprehensive tests covering:

- **Unit Tests**: Individual component functionality
- **Integration Tests**: Component interaction
- **Error Handling**: Edge cases and error conditions
- **Memory Management**: Leak detection and cleanup
- **Performance Tests**: Large-scale operations

```bash
# Run all tests
zig build test

# Run with verbose output
zig test src/root.zig --verbose

# Test specific components
zig test src/signaling.zig
zig test src/chat_demo.zig
```

## Architecture Details

### Signaling Protocol

The library implements the PeerJS WebSocket signaling protocol:

1. **Connection Establishment**: WebSocket connection to PeerJS server
2. **Peer Registration**: Receive unique peer ID or use custom ID
3. **Offer/Answer Exchange**: SDP negotiation for WebRTC connection
4. **ICE Candidate Exchange**: Network connectivity establishment
5. **Data Channel Setup**: Direct peer-to-peer communication

### Message Types

- **HEARTBEAT**: Keep-alive messages
- **OPEN**: Server assigns peer ID
- **OFFER**: WebRTC connection offer
- **ANSWER**: WebRTC connection answer
- **CANDIDATE**: ICE candidates for connectivity
- **LEAVE**: Peer disconnection notification
- **ERROR**: Error messages from server

### Memory Management

- **RAII Pattern**: Automatic resource cleanup with `defer`
- **Arena Allocation**: Efficient memory management for temporary data
- **Leak Detection**: Comprehensive testing for memory leaks
- **Safe Cleanup**: Proper cleanup even on error conditions

## Troubleshooting

### Common Issues

1. **Connection Failed**
   ```
   Error: PeerError.ConnectionFailed
   ```
   - Check internet connection
   - Verify PeerJS server is accessible
   - Try using `--local` flag for local development

2. **Invalid Peer ID**
   ```
   Error: PeerError.InvalidPeerId
   ```
   - Peer IDs must be 1-50 characters
   - Only alphanumeric, hyphens, and underscores allowed
   - Cannot start or end with hyphen

3. **Peer Unavailable**
   ```
   Error: PeerError.PeerUnavailable
   ```
   - Target peer is not online
   - Check peer ID spelling
   - Ensure target peer is connected to same server

### Debug Logging

Enable debug logging for troubleshooting:

```zig
var peer_client = try peerjs.PeerClient.init(allocator, .{
    .debug = 3, // Maximum debug level
});
```

Debug levels:
- **0**: No debug output
- **1**: Errors only
- **2**: Errors and warnings
- **3**: All debug information

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass: `zig build test`
5. Update documentation as needed
6. Submit a pull request

### Code Style

- Follow Zig standard formatting: `zig fmt src/`
- Add comprehensive tests for new features
- Document public APIs with doc comments
- Use meaningful variable and function names

## License

This project is open source. See the LICENSE file for details.
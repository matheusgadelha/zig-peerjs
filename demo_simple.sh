#!/bin/bash

# Automated Simple Server-Client Test for Zig PeerJS Connect

echo "🚀 Testing Zig PeerJS Simple Server-Client..."

# Check if binaries exist
if [ ! -f "zig-out/bin/simple_server" ] || [ ! -f "zig-out/bin/simple_client" ]; then
    echo "❌ Binaries not found. Building..."
    zig build || exit 1
fi

# Default IDs
SERVER_ID="test-server-$$"  # Use process ID to make unique
CLIENT_ID="test-client-$$"

# Clean up function
cleanup() {
    echo "🧹 Cleaning up..."
    if [ ! -z "$SERVER_PID" ]; then
        kill $SERVER_PID 2>/dev/null
        wait $SERVER_PID 2>/dev/null
    fi
    exit $1
}

# Set up cleanup on exit
trap 'cleanup 0' EXIT
trap 'cleanup 1' INT TERM

# Start server in background
echo "🖥️  Starting server (ID: $SERVER_ID)..."
./zig-out/bin/simple_server "$SERVER_ID" > server.log 2>&1 &
SERVER_PID=$!

# Wait for server to start
sleep 3

# Check if server is still running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "❌ Server failed to start. Check server.log:"
    cat server.log
    exit 1
fi

echo "✅ Server started (PID: $SERVER_PID)"

# Start client and send test message
echo "📱 Starting client (ID: $CLIENT_ID) and sending test message..."
echo "Hello from automated test! Time: $(date)" | ./zig-out/bin/simple_client "$CLIENT_ID" "$SERVER_ID" > client.log 2>&1 &
CLIENT_PID=$!

# Wait for client to finish
sleep 5

# Check results
echo "📋 Results:"
if grep -q "Connected to PeerJS server" server.log; then
    echo "✅ Server connected to PeerJS"
else
    echo "❌ Server failed to connect to PeerJS"
fi

if grep -q "Stored data from $CLIENT_ID" server.log; then
    echo "✅ Message received by server"
    echo "📥 $(grep "Stored data from $CLIENT_ID" server.log | head -1)"
elif grep -q "Message from $CLIENT_ID" server.log; then
    echo "✅ Message received by server"
    echo "📥 $(grep "Message from $CLIENT_ID" server.log | head -1)"
else
    echo "❌ No message received by server"
fi

if grep -q "Connected to server" client.log; then
    echo "✅ Client connected to server"
else
    echo "❌ Client failed to connect to server"
fi

if grep -q "Sent:" client.log; then
    echo "✅ Client sent message"
else
    echo "❌ Client failed to send message"
fi

# Show logs if there were issues
if ! grep -q "Message from $CLIENT_ID" server.log; then
    echo ""
    echo "🔍 Server log:"
    cat server.log
    echo ""
    echo "🔍 Client log:"
    cat client.log
fi

# Clean up log files
rm -f server.log client.log

echo "�� Test completed!" 
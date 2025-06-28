#!/bin/bash

# Zig PeerJS Chat Demo Script
# This script demonstrates bidirectional communication by launching two chat instances

set -e

echo "🗣️  Zig PeerJS Bidirectional Chat Demo"
echo "======================================"
echo ""

# Function to clean up background processes
cleanup() {
    echo ""
    echo "🧹 Cleaning up..."
    kill $ALICE_PID $BOB_PID 2>/dev/null || true
    # Clean up message storage
    rm -rf /tmp/zig_peerjs_messages 2>/dev/null || true
    echo "✅ Cleanup complete"
    exit 0
}

# Set up signal handlers
trap cleanup EXIT INT TERM

# Build the project
echo "🔨 Building chat demo..."
zig build || {
    echo "❌ Build failed!"
    exit 1
}
echo "✅ Build successful"
echo ""

# Clear any existing message storage
rm -rf /tmp/zig_peerjs_messages 2>/dev/null || true

# Define peer IDs for the demo
ALICE_ID="alice-demo-peer"
BOB_ID="bob-demo-peer"

echo "🚀 Starting chat demo between '$ALICE_ID' and '$BOB_ID'"
echo ""
echo "📋 Instructions:"
echo "   - Two terminal windows will open"
echo "   - Alice (left) and Bob (right) can send messages to each other"
echo "   - Type messages and press Enter to send"
echo "   - Type 'check' to check for new messages"
echo "   - Type 'quit' in either window to end the demo"
echo ""
echo "⏳ Starting in 3 seconds..."
sleep 3

# Create a function to run chat instances
run_chat_instance() {
    local name="$1"
    local my_id="$2"
    local target_id="$3"
    local position="$4"
    
    echo ""
    echo "🟢 Starting $name chat instance..."
    
    if command -v osascript >/dev/null 2>&1; then
        # macOS - use AppleScript to open new terminal windows
        osascript <<EOF
tell application "Terminal"
    activate
    set newTab to do script "cd '$PWD' && echo '👤 $name Chat Window' && echo 'ID: $my_id -> $target_id' && echo '' && ./zig-out/bin/zig_peerjs_chat '$my_id' '$target_id'"
    set position of front window to {$position, 100}
    set size of front window to {600, 400}
end tell
EOF
    elif command -v gnome-terminal >/dev/null 2>&1; then
        # Linux with GNOME Terminal
        gnome-terminal --geometry=80x24+$position+100 --title="$name Chat" -- bash -c "
            echo '👤 $name Chat Window'
            echo 'ID: $my_id -> $target_id'
            echo ''
            cd '$PWD'
            ./zig-out/bin/zig_peerjs_chat '$my_id' '$target_id'
            read -p 'Press Enter to close...'
        " &
    elif command -v xterm >/dev/null 2>&1; then
        # Fallback to xterm
        xterm -geometry 80x24+$position+100 -title "$name Chat" -e bash -c "
            echo '👤 $name Chat Window'
            echo 'ID: $my_id -> $target_id'
            echo ''
            cd '$PWD'
            ./zig-out/bin/zig_peerjs_chat '$my_id' '$target_id'
            read -p 'Press Enter to close...'
        " &
    else
        echo "⚠️  No suitable terminal emulator found. Running in background mode..."
        echo "   You can manually run:"
        echo "   ./zig-out/bin/zig_peerjs_chat '$my_id' '$target_id'"
        return 1
    fi
}

# Check if we can open new terminal windows
if command -v osascript >/dev/null 2>&1 || command -v gnome-terminal >/dev/null 2>&1 || command -v xterm >/dev/null 2>&1; then
    echo "🎭 Opening separate terminal windows for each peer..."
    
    # Start Alice and Bob in separate terminal windows
    run_chat_instance "Alice" "$ALICE_ID" "$BOB_ID" 50
    sleep 2
    run_chat_instance "Bob" "$BOB_ID" "$ALICE_ID" 700
    
    echo ""
    echo "🎉 Chat demo started!"
    echo "   - Check the new terminal windows"
    echo "   - Send messages between Alice and Bob"
    echo "   - Press Ctrl+C here to stop the demo"
    echo ""
    
    # Wait for user to stop the demo
    echo "Press Ctrl+C to stop the demo..."
    while true; do
        sleep 1
    done
    
else
    echo "⚠️  Cannot open new terminal windows automatically."
    echo ""
    echo "🔧 Manual Setup Instructions:"
    echo ""
    echo "1️⃣  Open TWO terminal windows/tabs"
    echo ""
    echo "2️⃣  In the FIRST terminal, run:"
    echo "   ./zig-out/bin/zig_peerjs_chat $ALICE_ID $BOB_ID"
    echo ""
    echo "3️⃣  In the SECOND terminal, run:"
    echo "   ./zig-out/bin/zig_peerjs_chat $BOB_ID $ALICE_ID"
    echo ""
    echo "4️⃣  Send messages between the two chat instances!"
    echo ""
    echo "💡 Demo scenario:"
    echo "   - Alice sends: 'Hello Bob! 👋'"
    echo "   - Bob types 'check' to see the message"
    echo "   - Bob sends: 'Hi Alice! How are you?'"
    echo "   - Alice types 'check' to see Bob's reply"
    echo "   - Continue the conversation..."
    echo ""
    echo "🎬 You can also test with custom peer IDs:"
    echo "   ./zig-out/bin/zig_peerjs_chat"
    echo ""
    echo "Press Enter to continue..."
    read
fi 
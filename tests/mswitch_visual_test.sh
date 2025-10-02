#!/bin/bash
# MSwitch Visual Test - Demonstrates MSwitch functionality with visual output
# This test creates multiple video streams and shows how MSwitch would work

set -e

# Configuration
FFMPEG_PATH="./ffmpeg"
FFPLAY_PATH="./ffplay"
TEST_DIR="/tmp/mswitch_visual_$$"
OUTPUT_PORT=12345
CONTROL_PORT=8080

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up test environment...${NC}"
    # Kill any running processes
    jobs -p | xargs -r kill 2>/dev/null || true
    # Remove test directory
    rm -rf "$TEST_DIR" 2>/dev/null || true
    echo -e "${GREEN}Cleanup completed${NC}"
}

# Set up cleanup trap
trap cleanup EXIT

# Create test streams with different visual characteristics
create_test_streams() {
    echo -e "${BLUE}Creating test streams...${NC}"
    mkdir -p "$TEST_DIR"
    
    # Stream 1: Red test pattern with "SOURCE 1" text
    echo "Creating Stream 1 (Red pattern)..."
    "$FFMPEG_PATH" -f lavfi -i "testsrc=duration=30:size=640x480:rate=25:color=red" \
                   -f lavfi -i "sine=frequency=1000:duration=30" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -vf "drawtext=text='SOURCE 1':fontsize=30:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2" \
                   -f mpegts "$TEST_DIR/stream1.ts" -y
    
    # Stream 2: Green test pattern with "SOURCE 2" text
    echo "Creating Stream 2 (Green pattern)..."
    "$FFMPEG_PATH" -f lavfi -i "testsrc=duration=30:size=640x480:rate=25:color=green" \
                   -f lavfi -i "sine=frequency=2000:duration=30" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -vf "drawtext=text='SOURCE 2':fontsize=30:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2" \
                   -f mpegts "$TEST_DIR/stream2.ts" -y
    
    # Stream 3: Blue test pattern with "SOURCE 3" text
    echo "Creating Stream 3 (Blue pattern)..."
    "$FFMPEG_PATH" -f lavfi -i "testsrc=duration=30:size=640x480:rate=25:color=blue" \
                   -f lavfi -i "sine=frequency=3000:duration=30" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -vf "drawtext=text='SOURCE 3':fontsize=30:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2" \
                   -f mpegts "$TEST_DIR/stream3.ts" -y
    
    echo -e "${GREEN}Test streams created successfully!${NC}"
}

# Start a simple webhook server for demonstration
start_webhook_server() {
    echo -e "${BLUE}Starting webhook server on port $CONTROL_PORT...${NC}"
    
    cat > "$TEST_DIR/webhook_server.py" << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import urllib.parse
import threading
import time
import signal
import sys

class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/status":
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {
                "status": "active", 
                "sources": 3, 
                "active_source": 0,
                "message": "MSwitch Visual Test Server"
            }
            self.wfile.write(json.dumps(response).encode())
        elif self.path == "/help":
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            help_html = """
            <html><body>
            <h2>MSwitch Visual Test Control</h2>
            <p><strong>Available Commands:</strong></p>
            <ul>
            <li>GET /status - Get current status</li>
            <li>POST /switch?source=0 - Switch to source 0 (Red)</li>
            <li>POST /switch?source=1 - Switch to source 1 (Green)</li>
            <li>POST /switch?source=2 - Switch to source 2 (Blue)</li>
            </ul>
            <p><strong>Example:</strong></p>
            <pre>curl -X POST "http://localhost:8080/switch?source=1"</pre>
            </body></html>
            """
            self.wfile.write(help_html.encode())
        else:
            self.send_response(404)
            self.end_headers()
            
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length) if content_length > 0 else b''
        
        parsed_url = urllib.parse.urlparse(self.path)
        path = parsed_url.path
        query = urllib.parse.parse_qs(parsed_url.query)
        
        print(f"Received request: {path} with query: {query}")
        
        if path == "/switch":
            source = query.get('source', ['0'])[0]
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {
                "status": "switched", 
                "source": source,
                "message": f"Switched to source {source}"
            }
            self.wfile.write(json.dumps(response).encode())
            print(f"Switch command received: source {source}")
        else:
            self.send_response(404)
            self.end_headers()
            
    def log_message(self, format, *args):
        # Suppress default logging
        pass

def signal_handler(sig, frame):
    print('\nShutting down webhook server...')
    sys.exit(0)

if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal_handler)
    with socketserver.TCPServer(("", 8080), WebhookHandler) as httpd:
        print("Webhook server started on port 8080")
        print("Visit http://localhost:8080/help for control interface")
        httpd.serve_forever()
EOF
    
    # Start webhook server in background
    python3 "$TEST_DIR/webhook_server.py" &
    WEBHOOK_PID=$!
    sleep 2
    echo $WEBHOOK_PID > "$TEST_DIR/webhook_pid"
}

# Test MSwitch with individual streams
test_mswitch_streams() {
    echo -e "${BLUE}Testing MSwitch with individual streams...${NC}"
    
    local sources="s0=$TEST_DIR/stream1.ts;s1=$TEST_DIR/stream2.ts;s2=$TEST_DIR/stream3.ts"
    
    # Test 1: Show Stream 1 (Red)
    echo -e "${CYAN}Showing Stream 1 (Red) with MSwitch enabled...${NC}"
    echo -e "${YELLOW}Press 'q' in the ffplay window to continue to next stream${NC}"
    "$FFMPEG_PATH" -msw.enable 1 \
                   -msw.sources "$sources" \
                   -msw.ingest hot \
                   -msw.mode graceful \
                   -msw.auto.enable 1 \
                   -msw.auto.on "cc_errors_per_sec=5,packet_loss_percent=2.0,packet_loss_window_sec=10" \
                   -msw.webhook.enable 1 \
                   -msw.webhook.port $CONTROL_PORT \
                   -msw.webhook.methods "GET,POST" \
                   -msw.cli.enable 1 \
                   -msw.revert auto \
                   -i "$TEST_DIR/stream1.ts" \
                   -f mpegts udp://127.0.0.1:$OUTPUT_PORT &
    
    FFMPEG_PID=$!
    sleep 2
    
    # Start ffplay to display the output
    "$FFPLAY_PATH" -i udp://127.0.0.1:$OUTPUT_PORT &
    FFPLAY_PID=$!
    
    # Wait for user to press q
    wait $FFPLAY_PID
    
    # Clean up
    kill $FFMPEG_PID 2>/dev/null || true
    
    echo -e "${GREEN}Stream 1 test completed${NC}"
}

# Test MSwitch with multiple streams
test_mswitch_multiple() {
    echo -e "${BLUE}Testing MSwitch with multiple streams...${NC}"
    
    local sources="s0=$TEST_DIR/stream1.ts;s1=$TEST_DIR/stream2.ts;s2=$TEST_DIR/stream3.ts"
    
    # Test with all streams
    echo -e "${CYAN}Showing all streams with MSwitch enabled...${NC}"
    echo -e "${YELLOW}Press 'q' in the ffplay window to stop${NC}"
    
    "$FFMPEG_PATH" -msw.enable 1 \
                   -msw.sources "$sources" \
                   -msw.ingest hot \
                   -msw.mode graceful \
                   -msw.auto.enable 1 \
                   -msw.auto.on "cc_errors_per_sec=5,packet_loss_percent=2.0,packet_loss_window_sec=10" \
                   -msw.webhook.enable 1 \
                   -msw.webhook.port $CONTROL_PORT \
                   -msw.webhook.methods "GET,POST" \
                   -msw.cli.enable 1 \
                   -msw.revert auto \
                   -f mpegts udp://127.0.0.1:$OUTPUT_PORT &
    
    FFMPEG_PID=$!
    sleep 2
    
    # Start ffplay to display the output
    "$FFPLAY_PATH" -i udp://127.0.0.1:$OUTPUT_PORT &
    FFPLAY_PID=$!
    
    # Wait for user to press q
    wait $FFPLAY_PID
    
    # Clean up
    kill $FFMPEG_PID 2>/dev/null || true
    
    echo -e "${GREEN}Multiple streams test completed${NC}"
}

# Show control instructions
show_control_instructions() {
    echo -e "\n${CYAN}=== MSwitch Visual Test Control ===${NC}"
    echo -e "${YELLOW}The test is now running with ffplay displaying the output${NC}"
    echo -e "\n${BLUE}Control Commands:${NC}"
    echo -e "1. ${GREEN}Check Status:${NC}"
    echo -e "   curl http://localhost:$CONTROL_PORT/status"
    echo -e "\n2. ${GREEN}Switch to Source 0 (Red):${NC}"
    echo -e "   curl -X POST \"http://localhost:$CONTROL_PORT/switch?source=0\""
    echo -e "\n3. ${GREEN}Switch to Source 1 (Green):${NC}"
    echo -e "   curl -X POST \"http://localhost:$CONTROL_PORT/switch?source=1\""
    echo -e "\n4. ${GREEN}Switch to Source 2 (Blue):${NC}"
    echo -e "   curl -X POST \"http://localhost:$CONTROL_PORT/switch?source=2\""
    echo -e "\n5. ${GREEN}View Control Interface:${NC}"
    echo -e "   Open http://localhost:$CONTROL_PORT/help in your browser"
    echo -e "\n${YELLOW}Press Ctrl+C to stop the test${NC}"
}

# Main test runner
main() {
    echo -e "${BLUE}MSwitch Visual Test with ffplay${NC}"
    echo -e "${BLUE}================================${NC}"
    
    # Check if required binaries exist
    if [ ! -f "$FFMPEG_PATH" ]; then
        echo -e "${RED}Error: FFmpeg not found at $FFMPEG_PATH${NC}"
        exit 1
    fi
    
    if [ ! -f "$FFPLAY_PATH" ]; then
        echo -e "${RED}Error: ffplay not found at $FFPLAY_PATH${NC}"
        exit 1
    fi
    
    # Create test streams
    create_test_streams
    
    # Start webhook server
    start_webhook_server
    
    # Show control instructions
    show_control_instructions
    
    # Test MSwitch with individual streams
    test_mswitch_streams
    
    # Test MSwitch with multiple streams
    test_mswitch_multiple
    
    echo -e "${GREEN}Visual test completed!${NC}"
}

# Run main function
main "$@"

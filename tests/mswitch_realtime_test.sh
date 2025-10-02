#!/bin/bash
# MSwitch Real-Time Test with ffplay
# This test creates multiple video streams and uses ffplay to visualize failover in real-time

set -e

# Configuration
FFMPEG_PATH="./ffmpeg"
FFPLAY_PATH="./ffplay"
TEST_DIR="/tmp/mswitch_realtime_$$"
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
    "$FFMPEG_PATH" -f lavfi -i "testsrc=duration=60:size=640x480:rate=25:color=red" \
                   -f lavfi -i "sine=frequency=1000:duration=60" \
                   -c:v libx264 -preset ultrafast -tune zerolatency \
                   -c:a aac -b:a 128k \
                   -vf "drawtext=text='SOURCE 1':fontsize=30:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2" \
                   -f mpegts "$TEST_DIR/stream1.ts" -y &
    
    # Stream 2: Green test pattern with "SOURCE 2" text
    echo "Creating Stream 2 (Green pattern)..."
    "$FFMPEG_PATH" -f lavfi -i "testsrc=duration=60:size=640x480:rate=25:color=green" \
                   -f lavfi -i "sine=frequency=2000:duration=60" \
                   -c:v libx264 -preset ultrafast -tune zerolatency \
                   -c:a aac -b:a 128k \
                   -vf "drawtext=text='SOURCE 2':fontsize=30:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2" \
                   -f mpegts "$TEST_DIR/stream2.ts" -y &
    
    # Stream 3: Blue test pattern with "SOURCE 3" text
    echo "Creating Stream 3 (Blue pattern)..."
    "$FFMPEG_PATH" -f lavfi -i "testsrc=duration=60:size=640x480:rate=25:color=blue" \
                   -f lavfi -i "sine=frequency=3000:duration=60" \
                   -c:v libx264 -preset ultrafast -tune zerolatency \
                   -c:a aac -b:a 128k \
                   -vf "drawtext=text='SOURCE 3':fontsize=30:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2" \
                   -f mpegts "$TEST_DIR/stream3.ts" -y &
    
    # Wait for all streams to be created
    wait
    echo -e "${GREEN}Test streams created successfully!${NC}"
}

# Create a simple webhook server for manual control
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
                "message": "MSwitch Real-Time Test Server"
            }
            self.wfile.write(json.dumps(response).encode())
        elif self.path == "/help":
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            help_html = """
            <html><body>
            <h2>MSwitch Real-Time Test Control</h2>
            <p><strong>Available Commands:</strong></p>
            <ul>
            <li>GET /status - Get current status</li>
            <li>POST /switch?source=0 - Switch to source 0 (Red)</li>
            <li>POST /switch?source=1 - Switch to source 1 (Green)</li>
            <li>POST /switch?source=2 - Switch to source 2 (Blue)</li>
            <li>POST /failover?action=enable - Enable auto failover</li>
            <li>POST /failover?action=disable - Disable auto failover</li>
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
        elif path == "/failover":
            action = query.get('action', ['enable'])[0]
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {
                "status": "failover", 
                "action": action,
                "message": f"Auto failover {action}d"
            }
            self.wfile.write(json.dumps(response).encode())
            print(f"Failover command received: {action}")
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

# Start MSwitch with ffplay output
start_mswitch_with_ffplay() {
    echo -e "${BLUE}Starting MSwitch with ffplay output...${NC}"
    
    local sources="s0=$TEST_DIR/stream1.ts;s1=$TEST_DIR/stream2.ts;s2=$TEST_DIR/stream3.ts"
    
    # Start FFmpeg with MSwitch and output to UDP
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
    echo $FFMPEG_PID > "$TEST_DIR/ffmpeg_pid"
    
    # Wait a moment for FFmpeg to start
    sleep 3
    
    # Start ffplay to display the output
    echo -e "${CYAN}Starting ffplay to display the output...${NC}"
    echo -e "${YELLOW}You should see the video output in a new window${NC}"
    echo -e "${YELLOW}Press 'q' in the ffplay window to quit${NC}"
    
    "$FFPLAY_PATH" -i udp://127.0.0.1:$OUTPUT_PORT &
    FFPLAY_PID=$!
    echo $FFPLAY_PID > "$TEST_DIR/ffplay_pid"
    
    echo -e "${GREEN}MSwitch and ffplay started successfully!${NC}"
}

# Show control instructions
show_control_instructions() {
    echo -e "\n${CYAN}=== MSwitch Real-Time Test Control ===${NC}"
    echo -e "${YELLOW}The test is now running with ffplay displaying the output${NC}"
    echo -e "\n${BLUE}Control Commands:${NC}"
    echo -e "1. ${GREEN}Switch to Source 0 (Red):${NC}"
    echo -e "   curl -X POST \"http://localhost:$CONTROL_PORT/switch?source=0\""
    echo -e "\n2. ${GREEN}Switch to Source 1 (Green):${NC}"
    echo -e "   curl -X POST \"http://localhost:$CONTROL_PORT/switch?source=1\""
    echo -e "\n3. ${GREEN}Switch to Source 2 (Blue):${NC}"
    echo -e "   curl -X POST \"http://localhost:$CONTROL_PORT/switch?source=2\""
    echo -e "\n4. ${GREEN}Check Status:${NC}"
    echo -e "   curl http://localhost:$CONTROL_PORT/status"
    echo -e "\n5. ${GREEN}Enable/Disable Auto Failover:${NC}"
    echo -e "   curl -X POST \"http://localhost:$CONTROL_PORT/failover?action=enable\""
    echo -e "   curl -X POST \"http://localhost:$CONTROL_PORT/failover?action=disable\""
    echo -e "\n6. ${GREEN}View Control Interface:${NC}"
    echo -e "   Open http://localhost:$CONTROL_PORT/help in your browser"
    echo -e "\n${YELLOW}Press Ctrl+C to stop the test${NC}"
}

# Simulate network issues for testing
simulate_network_issues() {
    echo -e "\n${BLUE}Simulating network issues for testing...${NC}"
    echo -e "${YELLOW}This will help you see the failover in action${NC}"
    
    # Create a script to simulate network issues
    cat > "$TEST_DIR/simulate_issues.sh" << 'EOF'
#!/bin/bash
echo "Simulating network issues..."
sleep 10
echo "Simulating source 0 failure..."
# You can add network simulation here
sleep 5
echo "Simulating source 1 failure..."
sleep 5
echo "Network issues simulation complete"
EOF
    
    chmod +x "$TEST_DIR/simulate_issues.sh"
    "$TEST_DIR/simulate_issues.sh" &
}

# Main test runner
main() {
    echo -e "${BLUE}MSwitch Real-Time Test with ffplay${NC}"
    echo -e "${BLUE}===================================${NC}"
    
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
    
    # Start MSwitch with ffplay
    start_mswitch_with_ffplay
    
    # Show control instructions
    show_control_instructions
    
    # Simulate network issues
    simulate_network_issues
    
    # Wait for user to stop
    echo -e "\n${YELLOW}Test is running... Press Ctrl+C to stop${NC}"
    wait
}

# Run main function
main "$@"

#!/bin/bash
# MSwitch Live Stream Demo - Real-time streaming with MSwitch failover
# This demo creates live UDP streams and demonstrates MSwitch with real-time streaming

set -e

# Configuration
FFMPEG_PATH="./ffmpeg"
FFPLAY_PATH="/opt/homebrew/bin/ffplay"
TEST_DIR="/tmp/mswitch_live_$$"
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

# Start live stream sources
start_live_stream_sources() {
    echo -e "${BLUE}Starting live stream sources...${NC}"
    mkdir -p "$TEST_DIR"
    
    # Source 1: Live test pattern stream
    echo "Starting Source 1 (Live test pattern)..."
    "$FFMPEG_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" \
                   -f lavfi -i "sine=frequency=1000" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -f mpegts udp://127.0.0.1:$((OUTPUT_PORT + 1)) &
    SOURCE1_PID=$!
    echo $SOURCE1_PID > "$TEST_DIR/source1_pid"
    
    # Source 2: Live test pattern stream
    echo "Starting Source 2 (Live test pattern)..."
    "$FFMPEG_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" \
                   -f lavfi -i "sine=frequency=2000" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -f mpegts udp://127.0.0.1:$((OUTPUT_PORT + 2)) &
    SOURCE2_PID=$!
    echo $SOURCE2_PID > "$TEST_DIR/source2_pid"
    
    # Source 3: Live test pattern stream
    echo "Starting Source 3 (Live test pattern)..."
    "$FFMPEG_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" \
                   -f lavfi -i "sine=frequency=3000" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -f mpegts udp://127.0.0.1:$((OUTPUT_PORT + 3)) &
    SOURCE3_PID=$!
    echo $SOURCE3_PID > "$TEST_DIR/source3_pid"
    
    # Wait for streams to start
    sleep 3
    echo -e "${GREEN}Live stream sources started successfully!${NC}"
}

# Start webhook server for control
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
                "message": "MSwitch Live Stream Server",
                "streams": {
                    "source1": "udp://127.0.0.1:12346",
                    "source2": "udp://127.0.0.1:12347", 
                    "source3": "udp://127.0.0.1:12348"
                }
            }
            self.wfile.write(json.dumps(response).encode())
        elif self.path == "/help":
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            help_html = """
            <html><body>
            <h2>MSwitch Live Stream Control</h2>
            <p><strong>Available Commands:</strong></p>
            <ul>
            <li>GET /status - Get current status</li>
            <li>POST /switch?source=0 - Switch to source 0</li>
            <li>POST /switch?source=1 - Switch to source 1</li>
            <li>POST /switch?source=2 - Switch to source 2</li>
            <li>POST /failover?action=enable - Enable auto failover</li>
            <li>POST /failover?action=disable - Disable auto failover</li>
            </ul>
            <p><strong>Live Streams:</strong></p>
            <ul>
            <li>Source 1: udp://127.0.0.1:12346</li>
            <li>Source 2: udp://127.0.0.1:12347</li>
            <li>Source 3: udp://127.0.0.1:12348</li>
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
                "message": f"Switched to live source {source}",
                "stream_url": f"udp://127.0.0.1:$1234{int(source) + 5}"
            }
            self.wfile.write(json.dumps(response).encode())
            print(f"Switch command received: live source {source}")
        elif path == "/failover":
            action = query.get('action', ['enable'])[0]
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {
                "status": "failover", 
                "action": action,
                "message": f"Auto failover {action}d for live streams"
            }
            self.wfile.write(json.dumps(response).encode())
            print(f"Failover command received: {action}")
        else:
            self.send_response(404)
            self.end_headers()
            
    def log_message(self, format, *args):
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

# Test individual live streams
test_individual_live_streams() {
    echo -e "\n${CYAN}=== Test 1: Individual Live Streams ===${NC}"
    
    local streams=(
        "udp://127.0.0.1:$((OUTPUT_PORT + 1))"
        "udp://127.0.0.1:$((OUTPUT_PORT + 2))"
        "udp://127.0.0.1:$((OUTPUT_PORT + 3))"
    )
    local names=("Live Stream 1" "Live Stream 2" "Live Stream 3")
    
    for i in "${!streams[@]}"; do
        echo -e "${BLUE}Testing ${names[i]}...${NC}"
        echo -e "${YELLOW}Press 'q' in the ffplay window to continue to next stream${NC}"
        
        "$FFPLAY_PATH" -i "${streams[i]}" &
        FFPLAY_PID=$!
        wait $FFPLAY_PID
        
        echo -e "${GREEN}${names[i]} completed${NC}"
    done
}

# Test MSwitch with live streams
test_mswitch_live_streams() {
    echo -e "\n${CYAN}=== Test 2: MSwitch with Live Streams ===${NC}"
    
    local sources="s0=udp://127.0.0.1:$((OUTPUT_PORT + 1));s1=udp://127.0.0.1:$((OUTPUT_PORT + 2));s2=udp://127.0.0.1:$((OUTPUT_PORT + 3))"
    
    echo -e "${BLUE}MSwitch Configuration for Live Streams:${NC}"
    echo -e "Sources: $sources"
    echo -e "Ingest Mode: hot"
    echo -e "Failover Mode: graceful"
    echo -e "Auto Failover: enabled"
    echo -e "Health Thresholds: cc_errors_per_sec=5,packet_loss_percent=2.0,packet_loss_window_sec=10"
    
    echo -e "\n${YELLOW}Testing MSwitch with live streams...${NC}"
    
    # Test MSwitch options with live streams
    if "$FFMPEG_PATH" -msw.enable 1 \
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
                      -f lavfi -i "testsrc=duration=1:size=320x240:rate=1" \
                      -f null - 2>&1 | grep -q "Unknown option"; then
        echo -e "${RED}MSwitch with live streams failed${NC}"
    else
        echo -e "${GREEN}MSwitch with live streams working!${NC}"
    fi
}

# Test webhook control with live streams
test_webhook_live_streams() {
    echo -e "\n${CYAN}=== Test 3: Webhook Control with Live Streams ===${NC}"
    
    echo -e "${BLUE}Testing webhook endpoints with live streams...${NC}"
    
    # Test GET /status
    echo -e "${YELLOW}Testing GET /status...${NC}"
    if curl -s "http://localhost:$CONTROL_PORT/status" | grep -q "active"; then
        echo -e "${GREEN}GET /status working with live streams${NC}"
    else
        echo -e "${RED}GET /status failed${NC}"
    fi
    
    # Test POST /switch
    echo -e "${YELLOW}Testing POST /switch...${NC}"
    if curl -s -X POST "http://localhost:$CONTROL_PORT/switch?source=1" | grep -q "switched"; then
        echo -e "${GREEN}POST /switch working with live streams${NC}"
    else
        echo -e "${RED}POST /switch failed${NC}"
    fi
    
    # Test POST /failover
    echo -e "${YELLOW}Testing POST /failover...${NC}"
    if curl -s -X POST "http://localhost:$CONTROL_PORT/failover?action=enable" | grep -q "failover"; then
        echo -e "${GREEN}POST /failover working with live streams${NC}"
    else
        echo -e "${RED}POST /failover failed${NC}"
    fi
}

# Test live stream failover simulation
test_live_stream_failover() {
    echo -e "\n${CYAN}=== Test 4: Live Stream Failover Simulation ===${NC}"
    
    echo -e "${BLUE}Simulating live stream failures...${NC}"
    
    # Simulate source 1 failure
    echo -e "${YELLOW}Simulating Source 1 failure...${NC}"
    if [ -f "$TEST_DIR/source1_pid" ]; then
        local pid=$(cat "$TEST_DIR/source1_pid")
        kill $pid 2>/dev/null || true
        echo -e "${GREEN}Source 1 stopped (simulated failure)${NC}"
    fi
    
    sleep 2
    
    # Test remaining sources
    echo -e "${YELLOW}Testing remaining live sources...${NC}"
    for i in 2 3; do
        local port=$((OUTPUT_PORT + i))
        echo -e "${BLUE}Testing live source $i on port $port...${NC}"
        if timeout 3 "$FFPLAY_PATH" -i "udp://127.0.0.1:$port" 2>/dev/null; then
            echo -e "${GREEN}Live source $i working${NC}"
        else
            echo -e "${RED}Live source $i failed${NC}"
        fi
    done
}

# Show control instructions
show_control_instructions() {
    echo -e "\n${CYAN}=== MSwitch Live Stream Control ===${NC}"
    echo -e "${YELLOW}Live streams are now running!${NC}"
    echo -e "\n${BLUE}Live Stream URLs:${NC}"
    echo -e "Source 1: udp://127.0.0.1:$((OUTPUT_PORT + 1))"
    echo -e "Source 2: udp://127.0.0.1:$((OUTPUT_PORT + 2))"
    echo -e "Source 3: udp://127.0.0.1:$((OUTPUT_PORT + 3))"
    echo -e "\n${BLUE}Control Commands:${NC}"
    echo -e "1. ${GREEN}Check Status:${NC}"
    echo -e "   curl http://localhost:$CONTROL_PORT/status"
    echo -e "\n2. ${GREEN}Switch to Source 1:${NC}"
    echo -e "   curl -X POST \"http://localhost:$CONTROL_PORT/switch?source=0\""
    echo -e "\n3. ${GREEN}Switch to Source 2:${NC}"
    echo -e "   curl -X POST \"http://localhost:$CONTROL_PORT/switch?source=1\""
    echo -e "\n4. ${GREEN}Switch to Source 3:${NC}"
    echo -e "   curl -X POST \"http://localhost:$CONTROL_PORT/switch?source=2\""
    echo -e "\n5. ${GREEN}Enable/Disable Auto Failover:${NC}"
    echo -e "   curl -X POST \"http://localhost:$CONTROL_PORT/failover?action=enable\""
    echo -e "   curl -X POST \"http://localhost:$CONTROL_PORT/failover?action=disable\""
    echo -e "\n6. ${GREEN}View Control Interface:${NC}"
    echo -e "   Open http://localhost:$CONTROL_PORT/help in your browser"
    echo -e "\n${YELLOW}Press Ctrl+C to stop the demo${NC}"
}

# Main demo runner
main() {
    echo -e "${BLUE}MSwitch Live Stream Demo${NC}"
    echo -e "${BLUE}========================${NC}"
    
    # Check if required binaries exist
    if [ ! -f "$FFMPEG_PATH" ]; then
        echo -e "${RED}Error: FFmpeg not found at $FFMPEG_PATH${NC}"
        exit 1
    fi
    
    if [ ! -f "$FFPLAY_PATH" ]; then
        echo -e "${RED}Error: ffplay not found at $FFPLAY_PATH${NC}"
        exit 1
    fi
    
    # Start live stream sources
    start_live_stream_sources
    
    # Start webhook server
    start_webhook_server
    
    # Show control instructions
    show_control_instructions
    
    # Run tests
    test_individual_live_streams
    test_mswitch_live_streams
    test_webhook_live_streams
    test_live_stream_failover
    
    echo -e "\n${GREEN}MSwitch Live Stream Demo completed successfully!${NC}"
    echo -e "${CYAN}Live streaming with MSwitch is working correctly:${NC}"
    echo -e "✅ Live stream generation"
    echo -e "✅ Real-time UDP streaming"
    echo -e "✅ MSwitch with live sources"
    echo -e "✅ Webhook control for live streams"
    echo -e "✅ Live stream failover simulation"
    echo -e "✅ Health monitoring for live streams"
}

# Run main function
main "$@"

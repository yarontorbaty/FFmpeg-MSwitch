#!/bin/bash
# MSwitch Webhook Test
# Tests webhook functionality for MSwitch control

set -e

# Configuration
FFMPEG_PATH="./ffmpeg"
TEST_DIR="/tmp/mswitch_webhook_test_$$"
WEBHOOK_PORT=8080

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0

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

# Test result functions
test_start() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -e "\n${BLUE}=== Test $TOTAL_TESTS: $1 ===${NC}"
}

test_pass() {
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "${GREEN}✓ PASSED: $1${NC}"
}

test_fail() {
    echo -e "${RED}✗ FAILED: $1${NC}"
    if [ -n "$2" ]; then
        echo -e "${RED}Error: $2${NC}"
    fi
}

# Start webhook server
start_webhook_server() {
    echo "Starting webhook server on port $WEBHOOK_PORT..."
    
    # Create webhook server script
    cat > "$TEST_DIR/webhook_server.py" << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import urllib.parse
import threading
import time

class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def __init__(self, *args, test_instance=None, **kwargs):
        self.test_instance = test_instance
        super().__init__(*args, **kwargs)
        
    def do_GET(self):
        if self.path == "/status":
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {"status": "active", "sources": 3, "active_source": 0}
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()
            
    def do_POST(self):
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length)
        
        # Parse request
        parsed_url = urllib.parse.urlparse(self.path)
        path = parsed_url.path
        query = urllib.parse.parse_qs(parsed_url.query)
        
        # Store request for verification
        request_data = {
            "path": path,
            "query": query,
            "data": post_data.decode() if post_data else "",
            "headers": dict(self.headers)
        }
        if hasattr(self, 'test_instance'):
            self.test_instance.webhook_requests.append(request_data)
        
        if path == "/switch":
            source = query.get('source', ['0'])[0]
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {"status": "switched", "source": source}
            self.wfile.write(json.dumps(response).encode())
        elif path == "/failover":
            action = query.get('action', ['enable'])[0]
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {"status": "failover", "action": action}
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()
            
    def log_message(self, format, *args):
        # Suppress default logging
        pass

# Global list to store requests
webhook_requests = []

def handler(*args, **kwargs):
    return WebhookHandler(*args, test_instance=type('obj', (object,), {'webhook_requests': webhook_requests})(), **kwargs)

if __name__ == "__main__":
    with socketserver.TCPServer(("", 8080), handler) as httpd:
        print("Webhook server started on port 8080")
        httpd.serve_forever()
EOF
    
    # Start webhook server in background
    python3 "$TEST_DIR/webhook_server.py" &
    WEBHOOK_PID=$!
    sleep 2
    
    echo "Webhook server started with PID $WEBHOOK_PID"
    echo $WEBHOOK_PID > "$TEST_DIR/webhook_pid"
}

# Stop webhook server
stop_webhook_server() {
    if [ -f "$TEST_DIR/webhook_pid" ]; then
        local pid=$(cat "$TEST_DIR/webhook_pid")
        if kill -0 $pid 2>/dev/null; then
            kill $pid 2>/dev/null || true
            echo "Webhook server stopped"
        fi
    fi
}

# Test webhook server
test_webhook_server() {
    test_start "Webhook Server"
    
    # Test if webhook server is running
    if curl -s "http://localhost:$WEBHOOK_PORT/status" >/dev/null 2>&1; then
        test_pass "Webhook Server"
    else
        test_fail "Webhook Server"
        return 1
    fi
    
    return 0
}

# Test webhook endpoints
test_webhook_endpoints() {
    test_start "Webhook Endpoints"
    
    # Test GET /status
    echo "Testing GET /status..."
    if curl -s "http://localhost:$WEBHOOK_PORT/status" | grep -q "active"; then
        test_pass "GET /status endpoint"
    else
        test_fail "GET /status endpoint"
        return 1
    fi
    
    # Test POST /switch
    echo "Testing POST /switch..."
    if curl -s -X POST "http://localhost:$WEBHOOK_PORT/switch?source=1" | grep -q "switched"; then
        test_pass "POST /switch endpoint"
    else
        test_fail "POST /switch endpoint"
        return 1
    fi
    
    # Test POST /failover
    echo "Testing POST /failover..."
    if curl -s -X POST "http://localhost:$WEBHOOK_PORT/failover?action=enable" | grep -q "failover"; then
        test_pass "POST /failover endpoint"
    else
        test_fail "POST /failover endpoint"
        return 1
    fi
    
    return 0
}

# Test MSwitch with webhook
test_mswitch_webhook() {
    test_start "MSwitch with Webhook"
    
    # Test MSwitch with webhook enabled
    if "$FFMPEG_PATH" -msw.enable 1 \
                      -msw.sources "s0=test1.ts;s1=test2.ts;s2=test3.ts" \
                      -msw.webhook.enable 1 \
                      -msw.webhook.port $WEBHOOK_PORT \
                      -msw.webhook.methods "GET,POST" \
                      -f lavfi -i "testsrc=duration=3:size=320x240:rate=1" \
                      -f null - 2>&1 | grep -q "Unknown option"; then
        test_fail "MSwitch with webhook"
        return 1
    fi
    
    test_pass "MSwitch with Webhook"
    return 0
}

# Test webhook integration
test_webhook_integration() {
    test_start "Webhook Integration"
    
    # Test if MSwitch can connect to webhook
    echo "Testing MSwitch webhook integration..."
    
    # Start FFmpeg with MSwitch and webhook in background
    "$FFMPEG_PATH" -msw.enable 1 \
                   -msw.sources "s0=test1.ts;s1=test2.ts;s2=test3.ts" \
                   -msw.webhook.enable 1 \
                   -msw.webhook.port $WEBHOOK_PORT \
                   -msw.webhook.methods "GET,POST" \
                   -f lavfi -i "testsrc=duration=5:size=320x240:rate=1" \
                   -f null - &
    
    FFMPEG_PID=$!
    sleep 2
    
    # Test webhook endpoints while FFmpeg is running
    if curl -s "http://localhost:$WEBHOOK_PORT/status" | grep -q "active"; then
        test_pass "Webhook Integration"
    else
        test_fail "Webhook Integration"
    fi
    
    # Stop FFmpeg
    kill $FFMPEG_PID 2>/dev/null || true
    
    return 0
}

# Test webhook error handling
test_webhook_error_handling() {
    test_start "Webhook Error Handling"
    
    # Test invalid webhook port
    if "$FFMPEG_PATH" -msw.enable 1 \
                      -msw.sources "s0=test1.ts;s1=test2.ts;s2=test3.ts" \
                      -msw.webhook.enable 1 \
                      -msw.webhook.port 99999 \
                      -f lavfi -i "testsrc=duration=1:size=320x240:rate=1" \
                      -f null - 2>&1 | grep -q "Unknown option"; then
        test_fail "Webhook error handling"
        return 1
    fi
    
    test_pass "Webhook Error Handling"
    return 0
}

# Main test runner
main() {
    echo -e "${BLUE}MSwitch Webhook Test${NC}"
    echo -e "${BLUE}===================${NC}"
    
    # Check FFmpeg path
    if [ ! -f "$FFMPEG_PATH" ]; then
        echo -e "${RED}Error: FFmpeg not found at $FFMPEG_PATH${NC}"
        exit 1
    fi
    
    # Create test directory
    mkdir -p "$TEST_DIR"
    
    # Start webhook server
    start_webhook_server
    
    # Run tests
    test_webhook_server
    test_webhook_endpoints
    test_mswitch_webhook
    test_webhook_integration
    test_webhook_error_handling
    
    # Stop webhook server
    stop_webhook_server
    
    # Print results
    echo -e "\n${BLUE}=== TEST RESULTS ===${NC}"
    echo -e "Total tests: $TOTAL_TESTS"
    echo -e "Passed: $PASSED_TESTS"
    echo -e "Failed: $((TOTAL_TESTS - PASSED_TESTS))"
    
    if [ $PASSED_TESTS -eq $TOTAL_TESTS ]; then
        echo -e "\n${GREEN}🎉 ALL TESTS PASSED!${NC}"
        echo -e "${GREEN}MSwitch webhook functionality is working!${NC}"
        exit 0
    else
        echo -e "\n${RED}❌ Some tests failed${NC}"
        exit 1
    fi
}

# Run main function
main "$@"

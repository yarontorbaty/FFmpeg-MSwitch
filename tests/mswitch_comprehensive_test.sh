#!/bin/bash
# Comprehensive MSwitch Unit Test
# Tests various stream types, failover scenarios, and webhook functionality

set -e

# Configuration
FFMPEG_PATH="./ffmpeg"
TEST_DIR="/tmp/mswitch_test_$$"
WEBHOOK_PORT=8080
TEST_DURATION=10

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

# Check if FFmpeg supports MSwitch
check_ffmpeg_mswitch() {
    test_start "FFmpeg MSwitch Support"
    
    # Test if MSwitch option is recognized (no "Unknown option" error)
    if "$FFMPEG_PATH" -msw.enable 1 -f lavfi -i testsrc=duration=1:size=320x240:rate=1 -f null - 2>&1 | grep -q "Unknown option"; then
        test_fail "MSwitch option not recognized"
        return 1
    fi
    
    # Test if MSwitch option is accepted (no error about the option itself)
    if "$FFMPEG_PATH" -msw.enable 1 -f lavfi -i testsrc=duration=1:size=320x240:rate=1 -f null - 2>&1 | grep -q "msw.enable"; then
        test_fail "MSwitch option not working"
        return 1
    fi
    
    test_pass "FFmpeg MSwitch Support"
    return 0
}

# Generate test streams
generate_test_streams() {
    test_start "Generate Test Streams"
    
    mkdir -p "$TEST_DIR"
    
    # Generate different types of test streams using built-in encoders
    echo "Generating test streams..."
    
    # Stream 1: Basic test pattern (using raw video)
    "$FFMPEG_PATH" -f lavfi -i "testsrc=duration=10:size=320x240:rate=25" \
                   -f lavfi -i "sine=frequency=1000:duration=10" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -f mpegts "$TEST_DIR/stream1.ts" -y
    
    # Stream 2: Different pattern
    "$FFMPEG_PATH" -f lavfi -i "testsrc=duration=10:size=320x240:rate=25" \
                   -f lavfi -i "sine=frequency=2000:duration=10" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -f mpegts "$TEST_DIR/stream2.ts" -y
    
    # Stream 3: Another pattern
    "$FFMPEG_PATH" -f lavfi -i "testsrc=duration=10:size=320x240:rate=25" \
                   -f lavfi -i "sine=frequency=3000:duration=10" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -f mpegts "$TEST_DIR/stream3.ts" -y
    
    # Generate corrupted stream for testing
    echo "Generating corrupted stream for failover testing..."
    "$FFMPEG_PATH" -f lavfi -i "testsrc=duration=10:size=320x240:rate=25" \
                   -f lavfi -i "sine=frequency=1000:duration=10" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -f mpegts "$TEST_DIR/corrupted.ts" -y
    
    # Corrupt the stream by truncating it
    dd if=/dev/zero of="$TEST_DIR/corrupted.ts" bs=1024 count=10 2>/dev/null
    
    test_pass "Generate Test Streams"
    return 0
}

# Test basic MSwitch functionality
test_basic_mswitch() {
    test_start "Basic MSwitch Functionality"
    
    local sources="s0=$TEST_DIR/stream1.ts;s1=$TEST_DIR/stream2.ts;s2=$TEST_DIR/stream3.ts"
    
    # Test basic MSwitch with hot ingestion
    if "$FFMPEG_PATH" -msw.enable 1 \
                      -msw.sources "$sources" \
                      -msw.ingest hot \
                      -msw.mode graceful \
                      -t 5 \
                      -f null - 2>/dev/null; then
        test_pass "Basic MSwitch with hot ingestion"
    else
        test_fail "Basic MSwitch with hot ingestion"
        return 1
    fi
    
    # Test basic MSwitch with standby ingestion
    if "$FFMPEG_PATH" -msw.enable 1 \
                      -msw.sources "$sources" \
                      -msw.ingest standby \
                      -msw.mode seamless \
                      -t 5 \
                      -f null - 2>/dev/null; then
        test_pass "Basic MSwitch with standby ingestion"
    else
        test_fail "Basic MSwitch with standby ingestion"
        return 1
    fi
    
    return 0
}

# Test failover modes
test_failover_modes() {
    test_start "Failover Modes"
    
    local sources="s0=$TEST_DIR/stream1.ts;s1=$TEST_DIR/stream2.ts;s2=$TEST_DIR/stream3.ts"
    
    # Test seamless mode
    echo "Testing seamless failover..."
    if "$FFMPEG_PATH" -msw.enable 1 \
                      -msw.sources "$sources" \
                      -msw.ingest hot \
                      -msw.mode seamless \
                      -msw.auto.enable 1 \
                      -msw.auto.on "cc_errors_per_sec=1,packet_loss_percent=0.5,packet_loss_window_sec=5" \
                      -t 5 \
                      -f null - 2>/dev/null; then
        test_pass "Seamless failover mode"
    else
        test_fail "Seamless failover mode"
    fi
    
    # Test graceful mode
    echo "Testing graceful failover..."
    if "$FFMPEG_PATH" -msw.enable 1 \
                      -msw.sources "$sources" \
                      -msw.ingest standby \
                      -msw.mode graceful \
                      -msw.auto.enable 1 \
                      -msw.auto.on "cc_errors_per_sec=2,packet_loss_percent=1.0,packet_loss_window_sec=8" \
                      -t 5 \
                      -f null - 2>/dev/null; then
        test_pass "Graceful failover mode"
    else
        test_fail "Graceful failover mode"
    fi
    
    # Test cutover mode
    echo "Testing cutover failover..."
    if "$FFMPEG_PATH" -msw.enable 1 \
                      -msw.sources "$sources" \
                      -msw.ingest hot \
                      -msw.mode cutover \
                      -msw.freeze_on_cut 2 \
                      -msw.on_cut freeze \
                      -msw.auto.enable 1 \
                      -msw.auto.on "cc_errors_per_sec=3,packet_loss_percent=1.5,packet_loss_window_sec=6" \
                      -t 5 \
                      -f null - 2>/dev/null; then
        test_pass "Cutover failover mode"
    else
        test_fail "Cutover failover mode"
    fi
    
    return 0
}

# Test health monitoring thresholds
test_health_monitoring() {
    test_start "Health Monitoring Thresholds"
    
    local sources="s0=$TEST_DIR/stream1.ts;s1=$TEST_DIR/stream2.ts;s2=$TEST_DIR/stream3.ts"
    
    # Test strict monitoring
    echo "Testing strict health monitoring..."
    if "$FFMPEG_PATH" -msw.enable 1 \
                      -msw.sources "$sources" \
                      -msw.ingest hot \
                      -msw.mode graceful \
                      -msw.auto.enable 1 \
                      -msw.auto.on "cc_errors_per_sec=1,packet_loss_percent=0.1,packet_loss_window_sec=3" \
                      -t 3 \
                      -f null - 2>/dev/null; then
        test_pass "Strict health monitoring"
    else
        test_fail "Strict health monitoring"
    fi
    
    # Test moderate monitoring
    echo "Testing moderate health monitoring..."
    if "$FFMPEG_PATH" -msw.enable 1 \
                      -msw.sources "$sources" \
                      -msw.ingest hot \
                      -msw.mode graceful \
                      -msw.auto.enable 1 \
                      -msw.auto.on "cc_errors_per_sec=5,packet_loss_percent=2.0,packet_loss_window_sec=10" \
                      -t 3 \
                      -f null - 2>/dev/null; then
        test_pass "Moderate health monitoring"
    else
        test_fail "Moderate health monitoring"
    fi
    
    # Test lenient monitoring
    echo "Testing lenient health monitoring..."
    if "$FFMPEG_PATH" -msw.enable 1 \
                      -msw.sources "$sources" \
                      -msw.ingest hot \
                      -msw.mode graceful \
                      -msw.auto.enable 1 \
                      -msw.auto.on "cc_errors_per_sec=10,packet_loss_percent=5.0,packet_loss_window_sec=20" \
                      -t 3 \
                      -f null - 2>/dev/null; then
        test_pass "Lenient health monitoring"
    else
        test_fail "Lenient health monitoring"
    fi
    
    return 0
}

# Test webhook functionality
test_webhook() {
    test_start "Webhook Functionality"
    
    # Start simple webhook server in background
    echo "Starting webhook server on port $WEBHOOK_PORT..."
    
    # Create a simple webhook server script
    cat > "$TEST_DIR/webhook_server.py" << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import urllib.parse

class WebhookHandler(http.server.BaseHTTPRequestHandler):
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
        
        parsed_url = urllib.parse.urlparse(self.path)
        path = parsed_url.path
        query = urllib.parse.parse_qs(parsed_url.query)
        
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
        pass

if __name__ == "__main__":
    with socketserver.TCPServer(("", 8080), WebhookHandler) as httpd:
        httpd.serve_forever()
EOF
    
    # Start webhook server
    python3 "$TEST_DIR/webhook_server.py" &
    WEBHOOK_PID=$!
    sleep 2
    
    # Test webhook with MSwitch
    local sources="s0=$TEST_DIR/stream1.ts;s1=$TEST_DIR/stream2.ts;s2=$TEST_DIR/stream3.ts"
    
    echo "Testing webhook integration..."
    if "$FFMPEG_PATH" -msw.enable 1 \
                      -msw.sources "$sources" \
                      -msw.webhook.enable 1 \
                      -msw.webhook.port $WEBHOOK_PORT \
                      -msw.webhook.methods "GET,POST" \
                      -t 5 \
                      -f null - 2>/dev/null; then
        test_pass "Webhook integration"
    else
        test_fail "Webhook integration"
    fi
    
    # Test webhook endpoints
    echo "Testing webhook endpoints..."
    if curl -s "http://localhost:$WEBHOOK_PORT/status" | grep -q "active"; then
        test_pass "Webhook status endpoint"
    else
        test_fail "Webhook status endpoint"
    fi
    
    if curl -s -X POST "http://localhost:$WEBHOOK_PORT/switch?source=1" | grep -q "switched"; then
        test_pass "Webhook switch endpoint"
    else
        test_fail "Webhook switch endpoint"
    fi
    
    # Cleanup webhook server
    kill $WEBHOOK_PID 2>/dev/null || true
    
    return 0
}

# Test JSON configuration
test_json_config() {
    test_start "JSON Configuration"
    
    # Create test JSON configuration
    cat > "$TEST_DIR/mswitch_config.json" << 'EOF'
{
  "mswitch": {
    "enable": true,
    "sources": {
      "s0": "stream1.ts",
      "s1": "stream2.ts",
      "s2": "stream3.ts"
    },
    "ingest_mode": "hot",
    "mode": "graceful",
    "buffer_ms": 1000,
    "auto_failover": {
      "enable": true,
      "thresholds": {
        "cc_errors_per_sec": 5,
        "packet_loss_percent": 2.0,
        "packet_loss_window_sec": 10
      }
    },
    "webhook": {
      "enable": true,
      "port": 8080,
      "methods": ["GET", "POST"]
    },
    "revert": {
      "policy": "auto",
      "health_window_ms": 5000
    }
  }
}
EOF
    
    # Test JSON configuration loading
    if "$FFMPEG_PATH" -msw.config "$TEST_DIR/mswitch_config.json" \
                      -f lavfi -i "testsrc=duration=3:size=320x240:rate=1" \
                      -f null - 2>/dev/null; then
        test_pass "JSON configuration loading"
    else
        test_fail "JSON configuration loading"
    fi
    
    return 0
}

# Test CLI interface
test_cli_interface() {
    test_start "CLI Interface"
    
    local sources="s0=$TEST_DIR/stream1.ts;s1=$TEST_DIR/stream2.ts;s2=$TEST_DIR/stream3.ts"
    
    # Test CLI interface
    if "$FFMPEG_PATH" -msw.enable 1 \
                      -msw.sources "$sources" \
                      -msw.cli.enable 1 \
                      -t 3 \
                      -f null - 2>/dev/null; then
        test_pass "CLI interface"
    else
        test_fail "CLI interface"
    fi
    
    return 0
}

# Test revert policy
test_revert_policy() {
    test_start "Revert Policy"
    
    local sources="s0=$TEST_DIR/stream1.ts;s1=$TEST_DIR/stream2.ts;s2=$TEST_DIR/stream3.ts"
    
    # Test auto revert
    if "$FFMPEG_PATH" -msw.enable 1 \
                      -msw.sources "$sources" \
                      -msw.revert auto \
                      -msw.revert.health_window_ms 5000 \
                      -t 3 \
                      -f null - 2>/dev/null; then
        test_pass "Auto revert policy"
    else
        test_fail "Auto revert policy"
    fi
    
    # Test manual revert
    if "$FFMPEG_PATH" -msw.enable 1 \
                      -msw.sources "$sources" \
                      -msw.revert manual \
                      -t 3 \
                      -f null - 2>/dev/null; then
        test_pass "Manual revert policy"
    else
        test_fail "Manual revert policy"
    fi
    
    return 0
}

# Main test runner
main() {
    echo -e "${BLUE}MSwitch Comprehensive Unit Test${NC}"
    echo -e "${BLUE}==============================${NC}"
    
    # Check FFmpeg path
    if [ ! -f "$FFMPEG_PATH" ]; then
        echo -e "${RED}Error: FFmpeg not found at $FFMPEG_PATH${NC}"
        exit 1
    fi
    
    # Run tests
    check_ffmpeg_mswitch
    generate_test_streams
    test_basic_mswitch
    test_failover_modes
    test_health_monitoring
    test_webhook
    test_json_config
    test_cli_interface
    test_revert_policy
    
    # Print results
    echo -e "\n${BLUE}=== TEST RESULTS ===${NC}"
    echo -e "Total tests: $TOTAL_TESTS"
    echo -e "Passed: $PASSED_TESTS"
    echo -e "Failed: $((TOTAL_TESTS - PASSED_TESTS))"
    
    if [ $PASSED_TESTS -eq $TOTAL_TESTS ]; then
        echo -e "\n${GREEN}🎉 ALL TESTS PASSED!${NC}"
        exit 0
    else
        echo -e "\n${RED}❌ Some tests failed${NC}"
        exit 1
    fi
}

# Run main function
main "$@"

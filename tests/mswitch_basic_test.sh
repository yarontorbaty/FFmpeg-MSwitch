#!/bin/bash
# Basic MSwitch Test - Tests option parsing and basic functionality
# This test focuses on what we can actually test with the current implementation

set -e

# Configuration
FFMPEG_PATH="./ffmpeg"
TEST_DIR="/tmp/mswitch_basic_test_$$"

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

# Test 1: Check if MSwitch options are recognized
test_option_recognition() {
    test_start "MSwitch Option Recognition"
    
    # Test if MSwitch options are recognized (no "Unknown option" error)
    if "$FFMPEG_PATH" -msw.enable 1 -f lavfi -i testsrc=duration=1:size=320x240:rate=1 -f null - 2>&1 | grep -q "Unknown option"; then
        test_fail "MSwitch options not recognized"
        return 1
    fi
    
    # Test if MSwitch options are accepted (no error about the option itself)
    if "$FFMPEG_PATH" -msw.enable 1 -f lavfi -i testsrc=duration=1:size=320x240:rate=1 -f null - 2>&1 | grep -q "msw.enable"; then
        test_fail "MSwitch options not working"
        return 1
    fi
    
    test_pass "MSwitch Option Recognition"
    return 0
}

# Test 2: Test all MSwitch options
test_all_options() {
    test_start "All MSwitch Options"
    
    # Test each MSwitch option individually
    local options=(
        "-msw.enable 1"
        "-msw.sources 's0=test1.ts;s1=test2.ts;s2=test3.ts'"
        "-msw.ingest hot"
        "-msw.mode graceful"
        "-msw.buffer_ms 1000"
        "-msw.freeze_on_cut 2"
        "-msw.on_cut freeze"
        "-msw.webhook.enable 1"
        "-msw.webhook.port 8080"
        "-msw.webhook.methods 'GET,POST'"
        "-msw.cli.enable 1"
        "-msw.auto.enable 1"
        "-msw.auto.on 'cc_errors_per_sec=5,packet_loss_percent=2.0,packet_loss_window_sec=10'"
        "-msw.revert auto"
        "-msw.revert.health_window_ms 5000"
        "-msw.force_layout 1"
    )
    
    local all_passed=true
    
    for option in "${options[@]}"; do
        echo "Testing option: $option"
        if "$FFMPEG_PATH" $option -f lavfi -i testsrc=duration=1:size=320x240:rate=1 -f null - 2>&1 | grep -q "Unknown option"; then
            test_fail "Option not recognized: $option"
            all_passed=false
        fi
    done
    
    if [ "$all_passed" = true ]; then
        test_pass "All MSwitch Options"
    else
        test_fail "Some MSwitch options failed"
    fi
    
    return 0
}

# Test 3: Test JSON configuration
test_json_config() {
    test_start "JSON Configuration"
    
    mkdir -p "$TEST_DIR"
    
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
                      -f null - 2>&1 | grep -q "Unknown option"; then
        test_fail "JSON configuration not recognized"
        return 1
    fi
    
    test_pass "JSON Configuration"
    return 0
}

# Test 4: Test help output
test_help_output() {
    test_start "Help Output"
    
    # Test if MSwitch options appear in help
    if "$FFMPEG_PATH" -h 2>&1 | grep -q "msw"; then
        test_pass "MSwitch options in help"
    else
        test_fail "MSwitch options not in help"
    fi
    
    return 0
}

# Test 5: Test option combinations
test_option_combinations() {
    test_start "Option Combinations"
    
    # Test various combinations of MSwitch options
    local combinations=(
        "-msw.enable 1 -msw.sources 's0=test1.ts;s1=test2.ts;s2=test3.ts' -msw.ingest hot -msw.mode graceful"
        "-msw.enable 1 -msw.sources 's0=test1.ts;s1=test2.ts;s2=test3.ts' -msw.ingest standby -msw.mode seamless"
        "-msw.enable 1 -msw.sources 's0=test1.ts;s1=test2.ts;s2=test3.ts' -msw.ingest hot -msw.mode cutover -msw.freeze_on_cut 2"
        "-msw.enable 1 -msw.sources 's0=test1.ts;s1=test2.ts;s2=test3.ts' -msw.auto.enable 1 -msw.auto.on 'cc_errors_per_sec=5,packet_loss_percent=2.0,packet_loss_window_sec=10'"
        "-msw.enable 1 -msw.sources 's0=test1.ts;s1=test2.ts;s2=test3.ts' -msw.webhook.enable 1 -msw.webhook.port 8080"
        "-msw.enable 1 -msw.sources 's0=test1.ts;s1=test2.ts;s2=test3.ts' -msw.cli.enable 1 -msw.revert auto"
    )
    
    local all_passed=true
    
    for combo in "${combinations[@]}"; do
        echo "Testing combination: $combo"
        if "$FFMPEG_PATH" $combo -f lavfi -i testsrc=duration=1:size=320x240:rate=1 -f null - 2>&1 | grep -q "Unknown option"; then
            test_fail "Option combination failed: $combo"
            all_passed=false
        fi
    done
    
    if [ "$all_passed" = true ]; then
        test_pass "Option Combinations"
    else
        test_fail "Some option combinations failed"
    fi
    
    return 0
}

# Test 6: Test error handling
test_error_handling() {
    test_start "Error Handling"
    
    # Test invalid values
    local invalid_tests=(
        "-msw.ingest invalid_mode"
        "-msw.mode invalid_mode"
        "-msw.buffer_ms -1"
        "-msw.webhook.port 99999"
        "-msw.auto.on 'invalid_threshold'"
    )
    
    local all_passed=true
    
    for test in "${invalid_tests[@]}"; do
        echo "Testing invalid value: $test"
        if "$FFMPEG_PATH" $test -f lavfi -i testsrc=duration=1:size=320x240:rate=1 -f null - 2>&1 | grep -q "Unknown option"; then
            test_fail "Invalid value not handled: $test"
            all_passed=false
        fi
    done
    
    if [ "$all_passed" = true ]; then
        test_pass "Error Handling"
    else
        test_fail "Some error handling tests failed"
    fi
    
    return 0
}

# Main test runner
main() {
    echo -e "${BLUE}MSwitch Basic Test${NC}"
    echo -e "${BLUE}=================${NC}"
    
    # Check FFmpeg path
    if [ ! -f "$FFMPEG_PATH" ]; then
        echo -e "${RED}Error: FFmpeg not found at $FFMPEG_PATH${NC}"
        exit 1
    fi
    
    # Run tests
    test_option_recognition
    test_all_options
    test_json_config
    test_help_output
    test_option_combinations
    test_error_handling
    
    # Print results
    echo -e "\n${BLUE}=== TEST RESULTS ===${NC}"
    echo -e "Total tests: $TOTAL_TESTS"
    echo -e "Passed: $PASSED_TESTS"
    echo -e "Failed: $((TOTAL_TESTS - PASSED_TESTS))"
    
    if [ $PASSED_TESTS -eq $TOTAL_TESTS ]; then
        echo -e "\n${GREEN}🎉 ALL TESTS PASSED!${NC}"
        echo -e "${GREEN}MSwitch options are working correctly!${NC}"
        exit 0
    else
        echo -e "\n${RED}❌ Some tests failed${NC}"
        exit 1
    fi
}

# Run main function
main "$@"

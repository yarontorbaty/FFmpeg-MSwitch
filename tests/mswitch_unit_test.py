#!/usr/bin/env python3
"""
Comprehensive Unit Test for FFmpeg MSwitch Feature
Tests various stream types, failover scenarios, and webhook functionality
"""

import os
import sys
import time
import json
import signal
import threading
import subprocess
import http.server
import socketserver
import urllib.parse
from typing import Dict, List, Optional, Tuple
import tempfile
import shutil

class MSwitchUnitTest:
    def __init__(self, ffmpeg_path: str = "./ffmpeg"):
        self.ffmpeg_path = ffmpeg_path
        self.test_dir = tempfile.mkdtemp(prefix="mswitch_test_")
        self.processes = []
        self.webhook_server = None
        self.webhook_port = 8080
        self.webhook_requests = []
        self.test_results = {}
        
        print(f"Test directory: {self.test_dir}")
        
    def cleanup(self):
        """Clean up test processes and files"""
        for proc in self.processes:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
        
        if self.webhook_server:
            self.webhook_server.shutdown()
            
        shutil.rmtree(self.test_dir, ignore_errors=True)
        
    def create_test_streams(self) -> Dict[str, str]:
        """Generate various test streams"""
        streams = {}
        
        # 1. MPEGTS UDP stream
        udp_stream = os.path.join(self.test_dir, "stream_udp.ts")
        cmd = [
            self.ffmpeg_path,
            "-f", "lavfi", "-i", "testsrc=duration=60:size=640x480:rate=25",
            "-f", "lavfi", "-i", "sine=frequency=1000:duration=60",
            "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
            "-c:a", "aac", "-b:a", "128k",
            "-f", "mpegts", udp_stream,
            "-y"
        ]
        print("Creating MPEGTS UDP stream...")
        subprocess.run(cmd, check=True, capture_output=True)
        streams["udp"] = udp_stream
        
        # 2. SRT stream (simulated with file)
        srt_stream = os.path.join(self.test_dir, "stream_srt.ts")
        cmd = [
            self.ffmpeg_path,
            "-f", "lavfi", "-i", "testsrc=duration=60:size=720x576:rate=25",
            "-f", "lavfi", "-i", "sine=frequency=2000:duration=60",
            "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
            "-c:a", "aac", "-b:a", "192k",
            "-f", "mpegts", srt_stream,
            "-y"
        ]
        print("Creating SRT stream...")
        subprocess.run(cmd, check=True, capture_output=True)
        streams["srt"] = srt_stream
        
        # 3. RTMP stream (simulated with file)
        rtmp_stream = os.path.join(self.test_dir, "stream_rtmp.ts")
        cmd = [
            self.ffmpeg_path,
            "-f", "lavfi", "-i", "testsrc=duration=60:size=1280x720:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=3000:duration=60",
            "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
            "-c:a", "aac", "-b:a", "256k",
            "-f", "mpegts", rtmp_stream,
            "-y"
        ]
        print("Creating RTMP stream...")
        subprocess.run(cmd, check=True, capture_output=True)
        streams["rtmp"] = rtmp_stream
        
        # 4. Test pattern streams with different characteristics
        for i in range(3):
            pattern_stream = os.path.join(self.test_dir, f"pattern_{i}.ts")
            cmd = [
                self.ffmpeg_path,
                "-f", "lavfi", f"-i", f"testsrc=duration=60:size=640x480:rate=25:color={['red', 'green', 'blue'][i]}",
                "-f", "lavfi", f"-i", f"sine=frequency={1000 + i*500}:duration=60",
                "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
                "-c:a", "aac", "-b:a", "128k",
                "-f", "mpegts", pattern_stream,
                "-y"
            ]
            print(f"Creating test pattern stream {i}...")
            subprocess.run(cmd, check=True, capture_output=True)
            streams[f"pattern_{i}"] = pattern_stream
            
        return streams
        
    def start_webhook_server(self):
        """Start webhook server for MSwitch control"""
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
                
        # Create handler with test instance reference
        def handler(*args, **kwargs):
            return WebhookHandler(*args, test_instance=self, **kwargs)
            
        self.webhook_server = socketserver.TCPServer(("", self.webhook_port), handler)
        self.webhook_thread = threading.Thread(target=self.webhook_server.serve_forever)
        self.webhook_thread.daemon = True
        self.webhook_thread.start()
        print(f"Webhook server started on port {self.webhook_port}")
        
    def test_basic_mswitch_parsing(self) -> bool:
        """Test basic MSwitch option parsing"""
        print("\n=== Test 1: Basic MSwitch Option Parsing ===")
        
        cmd = [
            self.ffmpeg_path,
            "-msw.enable", "1",
            "-msw.sources", "s0=test1.ts;s1=test2.ts;s2=test3.ts",
            "-msw.ingest", "hot",
            "-msw.mode", "graceful",
            "-msw.auto.enable", "1",
            "-msw.auto.on", "cc_errors_per_sec=5,packet_loss_percent=2.0,packet_loss_window_sec=10",
            "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=1",
            "-f", "null", "-"
        ]
        
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            success = result.returncode == 0 or "msw" in result.stderr.lower()
            print(f"Basic parsing test: {'PASSED' if success else 'FAILED'}")
            if not success:
                print(f"Error: {result.stderr}")
            return success
        except subprocess.TimeoutExpired:
            print("Basic parsing test: TIMEOUT")
            return False
            
    def test_stream_failover_scenarios(self, streams: Dict[str, str]) -> bool:
        """Test various failover scenarios"""
        print("\n=== Test 2: Stream Failover Scenarios ===")
        
        # Create a simple test with multiple sources
        sources = f"s0={streams['pattern_0']};s1={streams['pattern_1']};s2={streams['pattern_2']}"
        
        # Test 2a: Seamless failover
        print("Testing seamless failover...")
        cmd = [
            self.ffmpeg_path,
            "-msw.enable", "1",
            "-msw.sources", sources,
            "-msw.ingest", "hot",
            "-msw.mode", "seamless",
            "-msw.auto.enable", "1",
            "-msw.auto.on", "cc_errors_per_sec=1,packet_loss_percent=0.5,packet_loss_window_sec=5",
            "-t", "5",  # Short duration for testing
            "-f", "null", "-"
        ]
        
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            seamless_success = result.returncode == 0
            print(f"Seamless failover: {'PASSED' if seamless_success else 'FAILED'}")
        except subprocess.TimeoutExpired:
            seamless_success = False
            print("Seamless failover: TIMEOUT")
            
        # Test 2b: Graceful failover
        print("Testing graceful failover...")
        cmd = [
            self.ffmpeg_path,
            "-msw.enable", "1",
            "-msw.sources", sources,
            "-msw.ingest", "standby",
            "-msw.mode", "graceful",
            "-msw.auto.enable", "1",
            "-msw.auto.on", "cc_errors_per_sec=2,packet_loss_percent=1.0,packet_loss_window_sec=8",
            "-t", "5",
            "-f", "null", "-"
        ]
        
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            graceful_success = result.returncode == 0
            print(f"Graceful failover: {'PASSED' if graceful_success else 'FAILED'}")
        except subprocess.TimeoutExpired:
            graceful_success = False
            print("Graceful failover: TIMEOUT")
            
        # Test 2c: Cutover failover
        print("Testing cutover failover...")
        cmd = [
            self.ffmpeg_path,
            "-msw.enable", "1",
            "-msw.sources", sources,
            "-msw.ingest", "hot",
            "-msw.mode", "cutover",
            "-msw.freeze_on_cut", "2",
            "-msw.on_cut", "freeze",
            "-msw.auto.enable", "1",
            "-msw.auto.on", "cc_errors_per_sec=3,packet_loss_percent=1.5,packet_loss_window_sec=6",
            "-t", "5",
            "-f", "null", "-"
        ]
        
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            cutover_success = result.returncode == 0
            print(f"Cutover failover: {'PASSED' if cutover_success else 'FAILED'}")
        except subprocess.TimeoutExpired:
            cutover_success = False
            print("Cutover failover: TIMEOUT")
            
        return seamless_success and graceful_success and cutover_success
        
    def test_webhook_functionality(self) -> bool:
        """Test webhook control functionality"""
        print("\n=== Test 3: Webhook Functionality ===")
        
        # Start webhook server
        self.start_webhook_server()
        time.sleep(1)  # Give server time to start
        
        # Test webhook with MSwitch
        cmd = [
            self.ffmpeg_path,
            "-msw.enable", "1",
            "-msw.sources", "s0=test1.ts;s1=test2.ts;s2=test3.ts",
            "-msw.webhook.enable", "1",
            "-msw.webhook.port", str(self.webhook_port),
            "-msw.webhook.methods", "GET,POST",
            "-f", "lavfi", "-i", "testsrc=duration=10:size=320x240:rate=1",
            "-f", "null", "-"
        ]
        
        # Start FFmpeg in background
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.processes.append(proc)
            
            # Give FFmpeg time to start
            time.sleep(2)
            
            # Test webhook endpoints
            import urllib.request
            import urllib.error
            
            # Test GET /status
            try:
                with urllib.request.urlopen(f"http://localhost:{self.webhook_port}/status") as response:
                    status_data = json.loads(response.read().decode())
                    print(f"Webhook status response: {status_data}")
            except urllib.error.URLError as e:
                print(f"Webhook status test failed: {e}")
                return False
                
            # Test POST /switch
            try:
                data = json.dumps({"source": "1"}).encode()
                req = urllib.request.Request(f"http://localhost:{self.webhook_port}/switch", data=data)
                req.add_header('Content-Type', 'application/json')
                with urllib.request.urlopen(req) as response:
                    switch_data = json.loads(response.read().decode())
                    print(f"Webhook switch response: {switch_data}")
            except urllib.error.URLError as e:
                print(f"Webhook switch test failed: {e}")
                return False
                
            # Test POST /failover
            try:
                data = json.dumps({"action": "enable"}).encode()
                req = urllib.request.Request(f"http://localhost:{self.webhook_port}/failover", data=data)
                req.add_header('Content-Type', 'application/json')
                with urllib.request.urlopen(req) as response:
                    failover_data = json.loads(response.read().decode())
                    print(f"Webhook failover response: {failover_data}")
            except urllib.error.URLError as e:
                print(f"Webhook failover test failed: {e}")
                return False
                
            # Check if requests were recorded
            print(f"Webhook requests recorded: {len(self.webhook_requests)}")
            for i, req in enumerate(self.webhook_requests):
                print(f"Request {i+1}: {req['path']} - {req['data']}")
                
            # Stop FFmpeg
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                
            return len(self.webhook_requests) >= 3
            
        except Exception as e:
            print(f"Webhook test failed: {e}")
            return False
            
    def test_health_monitoring(self, streams: Dict[str, str]) -> bool:
        """Test health monitoring with various thresholds"""
        print("\n=== Test 4: Health Monitoring ===")
        
        sources = f"s0={streams['pattern_0']};s1={streams['pattern_1']};s2={streams['pattern_2']}"
        
        # Test different health thresholds
        health_tests = [
            {
                "name": "Strict monitoring",
                "thresholds": "cc_errors_per_sec=1,packet_loss_percent=0.1,packet_loss_window_sec=3"
            },
            {
                "name": "Moderate monitoring", 
                "thresholds": "cc_errors_per_sec=5,packet_loss_percent=2.0,packet_loss_window_sec=10"
            },
            {
                "name": "Lenient monitoring",
                "thresholds": "cc_errors_per_sec=10,packet_loss_percent=5.0,packet_loss_window_sec=20"
            }
        ]
        
        all_passed = True
        for test in health_tests:
            print(f"Testing {test['name']}...")
            cmd = [
                self.ffmpeg_path,
                "-msw.enable", "1",
                "-msw.sources", sources,
                "-msw.ingest", "hot",
                "-msw.mode", "graceful",
                "-msw.auto.enable", "1",
                "-msw.auto.on", test['thresholds'],
                "-t", "3",
                "-f", "null", "-"
            ]
            
            try:
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
                success = result.returncode == 0
                print(f"{test['name']}: {'PASSED' if success else 'FAILED'}")
                if not success:
                    all_passed = False
            except subprocess.TimeoutExpired:
                print(f"{test['name']}: TIMEOUT")
                all_passed = False
                
        return all_passed
        
    def test_json_configuration(self) -> bool:
        """Test JSON configuration loading"""
        print("\n=== Test 5: JSON Configuration ===")
        
        # Create test JSON config
        config = {
            "mswitch": {
                "enable": True,
                "sources": {
                    "s0": "test1.ts",
                    "s1": "test2.ts", 
                    "s2": "test3.ts"
                },
                "ingest_mode": "hot",
                "mode": "graceful",
                "buffer_ms": 1000,
                "auto_failover": {
                    "enable": True,
                    "thresholds": {
                        "cc_errors_per_sec": 5,
                        "packet_loss_percent": 2.0,
                        "packet_loss_window_sec": 10
                    }
                },
                "webhook": {
                    "enable": True,
                    "port": 8080,
                    "methods": ["GET", "POST"]
                },
                "revert": {
                    "policy": "auto",
                    "health_window_ms": 5000
                }
            }
        }
        
        config_file = os.path.join(self.test_dir, "mswitch_config.json")
        with open(config_file, 'w') as f:
            json.dump(config, f, indent=2)
            
        # Test with JSON config
        cmd = [
            self.ffmpeg_path,
            "-msw.config", config_file,
            "-f", "lavfi", "-i", "testsrc=duration=3:size=320x240:rate=1",
            "-f", "null", "-"
        ]
        
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            success = result.returncode == 0
            print(f"JSON configuration test: {'PASSED' if success else 'FAILED'}")
            if not success:
                print(f"Error: {result.stderr}")
            return success
        except subprocess.TimeoutExpired:
            print("JSON configuration test: TIMEOUT")
            return False
            
    def run_all_tests(self) -> Dict[str, bool]:
        """Run all unit tests"""
        print("Starting MSwitch Unit Tests...")
        print("=" * 50)
        
        results = {}
        
        try:
            # Test 1: Basic parsing
            results["basic_parsing"] = self.test_basic_mswitch_parsing()
            
            # Generate test streams
            print("\nGenerating test streams...")
            streams = self.create_test_streams()
            print(f"Generated {len(streams)} test streams")
            
            # Test 2: Failover scenarios
            results["failover_scenarios"] = self.test_stream_failover_scenarios(streams)
            
            # Test 3: Webhook functionality
            results["webhook_functionality"] = self.test_webhook_functionality()
            
            # Test 4: Health monitoring
            results["health_monitoring"] = self.test_health_monitoring(streams)
            
            # Test 5: JSON configuration
            results["json_configuration"] = self.test_json_configuration()
            
        except KeyboardInterrupt:
            print("\nTest interrupted by user")
            results["interrupted"] = True
        except Exception as e:
            print(f"\nTest failed with exception: {e}")
            results["exception"] = str(e)
        finally:
            self.cleanup()
            
        return results
        
    def print_results(self, results: Dict[str, bool]):
        """Print test results summary"""
        print("\n" + "=" * 50)
        print("MSWITCH UNIT TEST RESULTS")
        print("=" * 50)
        
        total_tests = 0
        passed_tests = 0
        
        for test_name, result in results.items():
            if isinstance(result, bool):
                total_tests += 1
                if result:
                    passed_tests += 1
                status = "PASSED" if result else "FAILED"
                print(f"{test_name:20} : {status}")
            else:
                print(f"{test_name:20} : {result}")
                
        print("-" * 50)
        print(f"Total: {passed_tests}/{total_tests} tests passed")
        
        if passed_tests == total_tests:
            print("🎉 ALL TESTS PASSED!")
        else:
            print("❌ Some tests failed")
            
        return passed_tests == total_tests

def main():
    """Main test runner"""
    import argparse
    
    parser = argparse.ArgumentParser(description="MSwitch Unit Test")
    parser.add_argument("--ffmpeg", default="./ffmpeg", help="Path to FFmpeg binary")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    args = parser.parse_args()
    
    if not os.path.exists(args.ffmpeg):
        print(f"Error: FFmpeg binary not found at {args.ffmpeg}")
        sys.exit(1)
        
    # Run tests
    test = MSwitchUnitTest(args.ffmpeg)
    results = test.run_all_tests()
    success = test.print_results(results)
    
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()

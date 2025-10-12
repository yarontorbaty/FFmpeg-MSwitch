#!/usr/bin/env python3
"""
SRT Bandwidth-Aware Bitrate Controller
Monitors SRT stats and dynamically adjusts x264 bitrate via TCP
"""

import socket
import time
import re
import sys
import subprocess
import threading

class SRTBitrateController:
    def __init__(self, x264_tcp_port, min_bitrate_kbps=500, max_bitrate_kbps=5000):
        self.x264_tcp_port = x264_tcp_port
        self.min_bitrate = min_bitrate_kbps
        self.max_bitrate = max_bitrate_kbps
        self.current_bitrate = max_bitrate_kbps
        self.running = True
        
    def send_x264_command(self, bitrate_kbps):
        """Send bitrate command to x264 via TCP"""
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(1.0)
            sock.connect(('127.0.0.1', self.x264_tcp_port))
            
            # x264 TCP format: "set bitrate <value>\n"
            command = f"set bitrate {bitrate_kbps}\n"
            sock.sendall(command.encode())
            
            response = sock.recv(1024).decode()
            sock.close()
            return True
        except Exception as e:
            print(f"[Controller] Failed to send x264 command: {e}", file=sys.stderr)
            return False
    
    def calculate_target_bitrate(self, bandwidth_mbps, loss_rate, rtt_ms):
        """Calculate target bitrate based on network conditions"""
        # Convert bandwidth to kbps
        available_bw_kbps = bandwidth_mbps * 1000
        
        # Start with 80% of available bandwidth (safety margin)
        target_bitrate = available_bw_kbps * 0.8
        
        # Reduce further based on packet loss
        if loss_rate > 5.0:  # Severe loss
            target_bitrate *= 0.5
        elif loss_rate > 2.0:  # High loss
            target_bitrate *= 0.7
        elif loss_rate > 0.5:  # Moderate loss
            target_bitrate *= 0.85
        
        # Reduce based on RTT (high RTT = network congestion)
        if rtt_ms > 200:  # Severe congestion
            target_bitrate *= 0.6
        elif rtt_ms > 100:  # Moderate congestion
            target_bitrate *= 0.8
        
        # Clamp to min/max
        target_bitrate = max(self.min_bitrate, min(self.max_bitrate, target_bitrate))
        
        return int(target_bitrate)
    
    def parse_srt_stats(self, log_line):
        """Parse SRT stats from FFmpeg log line"""
        # Format: [srt @ 0x...] SRT Stats: BW=11.92 Mbps, Loss=0.00%, RTT=0.1 ms
        bw_match = re.search(r'BW=([\d.]+)\s*Mbps', log_line)
        loss_match = re.search(r'Loss=([\d.]+)%', log_line)
        rtt_match = re.search(r'RTT=([\d.]+)\s*ms', log_line)
        
        if bw_match and loss_match and rtt_match:
            return {
                'bandwidth_mbps': float(bw_match.group(1)),
                'loss_rate': float(loss_match.group(1)),
                'rtt_ms': float(rtt_match.group(1))
            }
        return None
    
    def monitor_and_adjust(self, log_source):
        """Monitor SRT stats from log and adjust bitrate"""
        print("[Controller] Starting bitrate controller...")
        print(f"[Controller] Min: {self.min_bitrate} kbps, Max: {self.max_bitrate} kbps")
        print(f"[Controller] Monitoring SRT stats...")
        
        last_adjustment = time.time()
        adjustment_interval = 2.0  # Adjust every 2 seconds max
        
        for line in log_source:
            if not self.running:
                break
                
            line = line.strip()
            
            # Look for SRT Stats
            if 'SRT Stats:' in line:
                stats = self.parse_srt_stats(line)
                if stats:
                    # Calculate new target bitrate
                    target_bitrate = self.calculate_target_bitrate(
                        stats['bandwidth_mbps'],
                        stats['loss_rate'],
                        stats['rtt_ms']
                    )
                    
                    # Only adjust if significant change and enough time elapsed
                    current_time = time.time()
                    bitrate_change = abs(target_bitrate - self.current_bitrate)
                    time_since_last = current_time - last_adjustment
                    
                    if bitrate_change > 200 and time_since_last >= adjustment_interval:
                        print(f"[Controller] BW={stats['bandwidth_mbps']:.2f} Mbps, "
                              f"Loss={stats['loss_rate']:.2f}%, RTT={stats['rtt_ms']:.1f} ms "
                              f"→ Bitrate: {self.current_bitrate} → {target_bitrate} kbps")
                        
                        if self.send_x264_command(target_bitrate):
                            self.current_bitrate = target_bitrate
                            last_adjustment = current_time
                    elif time_since_last >= 5.0:  # Still log periodically
                        print(f"[Controller] BW={stats['bandwidth_mbps']:.2f} Mbps, "
                              f"Loss={stats['loss_rate']:.2f}%, RTT={stats['rtt_ms']:.1f} ms "
                              f"→ Bitrate: {self.current_bitrate} kbps (stable)")
                        last_adjustment = current_time
    
    def stop(self):
        """Stop the controller"""
        self.running = False

def main():
    if len(sys.argv) < 2:
        print("Usage: srt_bitrate_controller.py <x264_tcp_port> [min_kbps] [max_kbps]")
        sys.exit(1)
    
    x264_port = int(sys.argv[1])
    min_kbps = int(sys.argv[2]) if len(sys.argv) > 2 else 500
    max_kbps = int(sys.argv[3]) if len(sys.argv) > 3 else 5000
    
    controller = SRTBitrateController(x264_port, min_kbps, max_kbps)
    
    try:
        # Read from stdin (FFmpeg logs piped in)
        controller.monitor_and_adjust(sys.stdin)
    except KeyboardInterrupt:
        print("\n[Controller] Stopping...")
        controller.stop()

if __name__ == "__main__":
    main()


#!/usr/bin/env python3
"""
Real-time bitrate and packet loss plotter.
Reads data from stdin and displays both metrics.
"""

import sys
import re
import time

# Data storage
timestamps = []
bitrates = []
target_bitrates = []
packet_losses = []

current_target = 0.0
demo_start_time = time.time()

print("[PLOT] Waiting 8 seconds for VLC to start playback and sync...")
sys.stdout.flush()
time.sleep(8)
print("[PLOT] Starting plot updates - now synchronized with video!")
print("")
sys.stdout.flush()

# Process stdin line by line
for line in sys.stdin:
    current_time = time.time() - demo_start_time
    
    # Extract actual bitrate from FFmpeg output
    bitrate_match = re.search(r'bitrate=\s*(\d+\.?\d*)([km])bits/s', line)
    if bitrate_match:
        bitrate_str = bitrate_match.group(1)
        bitrate_unit = bitrate_match.group(2)
        
        bitrate = float(bitrate_str)
        if bitrate_unit == 'k':
            bitrate /= 1000.0  # Convert kbps to Mbps
        
        timestamps.append(current_time)
        bitrates.append(bitrate)
        target_bitrates.append(current_target)
        
        print(f"[PLOT] t={current_time:.1f}s | Bitrate: {bitrate:.2f} Mbps | Target: {current_target:.2f} Mbps")
        sys.stdout.flush()
    
    # Extract target bitrate from rate control messages
    target_match = re.search(r'→ Bitrate:.* → (\d+) bps', line)
    if target_match:
        current_target = int(target_match.group(1)) / 1000000.0  # Convert to Mbps
        print(f"[PLOT] Target bitrate changed to {current_target:.2f} Mbps at {current_time:.1f}s")
        sys.stdout.flush()
    
    # Extract packet loss from SRT stats
    loss_match = re.search(r'Loss=([\d.]+)%', line)
    if loss_match:
        loss_value = float(loss_match.group(1))
        packet_losses.append((current_time, loss_value))
        print(f"[PLOT] Packet Loss: {loss_value:.2f}% at {current_time:.1f}s")
        sys.stdout.flush()
    
    # Detect phase changes
    phase_match = re.search(r'(PHASE \d+):', line)
    if phase_match:
        print(f"[PLOT] Phase changed to {phase_match.group(1)} at {current_time:.1f}s")
        sys.stdout.flush()

# Summary
print("\n[PLOT] Demo complete!")
print(f"[PLOT] Processed {len(timestamps)} bitrate samples")
print(f"[PLOT] Processed {len(packet_losses)} loss samples")
if timestamps:
    print(f"[PLOT] Average bitrate: {sum(bitrates)/len(bitrates):.2f} Mbps")
if packet_losses:
    avg_loss = sum(l[1] for l in packet_losses) / len(packet_losses)
    print(f"[PLOT] Average packet loss: {avg_loss:.2f}%")
sys.stdout.flush()

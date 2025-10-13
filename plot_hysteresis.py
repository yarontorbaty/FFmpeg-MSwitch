#!/usr/bin/env python3
"""
Real-time bitrate plotter for SRT Smart Hysteresis Demo
Reads from Docker logs and plots actual vs target bitrate + packet loss
"""

import subprocess
import time
import re
import sys
from collections import deque

try:
    import plotext as plt
except ImportError:
    print("ERROR: plotext not installed. Run: pip3 install plotext")
    sys.exit(1)

CONTAINER_NAME = "ffmpeg_hysteresis_demo"
MAX_POINTS = 200
UPDATE_INTERVAL = 0.5  # Update plot every 0.5 seconds

# Data storage
times = deque(maxlen=MAX_POINTS)
actual_bitrates = deque(maxlen=MAX_POINTS)
target_bitrates = deque(maxlen=MAX_POINTS)
packet_losses = deque(maxlen=MAX_POINTS)

# Current values
current_target = 20.0
current_loss = 0.0
start_time = None
last_log_line = ""

# Phase markers
phase_times = [0, 25, 50, 75, 100]
phase_labels = ["Excellent\n30Mbps", "Congestion\n8Mbps", "Recovery\n15Mbps", "Fluctuation\n6Mbps"]

def extract_actual_bitrate(line):
    """Extract actual encoding bitrate from FFmpeg output"""
    match = re.search(r'bitrate=\s*([0-9.]+)([kmg])bits', line, re.IGNORECASE)
    if match:
        value = float(match.group(1))
        unit = match.group(2).lower()
        if unit == 'k':
            return value / 1000.0  # Kbps to Mbps
        elif unit == 'm':
            return value
        elif unit == 'g':
            return value * 1000.0
    return None

def extract_target_bitrate(line):
    """Extract target bitrate from SRT Rate Control logs"""
    # Look for "→ X.XX Mbps" or "DOWNSHIFT: X.XX → Y.YY Mbps"
    match = re.search(r'→\s*([0-9.]+)\s*Mbps', line)
    if match:
        return float(match.group(1))
    return None

def extract_loss_percentage(line):
    """Extract loss percentage from SRT stats"""
    # Look for "Loss=X.XX%"
    match = re.search(r'Loss=([0-9.]+)%', line)
    if match:
        return float(match.group(1))
    return None

def update_plot():
    """Update the terminal plot"""
    if len(times) < 2:
        return
    
    plt.clf()
    plt.subplots(2, 1)
    
    # Subplot 1: Bitrate
    plt.subplot(1, 1)
    plt.title("SRT Smart Hysteresis - Bitrate Adaptation")
    
    t_list = list(times)
    actual_list = list(actual_bitrates)
    target_list = list(target_bitrates)
    
    plt.plot(t_list, actual_list, label="Actual Bitrate", color="cyan", marker="dot")
    plt.plot(t_list, target_list, label="Target Bitrate", color="yellow", marker="dot")
    
    plt.ylim(0, 25)
    plt.xlim(max(0, min(t_list)), max(t_list) + 5)
    plt.xlabel("Time (seconds)")
    plt.ylabel("Bitrate (Mbps)")
    plt.grid(True, True)
    
    # Subplot 2: Packet Loss
    plt.subplot(2, 1)
    plt.title("Unrecovered Packet Loss")
    
    loss_list = list(packet_losses)
    plt.plot(t_list, loss_list, label="Packet Loss", color="red", marker="dot")
    
    plt.ylim(0, 5)
    plt.xlim(max(0, min(t_list)), max(t_list) + 5)
    plt.xlabel("Time (seconds)")
    plt.ylabel("Loss (%)")
    plt.grid(True, True)
    
    plt.show()

print("╔══════════════════════════════════════════════════════════════╗")
print("║          SRT Smart Hysteresis - Real-Time Plot               ║")
print("╚══════════════════════════════════════════════════════════════╝")
print("")
print("Waiting 8 seconds to sync with VLC...")
time.sleep(8)
start_time = time.time()

print("Starting plot... (Press Ctrl+C to stop)")
print("")

try:
    last_update = time.time()
    update_counter = 0
    
    while True:
        # Read latest logs from Docker
        try:
            result = subprocess.run(
                ['docker', 'logs', '--tail', '100', CONTAINER_NAME],
                capture_output=True,
                text=True,
                timeout=2
            )
            logs = result.stdout + result.stderr
        except Exception as e:
            print(f"Error reading logs: {e}")
            time.sleep(1)
            continue
        
        current_time = time.time() - start_time
        
        # Process each line
        for line in logs.split('\n'):
            # Skip if we've seen this line
            if line == last_log_line:
                continue
            
            # Update target bitrate
            target = extract_target_bitrate(line)
            if target is not None:
                current_target = target
            
            # Update loss
            loss = extract_loss_percentage(line)
            if loss is not None:
                current_loss = loss
            
            # Get actual bitrate from frame= lines
            actual = extract_actual_bitrate(line)
            if actual is not None and 'frame=' in line:
                times.append(current_time)
                actual_bitrates.append(actual)
                target_bitrates.append(current_target)
                packet_losses.append(current_loss)
                update_counter += 1
                last_log_line = line
        
        # Update plot every UPDATE_INTERVAL seconds or every 5 samples
        now = time.time()
        if (now - last_update >= UPDATE_INTERVAL) or (update_counter >= 5):
            if len(times) > 0:
                update_plot()
                last_update = now
                update_counter = 0
        
        # Stop after 110 seconds
        if current_time > 110:
            print("\nDemo complete - stopping plot.")
            break
        
        time.sleep(0.2)
        
except KeyboardInterrupt:
    print("\n\nPlot stopped by user.")
except Exception as e:
    print(f"\n\nError: {e}")
finally:
    if len(times) > 0:
        print(f"\nFinal stats:")
        print(f"  Samples collected: {len(times)}")
        print(f"  Final actual bitrate: {actual_bitrates[-1]:.2f} Mbps")
        print(f"  Final target bitrate: {target_bitrates[-1]:.2f} Mbps")
        print(f"  Final packet loss: {packet_losses[-1]:.2f}%")


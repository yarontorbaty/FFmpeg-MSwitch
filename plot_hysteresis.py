#!/usr/bin/env python3
"""
Real-time bitrate plotter for SRT Smart Hysteresis Demo
Reads from /tmp/sender.log and plots actual vs target bitrate + packet loss
"""

import subprocess
import time
import re
import sys
import os
from collections import deque

try:
    import matplotlib
    # Use native macOS backend (works better than TkAgg on macOS)
    matplotlib.use('MacOSX')
    import matplotlib.pyplot as plt
    from matplotlib.animation import FuncAnimation
    
    # Set dark theme
    plt.style.use('dark_background')
    
    print(f"✓ Using matplotlib {matplotlib.__version__} with {matplotlib.get_backend()} backend")
except ImportError:
    print("ERROR: matplotlib not installed. Run: pip3 install matplotlib")
    sys.exit(1)

LOG_FILE = "/tmp/sender.log"
FFPLAY_LOG = "/tmp/ffplay_receiver.log"
THROUGHPUT_LOG = "/tmp/network_throughput.log"
MAX_POINTS = 200
UPDATE_INTERVAL = 1000  # Update plot every 1 second (in ms)

# Data storage
times = deque(maxlen=MAX_POINTS)
srt_bandwidth = deque(maxlen=MAX_POINTS)  # SRT bandwidth (encoder + overhead)
receiver_throughput = deque(maxlen=MAX_POINTS)  # Actual receiver throughput (ffplay)
target_bitrates = deque(maxlen=MAX_POINTS)
packet_losses = deque(maxlen=MAX_POINTS)
unrecovered_packets = deque(maxlen=MAX_POINTS)
unrecovered_percent = deque(maxlen=MAX_POINTS)

# Current values
current_target = 25.0  # Start at max bitrate
current_loss = 0.0
current_unrecovered = 0
current_srt_bandwidth = 0.0  # SRT reported bandwidth (sender side)
current_receiver_throughput = 0.0  # Actual measured network throughput (receiver side)
start_time = None
last_log_line = ""
frame_count = 0
last_unrecovered = 0  # Track previous unrecovered count for delta calculation
last_throughput_position = 0  # Track throughput log position

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

def extract_srt_bandwidth(line):
    """Extract SRT bandwidth measurement (sender side - may not reflect receiver constraint)"""
    # Look for "BW=X.XX Mbps" in SRT Stats
    match = re.search(r'BW=([0-9.]+)\s*Mbps', line)
    if match:
        return float(match.group(1))
    return None

def extract_receiver_bitrate(line):
    """Extract bitrate from ffplay's decoder output"""
    # ffplay logs stream info like: "Stream #0:0: Video: h264, yuv420p, 1280x720, 25 fps, 25 tbr, 90k tbn (default)"
    # And periodic stats like: "0B f=0/0   9.42 A-V:  0.000 fd=   0 aq=    0KB vq=    0KB"
    # We'll rely on throughput log for actual measurement
    return None

def extract_target_bitrate(line):
    """Extract target bitrate from SRT Rate Control logs or HTTP control logs"""
    # ONLY look for "✓ RESTARTED:" lines - these are actual applied bitrate changes
    # Ignore "INSTANT DOWNSHIFT", "UPSHIFT PENDING", etc. - those are just intentions/proposals
    if '✓ RESTARTED:' in line:
        match = re.search(r'RESTARTED:\s*[0-9.]+\s*→\s*([0-9.]+)\s*Mbps', line)
        if match:
            return float(match.group(1))
    
    # Look for HTTP control logs: "Target bitrate: XXXX kbps"
    if '[HTTP Control]' in line and 'Target bitrate:' in line:
        match = re.search(r'Target bitrate:\s*(\d+)\s*kbps', line)
        if match:
            return float(match.group(1)) / 1000.0  # Convert to Mbps
    
    return None

def extract_loss_percentage(line):
    """Extract loss percentage from SRT stats"""
    # Look for "Loss=X.XX%"
    match = re.search(r'Loss=([0-9.]+)%', line)
    if match:
        return float(match.group(1))
    return None

def extract_unrecovered_packets(line):
    """Extract unrecovered packets percentage from SRT stats"""
    # Look for "Unrecovered=12345 pkts (16.58%)"
    match = re.search(r'Unrecovered=([0-9]+)\s+pkts\s+\(([0-9.]+)%\)', line)
    if match:
        try:
            unrecovered_count = int(match.group(1))  # 12354
            unrecovered_percent = float(match.group(2))  # 16.58
            return unrecovered_percent
        except (ValueError, IndexError):
            return None
    return None

def estimate_unrecovered_packets(bitrate_mbps, loss_percent, duration_sec=1.0):
    """Estimate unrecovered packets based on bitrate and loss percentage (fallback)"""
    if bitrate_mbps <= 0 or loss_percent <= 0:
        return 0
    
    # Typical packet size for video streaming (MTU)
    packet_size_bytes = 1316  # SRT typical payload size
    packet_size_bits = packet_size_bytes * 8
    
    # Calculate packets per second
    bitrate_bps = bitrate_mbps * 1_000_000
    packets_per_sec = bitrate_bps / packet_size_bits
    
    # Calculate lost packets
    lost_packets = (packets_per_sec * loss_percent / 100.0) * duration_sec
    
    return int(lost_packets)

def read_network_throughput():
    """Read actual network throughput from Docker stats (receiver side)"""
    global current_receiver_throughput, last_throughput_position
    
    if not os.path.exists(THROUGHPUT_LOG):
        return
    
    try:
        with open(THROUGHPUT_LOG, 'r') as f:
            f.seek(last_throughput_position)
            lines = f.readlines()
            last_throughput_position = f.tell()
            
            # Get the last valid line
            for line in reversed(lines):
                if line.startswith('#'):
                    continue
                parts = line.strip().split()
                if len(parts) >= 3:
                    current_receiver_throughput = float(parts[2])  # mbps column
                    break
    except Exception:
        pass

def update_plot(frame):
    """Update the plot with new data"""
    global current_target, current_loss, current_unrecovered, current_srt_bandwidth, current_receiver_throughput, start_time, last_position, last_unrecovered
    
    # Read network throughput first
    read_network_throughput()
    
    # Read new lines from log file
    if not os.path.exists(LOG_FILE):
        ax1.text(0.5, 0.5, f'Waiting for log file:\n{LOG_FILE}', 
                 ha='center', va='center', transform=ax1.transAxes, fontsize=14)
        return
    
    try:
        with open(LOG_FILE, 'r') as f:
            f.seek(last_position)
            new_lines = f.readlines()
            last_position = f.tell()
            
            current_time = time.time() - start_time
            
            for line in new_lines:
                # Update target bitrate
                target = extract_target_bitrate(line)
                if target is not None:
                    current_target = target
                
                # Update loss from SRT stats
                loss = extract_loss_percentage(line)
                if loss is not None:
                    current_loss = loss
                
                # Extract SRT bandwidth (sender side: encoder + overhead)
                srt_bw = extract_srt_bandwidth(line)
                if srt_bw is not None:
                    current_srt_bandwidth = srt_bw
                
                # Extract actual unrecovered packets from logs (cumulative count)
                unrecov = extract_unrecovered_packets(line)
                if unrecov is not None:
                    current_unrecovered = unrecov
                
                # Get actual bitrate from frame= lines to trigger data point
                actual = extract_actual_bitrate(line)
                if actual is not None and 'frame=' in line:
                    
                    # Calculate unrecovered packets in the past second (delta)
                    unrecov_delta = max(0, current_unrecovered - last_unrecovered)
                    last_unrecovered = current_unrecovered
                    
                    # Calculate percentage of unrecovered packets vs total packets
                    # Use SRT bandwidth for packet calculation (sender side)
                    packet_size_bits = 1316 * 8  # SRT typical payload
                    if current_srt_bandwidth > 0:
                        total_packets_per_sec = (current_srt_bandwidth * 1_000_000) / packet_size_bits
                        unrecov_pct = (unrecov_delta / total_packets_per_sec) * 100.0 if total_packets_per_sec > 0 else 0
                    else:
                        unrecov_pct = 0
                    
                    times.append(current_time)
                    srt_bandwidth.append(current_srt_bandwidth)  # Sender: encoder + SRT overhead
                    receiver_throughput.append(current_receiver_throughput)  # Receiver: actual throughput
                    target_bitrates.append(current_target)
                    packet_losses.append(current_loss)
                    unrecovered_packets.append(unrecov_delta)  # Store delta, not cumulative
                    unrecovered_percent.append(unrecov_pct)
    except Exception as e:
        ax1.text(0.5, 0.5, f'Error reading log:\n{str(e)}', 
                 ha='center', va='center', transform=ax1.transAxes, fontsize=12, color='red')
        return
    
    if len(times) < 2:
        ax1.text(0.5, 0.5, f'Collecting data...\n({len(times)} samples)', 
                 ha='center', va='center', transform=ax1.transAxes, fontsize=14)
        return
    
    # Clear and redraw
    ax1.clear()
    ax2.clear()
    
    t_list = list(times)
    srt_bw_list = list(srt_bandwidth)
    receiver_list = list(receiver_throughput)
    target_list = list(target_bitrates)
    loss_list = list(packet_losses)
    unrecovered_pct_list = list(unrecovered_percent)
    
    # Plot 1: Bitrate with three lines showing sender, receiver, and target
    ax1.plot(t_list, srt_bw_list, label="SRT Bandwidth (Encoder+Overhead)", color="#00FF00", linewidth=3, marker='o', markersize=3, alpha=0.9)
    ax1.plot(t_list, receiver_list, label="Receiver Throughput (ffplay)", color="#00FFFF", linewidth=3, marker='x', markersize=4, alpha=0.9)
    ax1.plot(t_list, target_list, label="Target Bitrate", color="#FFA500", linewidth=3, linestyle='--', marker='s', markersize=4)
    
    ax1.set_title("SRT Smart Hysteresis - Sender vs Receiver Bitrate", fontsize=14, fontweight='bold', color='white')
    ax1.set_ylabel("Bitrate (Mbps)", fontsize=12, color='white')
    ax1.set_ylim(0, 35)
    ax1.legend(loc='upper right', fontsize=9, framealpha=0.9)
    ax1.grid(True, alpha=0.4, color='gray', linestyle=':')
    
    # Add phase markers with brighter colors
    phase_colors = ['#00FF00', '#FF8C00', '#FF0000', '#00FF00']  # Bright green, orange, red
    phase_times_list = [0, 20, 40, 60]
    phase_labels_list = ['Phase 1\nUnlimited\n25 Mbps', 'Phase 2\n15 Mbps', 'Phase 3\n5 Mbps', 'Phase 4\nUnlimited']
    
    for i, (t, label, color) in enumerate(zip(phase_times_list, phase_labels_list, phase_colors)):
        if t <= max(t_list):
            ax1.axvline(x=t, color=color, linestyle=':', alpha=0.7, linewidth=2)
            if t < max(t_list):
                ax1.text(t + 1, 30, label, fontsize=9, color=color, alpha=0.9, fontweight='bold',
                        bbox=dict(boxstyle='round,pad=0.3', facecolor='black', alpha=0.7, edgecolor=color))
    
    # Plot 2: Unrecovered Packets Percentage Only
    ax2.plot(t_list, unrecovered_pct_list, label="Unrecovered %", color="#FFFF00", linewidth=3, marker='o', markersize=4)
    ax2.set_ylabel("Unrecovered %", fontsize=12, color='#FFFF00')
    ax2.set_title("Unrecovered Packets Percentage", fontsize=12, color='white')
    ax2.set_xlabel("Time (seconds)", fontsize=12, color='white')
    max_unrecov_pct = max(unrecovered_pct_list) if unrecovered_pct_list else 5
    ax2.set_ylim(0, max(5, max_unrecov_pct * 1.2))
    ax2.tick_params(axis='y', labelcolor='#FFFF00')
    ax2.grid(True, alpha=0.4, color='gray', linestyle=':')
    
    # Legend
    ax2.legend(loc='upper right', fontsize=11, framealpha=0.9)
    
    plt.tight_layout()

print("╔══════════════════════════════════════════════════════════════╗")
print("║          SRT Smart Hysteresis - Real-Time Plot               ║")
print("╚══════════════════════════════════════════════════════════════╝")
print("")
print("Waiting for log file to appear...")

# Wait for log file
timeout = 30
waited = 0
while not os.path.exists(LOG_FILE) and waited < timeout:
    time.sleep(0.5)
    waited += 0.5

if not os.path.exists(LOG_FILE):
    print(f"ERROR: Log file not found after {timeout}s: {LOG_FILE}")
    sys.exit(1)

print(f"✓ Log file found: {LOG_FILE}")
print("Starting plot... (Close window or press Ctrl+C to stop)")
print(f"Reading from: {LOG_FILE}")
print("")

start_time = time.time()
last_position = 0
last_unrecovered = 0  # Initialize global variable for tracking unrecovered packet delta

# Create figure with 2 subplots
fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 8))
fig.suptitle("SRT Smart Hysteresis Demo - Real-Time Monitoring", fontsize=16, fontweight='bold')

try:
    # Start animation
    ani = FuncAnimation(fig, update_plot, interval=UPDATE_INTERVAL, cache_frame_data=False)
    plt.show()
    
except KeyboardInterrupt:
    print("\n\nPlot stopped by user.")
except Exception as e:
    print(f"\n\nError: {e}")
    import traceback
    traceback.print_exc()
finally:
    if len(times) > 0:
        print(f"\nFinal stats:")
        print(f"  Samples collected: {len(times)}")
        print(f"  Final actual bitrate: {actual_bitrates[-1]:.2f} Mbps")
        print(f"  Final target bitrate: {target_bitrates[-1]:.2f} Mbps")
        print(f"  Final packet loss: {packet_losses[-1]:.2f}%")


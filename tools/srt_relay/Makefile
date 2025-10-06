# Makefile for SRT Relay Server

CC = gcc
CFLAGS = -Wall -O2 -I/opt/homebrew/include
LDFLAGS = -L/opt/homebrew/lib -lsrt -lpthread

TARGET = srt_relay
SOURCE = srt_relay.c

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(CC) $(CFLAGS) -o $(TARGET) $(SOURCE) $(LDFLAGS)
	@echo ""
	@echo "Build complete! Run with:"
	@echo "  ./$(TARGET) <input_port> <output_port_1> [output_port_2] ..."
	@echo ""
	@echo "Example:"
	@echo "  ./$(TARGET) 9000 12350 12351 12352"

clean:
	rm -f $(TARGET)

.PHONY: all clean

# Makefile for SRT Relay Server

CC = gcc
CFLAGS = -Wall -O2
LDFLAGS = -lsrt

# Platform-specific flags
UNAME_S := $(shell uname -s 2>/dev/null || echo Windows)
ifeq ($(UNAME_S),Darwin)
    # macOS
    CFLAGS += -I/opt/homebrew/include
    LDFLAGS += -L/opt/homebrew/lib -lpthread
else ifeq ($(UNAME_S),Linux)
    # Linux
    LDFLAGS += -lpthread
else
    # Windows (MSYS2/MinGW)
    LDFLAGS += -lws2_32
    TARGET_EXT = .exe
endif

TARGET = srt_relay$(TARGET_EXT)
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
	rm -f $(TARGET) srt_relay srt_relay.exe

.PHONY: all clean

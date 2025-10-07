# GitHub Actions Build Workflow

This workflow automatically builds FFmpeg MSwitch for all platforms when you push a git tag.

## Platforms Built

- **macOS arm64** (Apple Silicon) - runs on `macos-latest`
- **macOS x86_64** (Intel) - runs on `macos-13`
- **Linux x86_64** - runs on `ubuntu-latest`
- **Windows x86_64** - runs on `windows-latest` with MSYS2

## How to Trigger a Release Build

### Option 1: Create and Push a Tag

```bash
# Tag the current commit
git tag -a v1.0.0 -m "Release v1.0.0"

# Push the tag to GitHub
git push origin v1.0.0
```

This will automatically:
1. Build for all 4 platforms in parallel
2. Create release packages with binaries, documentation, and SRT relay
3. Create a GitHub Release with all the packages attached

### Option 2: Manual Trigger

You can also manually trigger the workflow from the GitHub Actions tab:
1. Go to your repository on GitHub
2. Click "Actions"
3. Select "Build FFmpeg MSwitch Releases"
4. Click "Run workflow"
5. Choose the branch and click "Run workflow"

Note: Manual triggers will build all platforms but won't create a GitHub Release (only tag pushes do that).

## What Gets Built

Each platform package includes:
- `ffmpeg` - Main FFmpeg binary with mswitchdirect demuxer
- `ffprobe` - Media analysis tool
- `ffplay` - Simple media player
- `srt_relay` - SRT relay server for multi-client support
- `mswitch_srt` - Helper script for SRT setup
- `README.md` - Main documentation
- `LICENSE.md` - License information
- `SRT_RELAY_README.md` - SRT relay documentation
- `VERSION.txt` - Build information

## Build Features

All builds include:
- **Codecs**: H.264 (libx264), HEVC (libx265), AV1 (libaom)
- **Protocols**: UDP, TCP, RTSP, RTMP, SRT
- **Filters**: All standard filters including drawtext, overlay, scale, etc.
- **Custom Demuxer**: mswitchdirect for multi-source failover

## Viewing Build Status

Check the "Actions" tab in your GitHub repository to see:
- Current and past build runs
- Build logs for each platform
- Download artifacts from builds (available for 90 days)

## Troubleshooting

If a build fails:
1. Click on the failed workflow run
2. Click on the failed job (e.g., "build-linux")
3. Expand the failed step to see the error
4. Common issues:
   - Missing dependencies (check the "Install dependencies" step)
   - Configuration errors (check the "Configure" step)
   - Compilation errors (check the "Build" step)

## Local Testing

To test the workflow locally before pushing:

```bash
# Install act (GitHub Actions local runner)
brew install act  # macOS
# or
curl https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash  # Linux

# Run the workflow locally (requires Docker)
act -j build-linux
```

Note: Local testing only works well for Linux builds. macOS and Windows builds require their respective runners.

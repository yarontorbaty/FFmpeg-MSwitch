/*
 * MSwitch Direct demuxer - CLI control interface
 * Copyright (c) 2025
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef AVFORMAT_MSWITCHDIRECT_H
#define AVFORMAT_MSWITCHDIRECT_H

/**
 * Switch to a different source via CLI
 * @param source_index Index of the source to switch to (0-based)
 * @return 0 on success, negative error code on failure
 */
int mswitchdirect_cli_switch(int source_index);

/**
 * Display current status of the demuxer via CLI
 */
void mswitchdirect_cli_status(void);

#endif /* AVFORMAT_MSWITCHDIRECT_H */


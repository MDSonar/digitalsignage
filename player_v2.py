#!/usr/bin/env python3
"""
Digital Signage Player - Simple & Reliable
Polls for new files, finishes current playlist before updating
No dependencies, no RC interface, just works!
"""

import os
import subprocess
import time
from pathlib import Path
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(message)s',
    handlers=[
        logging.FileHandler(os.path.expanduser('~/signage/logs/player.log')),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

CONTENT_DIR = os.path.expanduser("~/signage/content")
IMAGE_DURATION = 10
VIDEO_FORMATS = ['.mp4', '.avi', '.mov', '.mkv', '.webm']
IMAGE_FORMATS = ['.jpg', '.jpeg', '.png', '.gif', '.bmp']
PLAYLIST_FILE = os.path.expanduser("~/signage/playlist.m3u")
CHECK_INTERVAL = 3  # Check every 3 seconds

class SimplePollingPlayer:
    def __init__(self):
        self.content_dir = Path(CONTENT_DIR)
        self.content_dir.mkdir(parents=True, exist_ok=True)
        logger.info(f"Player started. Content dir: {CONTENT_DIR}")
        
        self.vlc_process = None
        self.current_files = []
        self.pending_update = False
    
    def get_media_files(self):
        """Get all media files sorted by name"""
        files = []
        
        for ext in VIDEO_FORMATS + IMAGE_FORMATS:
            files.extend(self.content_dir.glob(f"*{ext}"))
            files.extend(self.content_dir.glob(f"*{ext.upper()}"))
        
        return sorted(files)
    
    def create_playlist(self, files):
        """Create M3U playlist for VLC"""
        with open(PLAYLIST_FILE, 'w') as f:
            f.write("#EXTM3U\n")
            for filepath in files:
                ext = filepath.suffix.lower()
                
                if ext in IMAGE_FORMATS:
                    f.write(f"#EXTINF:{IMAGE_DURATION},{filepath.name}\n")
                else:
                    f.write(f"#EXTINF:-1,{filepath.name}\n")
                
                f.write(f"{filepath}\n")
        
        logger.info(f"Created playlist with {len(files)} items")
    
    def start_vlc(self):
        """Start VLC"""
        cmd = [
            "cvlc",
            "--fullscreen",
            "--no-video-title-show",
            "--no-osd",
            "--no-video-deco",
            "--video-on-top",
            "--no-interact",
            "--play-and-exit",
            "--image-duration", str(IMAGE_DURATION),
            PLAYLIST_FILE
        ]
        
        logger.info("Starting VLC...")
        self.vlc_process = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
    
    def is_vlc_running(self):
        """Check if VLC is running"""
        if not self.vlc_process:
            return False
        return self.vlc_process.poll() is None
    
    def stop_vlc(self):
        """Stop VLC"""
        if self.vlc_process and self.vlc_process.poll() is None:
            self.vlc_process.terminate()
            try:
                self.vlc_process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.vlc_process.kill()
            self.vlc_process = None
    
    def run(self):
        """Main loop"""
        logger.info("Starting simple polling player...")
        logger.info(f"Checking for new files every {CHECK_INTERVAL} seconds")
        
        while True:
            try:
                files = self.get_media_files()
                
                if not files:
                    logger.warning("No files found. Waiting...")
                    self.stop_vlc()
                    time.sleep(10)
                    continue
                
                # Detect changes
                if files != self.current_files:
                    if not self.is_vlc_running():
                        # Not playing, update now
                        logger.info(f"✓ Updating playlist: {len(files)} files")
                        self.create_playlist(files)
                        self.current_files = files.copy()
                        self.start_vlc()
                        self.pending_update = False
                    else:
                        # Playing, mark for later
                        if not self.pending_update:
                            logger.info(f"⏳ New files detected - will update after current playlist finishes")
                            self.pending_update = True
                
                # Restart if finished
                elif not self.is_vlc_running():
                    if self.pending_update:
                        logger.info(f"✓ Updating with new files: {len(files)} total")
                        self.create_playlist(files)
                        self.current_files = files.copy()
                        self.pending_update = False
                    else:
                        logger.info("↻ Restarting playlist")
                    
                    self.start_vlc()
                
                time.sleep(CHECK_INTERVAL)
                
            except KeyboardInterrupt:
                logger.info("Stopped by user")
                self.stop_vlc()
                break
            except Exception as e:
                logger.error(f"Error: {e}", exc_info=True)
                time.sleep(10)

if __name__ == "__main__":
    player = SimplePollingPlayer()
    player.run()

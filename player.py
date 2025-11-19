#!/usr/bin/env python3
"""
Minimal Digital Signage Player
Plays all media in ~/signage/content/ in loop
Works with modern Raspberry Pi OS (uses VLC instead of omxplayer)
"""

import os
import subprocess
import time
from pathlib import Path
import logging

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(message)s',
    handlers=[
        logging.FileHandler(os.path.expanduser('~/signage/logs/player.log')),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# Configuration
CONTENT_DIR = os.path.expanduser("~/signage/content")
IMAGE_DURATION = 10  # seconds
VIDEO_FORMATS = ['.mp4', '.avi', '.mov', '.mkv', '.webm']
IMAGE_FORMATS = ['.jpg', '.jpeg', '.png', '.gif', '.bmp']

class SimplePlayer:
    def __init__(self):
        self.content_dir = Path(CONTENT_DIR)
        self.content_dir.mkdir(parents=True, exist_ok=True)
        logger.info(f"Player started. Content dir: {CONTENT_DIR}")
        
        # Check available video players
        self.video_player = self.detect_video_player()
        logger.info(f"Using video player: {self.video_player}")
    
    def detect_video_player(self):
        """Detect available video player"""
        # Try VLC first (most reliable on modern Pi OS)
        if subprocess.run(['which', 'vlc'], capture_output=True).returncode == 0:
            return 'vlc'
        # Try omxplayer (legacy)
        elif subprocess.run(['which', 'omxplayer'], capture_output=True).returncode == 0:
            return 'omxplayer'
        else:
            logger.warning("No video player found!")
            return None
    
    def get_media_files(self):
        """Get all media files sorted by name"""
        files = []
        
        for ext in VIDEO_FORMATS + IMAGE_FORMATS:
            files.extend(self.content_dir.glob(f"*{ext}"))
            files.extend(self.content_dir.glob(f"*{ext.upper()}"))
        
        return sorted(files)
    
    def play_video(self, filepath):
        """Play video file"""
        logger.info(f"Playing video: {filepath.name}")
        
        if self.video_player == 'vlc':
            try:
                cmd = [
                    "cvlc",  # command-line VLC
                    "--fullscreen",
                    "--play-and-exit",
                    "--no-video-title-show",
                    "--no-osd",
                    str(filepath)
                ]
                subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception as e:
                logger.error(f"VLC playback error: {e}")
        
        elif self.video_player == 'omxplayer':
            try:
                cmd = ["omxplayer", "--no-osd", "--aspect-mode", "letterbox", str(filepath)]
                subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception as e:
                logger.error(f"omxplayer error: {e}")
        
        else:
            logger.warning("No video player available, skipping video")
            time.sleep(5)
    
    def show_image(self, filepath):
        """Display image"""
        logger.info(f"Showing image: {filepath.name}")
        
        try:
            cmd = ["feh", "--fullscreen", "--hide-pointer", "--auto-zoom", str(filepath)]
            proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(IMAGE_DURATION)
            proc.terminate()
            proc.wait()
        except FileNotFoundError:
            logger.error("feh not installed")
            time.sleep(IMAGE_DURATION)
    
    def play_file(self, filepath):
        """Play single file based on extension"""
        ext = filepath.suffix.lower()
        
        if ext in VIDEO_FORMATS:
            self.play_video(filepath)
        elif ext in IMAGE_FORMATS:
            self.show_image(filepath)
        else:
            logger.warning(f"Unknown format: {filepath.name}")
    
    def run(self):
        """Main loop"""
        logger.info("Starting playback loop...")
        
        while True:
            try:
                files = self.get_media_files()
                
                if not files:
                    logger.warning("No media files found. Waiting...")
                    time.sleep(10)
                    continue
                
                logger.info(f"Playing {len(files)} files in loop")
                
                for filepath in files:
                    self.play_file(filepath)
                
                logger.info("Loop complete, restarting...")
                
            except KeyboardInterrupt:
                logger.info("Stopped by user")
                break
            except Exception as e:
                logger.error(f"Error: {e}")
                time.sleep(5)

if __name__ == "__main__":
    player = SimplePlayer()
    player.run()

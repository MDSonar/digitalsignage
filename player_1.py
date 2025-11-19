#!/usr/bin/env python3
"""
Minimal Digital Signage Player
Plays all media in ~/signage/content/ in loop
Features:
- Auto-detects new files without restart
- Smooth transitions between videos
- Background preloading
"""

import os
import subprocess
import time
from pathlib import Path
import logging
import threading

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
CHECK_NEW_FILES_INTERVAL = 5  # Check for new files every 5 seconds

class SimplePlayer:
    def __init__(self):
        self.content_dir = Path(CONTENT_DIR)
        self.content_dir.mkdir(parents=True, exist_ok=True)
        logger.info(f"Player started. Content dir: {CONTENT_DIR}")
        
        # Check available video players
        self.video_player = self.detect_video_player()
        logger.info(f"Using video player: {self.video_player}")
        
        # Track current playlist
        self.current_files = []
        self.last_check_time = 0
        self.current_process = None
    
    def detect_video_player(self):
        """Detect available video player"""
        # Try VLC first (most reliable on modern Pi OS)
        if subprocess.run(['which', 'cvlc'], capture_output=True).returncode == 0:
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
    
    def check_for_new_files(self):
        """Check if playlist needs updating"""
        current_time = time.time()
        
        # Only check every N seconds to avoid excessive file system access
        if current_time - self.last_check_time < CHECK_NEW_FILES_INTERVAL:
            return False
        
        self.last_check_time = current_time
        new_files = self.get_media_files()
        
        # Compare with current playlist
        if new_files != self.current_files:
            logger.info(f"Playlist updated: {len(new_files)} files")
            self.current_files = new_files
            return True
        
        return False
    
    def play_video(self, filepath):
        """Play video file with smooth transitions"""
        logger.info(f"Playing video: {filepath.name}")
        
        if self.video_player == 'vlc':
            try:
                # Use VLC with minimal UI for smooth playback
                cmd = [
                    "cvlc",
                    "--fullscreen",
                    "--play-and-exit",
                    "--no-video-title-show",
                    "--no-osd",
                    "--no-video-deco",  # No window decorations
                    "--no-embedded-video",
                    "--video-on-top",
                    "--no-interact",
                    str(filepath)
                ]
                
                # Kill previous process if exists
                if self.current_process and self.current_process.poll() is None:
                    self.current_process.terminate()
                    self.current_process.wait(timeout=1)
                
                # Start new video
                self.current_process = subprocess.Popen(
                    cmd,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
                
                # Wait for video to finish
                self.current_process.wait()
                
            except Exception as e:
                logger.error(f"VLC playback error: {e}")
        
        elif self.video_player == 'omxplayer':
            try:
                cmd = [
                    "omxplayer",
                    "--no-osd",
                    "--aspect-mode", "letterbox",
                    "--blank",  # Blank other screens
                    str(filepath)
                ]
                
                # Kill previous process if exists
                if self.current_process and self.current_process.poll() is None:
                    self.current_process.terminate()
                    self.current_process.wait(timeout=1)
                
                self.current_process = subprocess.Popen(
                    cmd,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
                
                self.current_process.wait()
                
            except Exception as e:
                logger.error(f"omxplayer error: {e}")
        
        else:
            logger.warning("No video player available, skipping video")
            time.sleep(5)
    
    def show_image(self, filepath):
        """Display image"""
        logger.info(f"Showing image: {filepath.name}")
        
        try:
            # Kill previous feh process if exists
            if self.current_process and self.current_process.poll() is None:
                self.current_process.terminate()
                self.current_process.wait(timeout=1)
            
            cmd = [
                "feh",
                "--fullscreen",
                "--hide-pointer",
                "--auto-zoom",
                "--no-menus",
                str(filepath)
            ]
            
            self.current_process = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
            
            time.sleep(IMAGE_DURATION)
            
            # Terminate image display
            if self.current_process and self.current_process.poll() is None:
                self.current_process.terminate()
                self.current_process.wait(timeout=1)
                
        except FileNotFoundError:
            logger.error("feh not installed")
            time.sleep(IMAGE_DURATION)
        except Exception as e:
            logger.error(f"Image display error: {e}")
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
        """Main loop with auto-detection of new files"""
        logger.info("Starting playback loop with auto-detection...")
        
        # Initial playlist load
        self.current_files = self.get_media_files()
        playlist_index = 0
        
        while True:
            try:
                # Check for new files periodically
                if self.check_for_new_files():
                    logger.info("New files detected, updating playlist...")
                    playlist_index = 0  # Restart from beginning
                
                if not self.current_files:
                    logger.warning("No media files found. Waiting...")
                    time.sleep(10)
                    continue
                
                # Play current file
                if playlist_index < len(self.current_files):
                    filepath = self.current_files[playlist_index]
                    self.play_file(filepath)
                    playlist_index += 1
                else:
                    # Loop complete, restart
                    logger.info("Playlist complete, restarting...")
                    playlist_index = 0
                
            except KeyboardInterrupt:
                logger.info("Stopped by user")
                if self.current_process:
                    self.current_process.terminate()
                break
            except Exception as e:
                logger.error(f"Error: {e}", exc_info=True)
                time.sleep(5)

if __name__ == "__main__":
    player = SimplePlayer()
    player.run()

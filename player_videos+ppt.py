#!/usr/bin/env python3
"""
Digital Signage Player with PPT Support
- Videos play first from content/videos/
- PPTX auto-converts to images and plays after videos
- Smooth playlist updates
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
VIDEOS_DIR = os.path.expanduser("~/signage/content/videos")
PRESENTATIONS_DIR = os.path.expanduser("~/signage/content/presentations")
SLIDES_CACHE_DIR = os.path.expanduser("~/signage/cache/slides")
IMAGE_DURATION = 10  # seconds per image/slide
SLIDE_DURATION = 5   # seconds per PPT slide
VIDEO_FORMATS = ['.mp4', '.avi', '.mov', '.mkv', '.webm']
IMAGE_FORMATS = ['.jpg', '.jpeg', '.png', '.gif', '.bmp']
PPT_FORMATS = ['.pptx', '.ppt']
PLAYLIST_FILE = os.path.expanduser("~/signage/playlist.m3u")
CHECK_INTERVAL = 3

class PPTConverter:
    """Handles PPTX to PNG conversion using LibreOffice"""
    
    def __init__(self, cache_dir):
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)
    
    def get_cache_path(self, pptx_file):
        """Get cache directory for a PPTX file"""
        # Use file name (without extension) as cache folder
        cache_name = pptx_file.stem
        return self.cache_dir / cache_name
    
    def is_cached(self, pptx_file):
        """Check if PPTX already converted"""
        cache_path = self.get_cache_path(pptx_file)
        if not cache_path.exists():
            return False
        
        # Check if cache has PNG files
        png_files = list(cache_path.glob("*.png"))
        return len(png_files) > 0
    
    def convert_pptx(self, pptx_file):
        """Convert PPTX to PNG slides"""
        cache_path = self.get_cache_path(pptx_file)
        cache_path.mkdir(parents=True, exist_ok=True)
        
        logger.info(f"Converting PPTX: {pptx_file.name}")
        
        try:
            # Use LibreOffice to convert PPTX to PNG
            cmd = [
                "libreoffice",
                "--headless",
                "--convert-to", "png",
                "--outdir", str(cache_path),
                str(pptx_file)
            ]
            
            subprocess.run(cmd, check=True, timeout=120)
            
            # Get generated PNG files
            png_files = sorted(cache_path.glob("*.png"))
            
            if not png_files:
                logger.error(f"No PNG files generated for {pptx_file.name}")
                return []
            
            logger.info(f"✓ Converted {pptx_file.name}: {len(png_files)} slides")
            return png_files
            
        except subprocess.TimeoutExpired:
            logger.error(f"Timeout converting {pptx_file.name}")
            return []
        except Exception as e:
            logger.error(f"Failed to convert {pptx_file.name}: {e}")
            return []
    
    def get_slides(self, pptx_file):
        """Get PNG slides for a PPTX file (convert if needed)"""
        if not self.is_cached(pptx_file):
            self.convert_pptx(pptx_file)
        
        cache_path = self.get_cache_path(pptx_file)
        return sorted(cache_path.glob("*.png"))


class SmartPlaylistPlayer:
    def __init__(self):
        # Create directory structure
        self.content_dir = Path(CONTENT_DIR)
        self.videos_dir = Path(VIDEOS_DIR)
        self.presentations_dir = Path(PRESENTATIONS_DIR)
        
        self.content_dir.mkdir(parents=True, exist_ok=True)
        self.videos_dir.mkdir(parents=True, exist_ok=True)
        self.presentations_dir.mkdir(parents=True, exist_ok=True)
        
        logger.info(f"Player started")
        logger.info(f"Videos: {VIDEOS_DIR}")
        logger.info(f"Presentations: {PRESENTATIONS_DIR}")
        
        self.vlc_process = None
        self.current_playlist_hash = None
        self.pending_update = False
        
        # Initialize PPT converter
        self.ppt_converter = PPTConverter(SLIDES_CACHE_DIR)
    
    def get_video_files(self):
        """Get all video files from videos directory"""
        files = []
        for ext in VIDEO_FORMATS:
            files.extend(self.videos_dir.glob(f"*{ext}"))
            files.extend(self.videos_dir.glob(f"*{ext.upper()}"))
        return sorted(files)
    
    def get_presentation_files(self):
        """Get all PPTX files from presentations directory"""
        files = []
        for ext in PPT_FORMATS:
            files.extend(self.presentations_dir.glob(f"*{ext}"))
            files.extend(self.presentations_dir.glob(f"*{ext.upper()}"))
        return sorted(files)
    
    def build_playlist_items(self):
        """Build complete playlist: videos first, then PPT slides"""
        playlist_items = []
        
        # 1. Add videos first
        video_files = self.get_video_files()
        for video in video_files:
            playlist_items.append({
                'type': 'video',
                'path': video,
                'duration': -1  # Full video duration
            })
        
        logger.info(f"Added {len(video_files)} videos to playlist")
        
        # 2. Add PPT slides after videos
        ppt_files = self.get_presentation_files()
        total_slides = 0
        
        for ppt_file in ppt_files:
            slides = self.ppt_converter.get_slides(ppt_file)
            
            for slide in slides:
                playlist_items.append({
                    'type': 'slide',
                    'path': slide,
                    'duration': SLIDE_DURATION
                })
                total_slides += 1
        
        logger.info(f"Added {len(ppt_files)} presentations ({total_slides} slides) to playlist")
        
        return playlist_items
    
    def create_playlist(self, items):
        """Create M3U playlist for VLC"""
        with open(PLAYLIST_FILE, 'w') as f:
            f.write("#EXTM3U\n")
            
            for item in items:
                if item['type'] == 'video':
                    f.write(f"#EXTINF:-1,{item['path'].name}\n")
                else:  # slide
                    f.write(f"#EXTINF:{item['duration']},{item['path'].name}\n")
                
                f.write(f"{item['path']}\n")
        
        logger.info(f"✓ Created playlist with {len(items)} items")
    
    def get_playlist_hash(self, items):
        """Get hash of playlist to detect changes"""
        return hash(tuple(str(item['path']) for item in items))
    
    def start_vlc(self):
        """Start VLC with playlist"""
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
        
        logger.info("▶ Starting VLC...")
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
        logger.info("🎬 Starting playlist player with PPT support...")
        logger.info(f"📹 Videos from: {VIDEOS_DIR}")
        logger.info(f"📊 Presentations from: {PRESENTATIONS_DIR}")
        logger.info(f"⏱️  Checking for updates every {CHECK_INTERVAL} seconds")
        
        while True:
            try:
                # Build playlist from videos and presentations
                playlist_items = self.build_playlist_items()
                
                if not playlist_items:
                    logger.warning("⚠️  No content found. Waiting...")
                    self.stop_vlc()
                    time.sleep(10)
                    continue
                
                # Check for playlist changes
                playlist_hash = self.get_playlist_hash(playlist_items)
                
                if playlist_hash != self.current_playlist_hash:
                    if not self.is_vlc_running():
                        # Not playing, update now
                        logger.info(f"✓ Updating playlist: {len(playlist_items)} items")
                        self.create_playlist(playlist_items)
                        self.current_playlist_hash = playlist_hash
                        self.start_vlc()
                        self.pending_update = False
                    else:
                        # Playing, mark for later
                        if not self.pending_update:
                            logger.info(f"⏳ Changes detected - will update after current playlist")
                            self.pending_update = True
                
                # Restart if finished
                elif not self.is_vlc_running():
                    if self.pending_update:
                        logger.info(f"✓ Applying updates: {len(playlist_items)} items")
                        self.create_playlist(playlist_items)
                        self.current_playlist_hash = playlist_hash
                        self.pending_update = False
                    else:
                        logger.info("↻ Restarting playlist")
                    
                    self.start_vlc()
                
                time.sleep(CHECK_INTERVAL)
                
            except KeyboardInterrupt:
                logger.info("⏹️  Stopped by user")
                self.stop_vlc()
                break
            except Exception as e:
                logger.error(f"❌ Error: {e}", exc_info=True)
                time.sleep(10)


if __name__ == "__main__":
    player = SmartPlaylistPlayer()
    player.run()

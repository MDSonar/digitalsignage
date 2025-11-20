    #!/bin/bash
    # Digital Signage Complete Auto-Setup Script with Web Player
    # Run this once to set up everything automatically

    set -e

    echo "=========================================="
    echo "Digital Signage - Complete Auto Setup"
    echo "With Network TV Web Player Support"
    echo "=========================================="
    echo ""

    # Check if running as root
    if [ "$EUID" -eq 0 ]; then 
        echo "❌ Please run as normal user (not root)"
        exit 1
    fi

    # Base directory
    BASE_DIR="$HOME/signage"

    echo "📁 Installation directory: $BASE_DIR"
    echo ""

    # Step 1: Install system packages
    echo "→ Step 1/11: Installing system packages..."
    sudo apt-get update -qq
    sudo apt-get install -y \
        python3 \
        python3-pip \
        python3-venv \
        python3-full \
        vlc \
        feh \
        libreoffice \
        imagemagick \
        vsftpd 2>/dev/null || echo "  ⚠️  vsftpd not available (will use SFTP)"

    echo "✓ System packages installed"

    # Step 2: Create folder structure
    echo ""
    echo "→ Step 2/11: Creating folder structure..."
    mkdir -p "$BASE_DIR"/{content/{videos,presentations},cache/slides,logs,templates}

    echo "✓ Folder structure created:"
    echo "  $BASE_DIR/content/videos/"
    echo "  $BASE_DIR/content/presentations/"
    echo "  $BASE_DIR/cache/slides/"
    echo "  $BASE_DIR/templates/"

    # Step 3: Create Python virtual environment
    echo ""
    echo "→ Step 3/11: Setting up Python environment..."
    cd "$BASE_DIR"
    python3 -m venv venv
    source venv/bin/activate

    pip install --upgrade pip -q
    pip install -q pillow flask flask-login werkzeug gunicorn

    deactivate

    echo "✓ Python environment ready"

    # Step 4: Create player.py
    echo ""
    echo "→ Step 4/11: Creating player.py..."
    cat > "$BASE_DIR/player.py" << 'PLAYER_EOF'
    #!/usr/bin/env python3
    """
    Digital Signage Player with PPTX & PDF Support
    - Supports PPTX and PDF presentations
    - Videos play first, then all presentation slides
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
    IMAGE_DURATION = 10
    SLIDE_DURATION = 10
    VIDEO_FORMATS = ['.mp4', '.avi', '.mov', '.mkv', '.webm']
    PPT_FORMATS = ['.pptx', '.ppt']
    PDF_FORMATS = ['.pdf']
    PLAYLIST_FILE = os.path.expanduser("~/signage/playlist.m3u")
    CHECK_INTERVAL = 20

    class PresentationConverter:
        """Handles PPTX and PDF to PNG conversion"""
        
        def __init__(self, cache_dir):
            self.cache_dir = Path(cache_dir)
            self.cache_dir.mkdir(parents=True, exist_ok=True)
        
        def get_cache_path(self, presentation_file):
            cache_name = presentation_file.stem
            return self.cache_dir / cache_name
        
        def is_cached(self, presentation_file):
            cache_path = self.get_cache_path(presentation_file)
            if not cache_path.exists():
                return False
            png_files = list(cache_path.glob("slide_*.png"))
            return len(png_files) > 0
        
        def convert_pptx_to_pdf(self, pptx_file, output_dir):
            logger.info(f"  Converting PPTX to PDF...")
            cmd = ["libreoffice", "--headless", "--convert-to", "pdf", "--outdir", str(output_dir), str(pptx_file)]
            subprocess.run(cmd, check=True, timeout=120)
            generated_pdf = output_dir / f"{pptx_file.stem}.pdf"
            if not generated_pdf.exists():
                raise FileNotFoundError(f"PDF not generated for {pptx_file.name}")
            return generated_pdf
        
        def convert_pdf_to_png(self, pdf_file, output_dir):
            logger.info(f"  Converting PDF pages to PNG...")
            cmd = ["convert", "-density", "150", "-quality", "90", str(pdf_file), str(output_dir / "slide_%03d.png")]
            subprocess.run(cmd, check=True, timeout=120)
            png_files = sorted(output_dir.glob("slide_*.png"))
            if not png_files:
                raise FileNotFoundError(f"No PNG files generated from {pdf_file.name}")
            return png_files
        
        def convert_pptx(self, pptx_file):
            cache_path = self.get_cache_path(pptx_file)
            cache_path.mkdir(parents=True, exist_ok=True)
            logger.info(f"Converting PPTX: {pptx_file.name}")
            try:
                pdf_file = self.convert_pptx_to_pdf(pptx_file, cache_path)
                png_files = self.convert_pdf_to_png(pdf_file, cache_path)
                pdf_file.unlink()
                logger.info(f"✓ Converted {pptx_file.name}: {len(png_files)} slides")
                return png_files
            except Exception as e:
                logger.error(f"Failed to convert {pptx_file.name}: {e}")
                return []
        
        def convert_pdf(self, pdf_file):
            cache_path = self.get_cache_path(pdf_file)
            cache_path.mkdir(parents=True, exist_ok=True)
            logger.info(f"Converting PDF: {pdf_file.name}")
            try:
                png_files = self.convert_pdf_to_png(pdf_file, cache_path)
                logger.info(f"✓ Converted {pdf_file.name}: {len(png_files)} slides")
                return png_files
            except Exception as e:
                logger.error(f"Failed to convert {pdf_file.name}: {e}")
                return []
        
        def convert_presentation(self, presentation_file):
            ext = presentation_file.suffix.lower()
            if ext in PPT_FORMATS:
                return self.convert_pptx(presentation_file)
            elif ext in PDF_FORMATS:
                return self.convert_pdf(presentation_file)
            else:
                logger.error(f"Unsupported format: {ext}")
                return []
        
        def get_slides(self, presentation_file):
            if not self.is_cached(presentation_file):
                self.convert_presentation(presentation_file)
            cache_path = self.get_cache_path(presentation_file)
            return sorted(cache_path.glob("slide_*.png"))

    class SmartPlaylistPlayer:
        def __init__(self):
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
            self.presentation_converter = PresentationConverter(SLIDES_CACHE_DIR)
        
        def get_video_files(self):
            files = []
            for ext in VIDEO_FORMATS:
                files.extend(self.videos_dir.glob(f"*{ext}"))
                files.extend(self.videos_dir.glob(f"*{ext.upper()}"))
            return sorted(files)
        
        def get_presentation_files(self):
            files = []
            for ext in PPT_FORMATS + PDF_FORMATS:
                files.extend(self.presentations_dir.glob(f"*{ext}"))
                files.extend(self.presentations_dir.glob(f"*{ext.upper()}"))
            return sorted(files)
        
        def build_playlist_items(self):
            playlist_items = []
            
            video_files = self.get_video_files()
            for video in video_files:
                playlist_items.append({'type': 'video', 'path': video, 'duration': -1})
            logger.info(f"Added {len(video_files)} videos to playlist")
            
            presentation_files = self.get_presentation_files()
            total_slides = 0
            for presentation_file in presentation_files:
                slides = self.presentation_converter.get_slides(presentation_file)
                for slide in slides:
                    playlist_items.append({'type': 'slide', 'path': slide, 'duration': SLIDE_DURATION})
                    total_slides += 1
            logger.info(f"Added {len(presentation_files)} presentations ({total_slides} slides) to playlist")
            
            return playlist_items
        
        def create_playlist(self, items):
            with open(PLAYLIST_FILE, 'w') as f:
                f.write("#EXTM3U\n")
                for item in items:
                    if item['type'] == 'video':
                        f.write(f"#EXTINF:-1,{item['path'].name}\n")
                    else:
                        f.write(f"#EXTINF:{item['duration']},{item['path'].name}\n")
                    f.write(f"{item['path']}\n")
            logger.info(f"✓ Created playlist with {len(items)} items")
        
        def get_playlist_hash(self, items):
            return hash(tuple(str(item['path']) for item in items))
        
        def start_vlc(self):
            cmd = ["cvlc", "--fullscreen", "--no-video-title-show", "--no-osd", "--no-video-deco", 
                "--video-on-top", "--no-interact", "--play-and-exit", 
                "--image-duration", str(SLIDE_DURATION), PLAYLIST_FILE]
            logger.info("▶ Starting VLC...")
            self.vlc_process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        
        def is_vlc_running(self):
            if not self.vlc_process:
                return False
            return self.vlc_process.poll() is None
        
        def stop_vlc(self):
            if self.vlc_process and self.vlc_process.poll() is None:
                self.vlc_process.terminate()
                try:
                    self.vlc_process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.vlc_process.kill()
                self.vlc_process = None
        
        def run(self):
            logger.info("🎬 Starting playlist player with PPTX & PDF support...")
            logger.info(f"📹 Videos from: {VIDEOS_DIR}")
            logger.info(f"📊 Presentations from: {PRESENTATIONS_DIR} (PPTX & PDF)")
            logger.info(f"⏱️  Checking for updates every {CHECK_INTERVAL} seconds")
            
            while True:
                try:
                    playlist_items = self.build_playlist_items()
                    
                    if not playlist_items:
                        logger.warning("⚠️  No content found. Waiting...")
                        self.stop_vlc()
                        time.sleep(10)
                        continue
                    
                    playlist_hash = self.get_playlist_hash(playlist_items)
                    
                    if playlist_hash != self.current_playlist_hash:
                        if not self.is_vlc_running():
                            logger.info(f"✓ Updating playlist: {len(playlist_items)} items")
                            self.create_playlist(playlist_items)
                            self.current_playlist_hash = playlist_hash
                            self.start_vlc()
                            self.pending_update = False
                        else:
                            if not self.pending_update:
                                logger.info(f"⏳ Changes detected - will update after current playlist")
                                self.pending_update = True
                    
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
    PLAYER_EOF

    chmod +x "$BASE_DIR/player.py"
    echo "✓ player.py created"

    # Step 5: Create dashboard.py
    echo ""
    echo "→ Step 5/11: Creating dashboard.py..."
    cat > "$BASE_DIR/dashboard.py" << 'DASHBOARD_EOF'
    #!/usr/bin/env python3
    """
    Digital Signage Web Dashboard
    """

    from flask import Flask, render_template, request, redirect, url_for, flash, session
    from werkzeug.utils import secure_filename
    from werkzeug.security import check_password_hash, generate_password_hash
    from functools import wraps
    import os
    from pathlib import Path
    import logging
    import time
    import shutil  # NEW: For cache deletion

    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s'
    )
    logger = logging.getLogger(__name__)

    app = Flask(__name__)
    app.secret_key = 'change-this-secret-key-12345'

    app.config['MAX_CONTENT_LENGTH'] = 2 * 1024 * 1024 * 1024  # 2GB
    app.config['SEND_FILE_MAX_AGE_DEFAULT'] = 0

    VIDEOS_DIR = Path.home() / 'signage' / 'content' / 'videos'
    PRESENTATIONS_DIR = Path.home() / 'signage' / 'content' / 'presentations'
    CACHE_DIR = Path.home() / 'signage' / 'cache' / 'slides'  # NEW: Cache directory
    ALLOWED_VIDEO_EXTENSIONS = {'.mp4', '.avi', '.mov', '.mkv', '.webm'}
    ALLOWED_PPT_EXTENSIONS = {'.pptx', '.ppt', '.pdf'}

    USERS = {'admin': generate_password_hash('signage')}

    def allowed_file(filename, allowed_extensions):
        return Path(filename).suffix.lower() in allowed_extensions

    def login_required(f):
        @wraps(f)
        def decorated_function(*args, **kwargs):
            if 'username' not in session:
                return redirect(url_for('login'))
            return f(*args, **kwargs)
        return decorated_function

    def get_file_size(filepath):
        size = filepath.stat().st_size
        for unit in ['B', 'KB', 'MB', 'GB']:
            if size < 1024.0:
                return f"{size:.1f} {unit}"
            size /= 1024.0
        return f"{size:.1f} TB"

    def get_file_format(filepath):
        ext = filepath.suffix.lower()
        if ext == '.pdf':
            return 'PDF'
        elif ext in ['.pptx', '.ppt']:
            return 'PPTX'
        elif ext in ['.mp4', '.avi', '.mov', '.mkv', '.webm']:
            return 'VIDEO'
        return 'UNKNOWN'

    # NEW: Helper function to get cache size
    def get_cache_size(presentation_name):
        """Get size of cached slides for a presentation"""
        cache_path = CACHE_DIR / Path(presentation_name).stem
        if cache_path.exists() and cache_path.is_dir():
            total_size = sum(f.stat().st_size for f in cache_path.rglob('*') if f.is_file())
            return get_file_size_from_bytes(total_size)
        return "0 B"

    def get_file_size_from_bytes(size):
        """Convert bytes to human readable size"""
        for unit in ['B', 'KB', 'MB', 'GB']:
            if size < 1024.0:
                return f"{size:.1f} {unit}"
            size /= 1024.0
        return f"{size:.1f} TB"

    @app.route('/')
    def index():
        if 'username' in session:
            return redirect(url_for('dashboard'))
        return redirect(url_for('login'))

    @app.route('/login', methods=['GET', 'POST'])
    def login():
        if request.method == 'POST':
            username = request.form.get('username')
            password = request.form.get('password')
            if username in USERS and check_password_hash(USERS[username], password):
                session['username'] = username
                flash('Login successful!', 'success')
                return redirect(url_for('dashboard'))
            else:
                flash('Invalid credentials', 'error')
        return render_template('login.html')

    @app.route('/logout')
    def logout():
        session.pop('username', None)
        flash('Logged out', 'success')
        return redirect(url_for('login'))

    @app.route('/dashboard')
    @login_required
    def dashboard():
        videos = []
        presentations = []
        
        try:
            VIDEOS_DIR.mkdir(parents=True, exist_ok=True)
            PRESENTATIONS_DIR.mkdir(parents=True, exist_ok=True)
            
            if VIDEOS_DIR.exists():
                for file in sorted(VIDEOS_DIR.iterdir()):
                    if file.is_file() and file.suffix.lower() in ALLOWED_VIDEO_EXTENSIONS:
                        videos.append({
                            'name': file.name,
                            'size': get_file_size(file),
                            'type': 'video',
                            'format': get_file_format(file)
                        })
            
            if PRESENTATIONS_DIR.exists():
                for file in sorted(PRESENTATIONS_DIR.iterdir()):
                    if file.is_file() and file.suffix.lower() in ALLOWED_PPT_EXTENSIONS:
                        presentations.append({
                            'name': file.name,
                            'size': get_file_size(file),
                            'type': 'presentation',
                            'format': get_file_format(file)
                        })
            
        except Exception as e:
            logger.error(f"Error loading dashboard: {e}", exc_info=True)
            flash('Error loading files', 'error')
        
        return render_template('dashboard.html', 
                            videos=videos, 
                            presentations=presentations, 
                            username=session.get('username'))

    @app.route('/upload/<content_type>', methods=['POST'])
    @login_required
    def upload_file(content_type):
        start_time = time.time()
        
        try:
            logger.info(f"Upload started for {content_type}")
            
            if 'file' not in request.files:
                flash('No file selected', 'error')
                return redirect(url_for('dashboard'))
            
            file = request.files['file']
            
            if file.filename == '':
                flash('No file selected', 'error')
                return redirect(url_for('dashboard'))
            
            if content_type == 'video':
                target_dir = VIDEOS_DIR
                allowed_ext = ALLOWED_VIDEO_EXTENSIONS
            elif content_type == 'presentation':
                target_dir = PRESENTATIONS_DIR
                allowed_ext = ALLOWED_PPT_EXTENSIONS
            else:
                flash('Invalid content type', 'error')
                return redirect(url_for('dashboard'))
            
            file_ext = Path(file.filename).suffix.lower()
            if file_ext not in allowed_ext:
                flash(f'Invalid file type. Allowed: {", ".join(allowed_ext)}', 'error')
                return redirect(url_for('dashboard'))
            
            filename = secure_filename(file.filename)
            filepath = target_dir / filename
            
            # NEW: If presentation exists, delete old cache first
            if content_type == 'presentation' and filepath.exists():
                cache_path = CACHE_DIR / filepath.stem
                if cache_path.exists():
                    shutil.rmtree(cache_path)
                    logger.info(f"Deleted old cache for: {filename}")
            
            target_dir.mkdir(parents=True, exist_ok=True)
            
            logger.info(f"Saving {filename}...")
            file.save(str(filepath))
            
            if filepath.exists():
                elapsed = time.time() - start_time
                file_size = get_file_size(filepath)
                flash(f'✓ Uploaded: {filename} ({file_size}) in {elapsed:.1f}s', 'success')
                logger.info(f"Upload complete: {filename} ({file_size}) in {elapsed:.1f}s")
            else:
                flash('Upload failed: File not saved', 'error')
                logger.error(f"File not found after save: {filepath}")
            
        except Exception as e:
            elapsed = time.time() - start_time
            flash(f'Upload failed after {elapsed:.1f}s: {str(e)}', 'error')
            logger.error(f"Upload error after {elapsed:.1f}s: {e}", exc_info=True)
        
        return redirect(url_for('dashboard'))

    @app.route('/delete/<content_type>/<filename>', methods=['POST'])
    @login_required
    def delete_file(content_type, filename):
        try:
            source_dir = VIDEOS_DIR if content_type == 'video' else PRESENTATIONS_DIR
            filepath = source_dir / filename
            
            if filepath.exists() and filepath.is_file():
                # NEW: Delete cache folder for presentations
                if content_type == 'presentation':
                    cache_path = CACHE_DIR / filepath.stem
                    if cache_path.exists() and cache_path.is_dir():
                        try:
                            shutil.rmtree(cache_path)
                            logger.info(f"✓ Deleted cache folder: {cache_path.name}")
                        except Exception as cache_error:
                            logger.warning(f"Failed to delete cache: {cache_error}")
                
                # Delete the file
                filepath.unlink()
                flash(f'✓ Deleted: {filename}', 'success')
                logger.info(f"Deleted {content_type}: {filename}")
            else:
                flash(f'File not found: {filename}', 'error')
                
        except Exception as e:
            flash(f'Delete failed: {str(e)}', 'error')
            logger.error(f"Delete error: {e}", exc_info=True)
        
        return redirect(url_for('dashboard'))

    @app.errorhandler(413)
    def too_large(e):
        flash('File too large! Maximum: 2GB', 'error')
        return redirect(url_for('dashboard'))

    @app.errorhandler(500)
    def internal_error(e):
        flash('Internal error. Check logs.', 'error')
        logger.error(f"Internal error: {e}", exc_info=True)
        return redirect(url_for('dashboard'))

    if __name__ == '__main__':
        VIDEOS_DIR.mkdir(parents=True, exist_ok=True)
        PRESENTATIONS_DIR.mkdir(parents=True, exist_ok=True)
        
        logger.info("=" * 60)
        logger.info("Starting Dashboard...")
        logger.info(f"Max upload: 2GB")
        logger.info("=" * 60)
        
        app.run(host='0.0.0.0', port=5000, debug=False)
    DASHBOARD_EOF

    chmod +x "$BASE_DIR/dashboard.py"
    echo "✓ dashboard.py created"

    # Step 6: Create web_player.py (NEW - FOR NETWORK TVs)
    echo ""
    echo "→ Step 6/11: Creating web_player.py for network TVs..."
    cat > "$BASE_DIR/web_player.py" << 'WEBPLAYER_EOF'
    #!/usr/bin/env python3
    """
    Digital Signage Web Player
    - Serves content as web app for network TVs
    - Multiple TVs can connect simultaneously
    - Auto-refresh when content changes
    """

    from flask import Flask, render_template, send_from_directory, jsonify
    from pathlib import Path
    import logging
    import json
    import hashlib

    logging.basicConfig(level=logging.INFO)
    logger = logging.getLogger(__name__)

    app = Flask(__name__)

    VIDEOS_DIR = Path.home() / 'signage' / 'content' / 'videos'
    PRESENTATIONS_DIR = Path.home() / 'signage' / 'content' / 'presentations'
    SLIDES_CACHE_DIR = Path.home() / 'signage' / 'cache' / 'slides'
    VIDEO_FORMATS = ['.mp4', '.avi', '.mov', '.mkv', '.webm']
    SLIDE_DURATION = 10

    def get_video_files():
        files = []
        if VIDEOS_DIR.exists():
            for ext in VIDEO_FORMATS:
                files.extend(VIDEOS_DIR.glob(f"*{ext}"))
                files.extend(VIDEOS_DIR.glob(f"*{ext.upper()}"))
        return sorted(files)

    def get_slide_files():
        slides = []
        if SLIDES_CACHE_DIR.exists():
            for presentation_dir in sorted(SLIDES_CACHE_DIR.iterdir()):
                if presentation_dir.is_dir():
                    slides.extend(sorted(presentation_dir.glob("slide_*.png")))
        return slides

    def get_playlist():
        playlist = []
        
        for video in get_video_files():
            playlist.append({
                'type': 'video',
                'url': f'/content/videos/{video.name}',
                'name': video.name
            })
        
        for slide in get_slide_files():
            relative_path = slide.relative_to(SLIDES_CACHE_DIR)
            playlist.append({
                'type': 'image',
                'url': f'/content/slides/{relative_path}',
                'name': slide.name,
                'duration': SLIDE_DURATION
            })
        
        return playlist

    def get_playlist_hash():
        playlist = get_playlist()
        playlist_str = json.dumps(playlist, sort_keys=True)
        return hashlib.md5(playlist_str.encode()).hexdigest()

    @app.route('/')
    def player():
        return render_template('web_player.html')

    @app.route('/api/playlist')
    def api_playlist():
        return jsonify({
            'playlist': get_playlist(),
            'hash': get_playlist_hash()
        })

    @app.route('/content/videos/<path:filename>')
    def serve_video(filename):
        return send_from_directory(VIDEOS_DIR, filename)

    @app.route('/content/slides/<path:filename>')
    def serve_slide(filename):
        return send_from_directory(SLIDES_CACHE_DIR, filename)

    if __name__ == '__main__':
        logger.info("=" * 60)
        logger.info("Starting Web Player for Network TVs")
        logger.info("TVs should open: http://<pi-ip>:8080")
        logger.info("=" * 60)
        
        app.run(host='0.0.0.0', port=8080, debug=False)
    WEBPLAYER_EOF

    chmod +x "$BASE_DIR/web_player.py"
    echo "✓ web_player.py created"

    # Step 7: Create HTML templates
    echo ""
    echo "→ Step 7/11: Creating HTML templates..."

    # login.html
    cat > "$BASE_DIR/templates/login.html" << 'LOGIN_EOF'
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Login - Digital Signage</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                min-height: 100vh;
                display: flex;
                align-items: center;
                justify-content: center;
            }
            .login-container {
                background: white;
                padding: 40px;
                border-radius: 12px;
                box-shadow: 0 10px 40px rgba(0,0,0,0.2);
                width: 100%;
                max-width: 400px;
            }
            h1 { text-align: center; color: #333; margin-bottom: 30px; font-size: 2em; }
            .form-group { margin-bottom: 20px; }
            label { display: block; margin-bottom: 5px; color: #555; font-weight: 500; }
            input {
                width: 100%;
                padding: 12px;
                border: 2px solid #ddd;
                border-radius: 8px;
                font-size: 1em;
            }
            input:focus { outline: none; border-color: #667eea; }
            button {
                width: 100%;
                padding: 12px;
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                color: white;
                border: none;
                border-radius: 8px;
                font-size: 1em;
                font-weight: bold;
                cursor: pointer;
            }
            .flash { padding: 12px; border-radius: 8px; margin-bottom: 20px; text-align: center; }
            .flash.error { background: #fee; color: #c00; border: 1px solid #fcc; }
            .flash.success { background: #efe; color: #0a0; border: 1px solid #cfc; }
        </style>
    </head>
    <body>
        <div class="login-container">
            <h1>🖥️ Digital Signage</h1>
            {% with messages = get_flashed_messages(with_categories=true) %}
                {% if messages %}
                    {% for category, message in messages %}
                        <div class="flash {{ category }}">{{ message }}</div>
                    {% endfor %}
                {% endif %}
            {% endwith %}
            <form method="POST">
                <div class="form-group">
                    <label for="username">Username</label>
                    <input type="text" id="username" name="username" required autofocus>
                </div>
                <div class="form-group">
                    <label for="password">Password</label>
                    <input type="password" id="password" name="password" required>
                </div>
                <button type="submit">Login</button>
            </form>
        </div>
    </body>
    </html>
    LOGIN_EOF

    # dashboard.html (using the corrected version with PDF support)
    cat > "$BASE_DIR/templates/dashboard.html" << 'DASH_EOF'
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Dashboard - Digital Signage</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                min-height: 100vh;
                padding: 20px;
            }
            .container {
                max-width: 1200px;
                margin: 0 auto;
                background: white;
                border-radius: 12px;
                box-shadow: 0 10px 40px rgba(0,0,0,0.2);
                overflow: hidden;
            }
            header {
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                color: white;
                padding: 30px;
                display: flex;
                justify-content: space-between;
                align-items: center;
            }
            h1 { font-size: 2em; }
            .user-info { font-size: 0.9em; opacity: 0.9; }
            .logout-btn {
                background: rgba(255,255,255,0.2);
                color: white;
                border: none;
                padding: 8px 16px;
                border-radius: 6px;
                cursor: pointer;
                text-decoration: none;
                display: inline-block;
            }
            .content { padding: 30px; }
            .section { margin-bottom: 40px; }
            h2 { color: #333; margin-bottom: 20px; font-size: 1.5em; }
            .upload-form {
                background: #f5f5f5;
                padding: 20px;
                border-radius: 8px;
                margin-bottom: 20px;
            }
            .upload-form form { display: flex; gap: 10px; align-items: center; }
            input[type="file"] {
                flex: 1;
                padding: 10px;
                border: 2px dashed #667eea;
                border-radius: 6px;
            }
            .btn {
                padding: 10px 20px;
                border: none;
                border-radius: 6px;
                cursor: pointer;
                font-weight: bold;
                transition: all 0.2s;
            }
            .btn-primary {
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                color: white;
            }
            .btn-primary:hover { transform: translateY(-2px); }
            .btn-danger { background: #dc3545; color: white; font-size: 0.9em; padding: 6px 12px; }
            .files-list { display: grid; gap: 15px; }
            .file-item {
                background: #f9f9f9;
                padding: 15px;
                border-radius: 8px;
                display: flex;
                justify-content: space-between;
                align-items: center;
                border: 1px solid #e0e0e0;
            }
            .file-info { flex: 1; }
            .file-name { font-weight: bold; color: #333; margin-bottom: 5px; }
            .file-size { color: #666; font-size: 0.9em; }
            .file-type-badge {
                display: inline-block;
                padding: 3px 10px;
                border-radius: 4px;
                font-size: 0.7em;
                font-weight: bold;
                margin-left: 8px;
            }
            .badge-pptx { background: #ff6b35; color: white; }
            .badge-pdf { background: #d32f2f; color: white; }
            .flash { padding: 15px; border-radius: 8px; margin-bottom: 20px; }
            .flash.error { background: #fee; color: #c00; border: 1px solid #fcc; }
            .flash.success { background: #efe; color: #0a0; border: 1px solid #cfc; }
            .empty-state { text-align: center; padding: 40px; color: #999; }
        </style>
    </head>
    <body>
        <div class="container">
            <header>
                <div>
                    <h1>🖥️ Digital Signage Dashboard</h1>
                    <div class="user-info">Logged in as: {{ username }}</div>
                </div>
                <a href="{{ url_for('logout') }}" class="logout-btn">Logout</a>
            </header>
            <div class="content">
                {% with messages = get_flashed_messages(with_categories=true) %}
                    {% if messages %}
                        {% for category, message in messages %}
                            <div class="flash {{ category }}">{{ message }}</div>
                        {% endfor %}
                    {% endif %}
                {% endwith %}
                <div class="section">
                    <h2>📹 Videos</h2>
                    <div class="upload-form">
                        <form action="{{ url_for('upload_file', content_type='video') }}" method="POST" enctype="multipart/form-data">
                            <input type="file" name="file" accept=".mp4,.avi,.mov,.mkv,.webm" required>
                            <button type="submit" class="btn btn-primary">Upload Video</button>
                        </form>
                    </div>
                    <div class="files-list">
                        {% if videos %}
                            {% for file in videos %}
                                <div class="file-item">
                                    <div class="file-info">
                                        <div class="file-name">{{ file.name }}</div>
                                        <div class="file-size">{{ file.size }}</div>
                                    </div>
                                    <form action="{{ url_for('delete_file', content_type='video', filename=file.name) }}" method="POST" onsubmit="return confirm('Delete {{ file.name }}?')">
                                        <button type="submit" class="btn btn-danger">Delete</button>
                                    </form>
                                </div>
                            {% endfor %}
                        {% else %}
                            <div class="empty-state">No videos uploaded yet</div>
                        {% endif %}
                    </div>
                </div>
                <div class="section">
                    <h2>📊 Presentations</h2>
                    <div class="upload-form">
                        <form action="{{ url_for('upload_file', content_type='presentation') }}" method="POST" enctype="multipart/form-data">
                            <input type="file" name="file" accept=".pptx,.ppt,.pdf" required>
                            <button type="submit" class="btn btn-primary">Upload Presentation (PPTX/PDF)</button>
                        </form>
                    </div>
                    <div class="files-list">
                        {% if presentations %}
                            {% for file in presentations %}
                                <div class="file-item">
                                    <div class="file-info">
                                        <div class="file-name">
                                            {{ file.name }}
                                            {% if file.format %}
                                                <span class="file-type-badge badge-{{ file.format|lower }}">{{ file.format }}</span>
                                            {% endif %}
                                        </div>
                                        <div class="file-size">{{ file.size }}</div>
                                    </div>
                                    <form action="{{ url_for('delete_file', content_type='presentation', filename=file.name) }}" method="POST" onsubmit="return confirm('Delete {{ file.name }}?')">
                                        <button type="submit" class="btn btn-danger">Delete</button>
                                    </form>
                                </div>
                            {% endfor %}
                        {% else %}
                            <div class="empty-state">No presentations uploaded yet</div>
                        {% endif %}
                    </div>
                </div>
            </div>
        </div>
    </body>
    </html>
    DASH_EOF

    # web_player.html (NEW - Fullscreen player for TVs)
    cat > "$BASE_DIR/templates/web_player.html" << 'WEBPLAYER_HTML_EOF'
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Digital Signage Player</title>
        <style>
            * {
                margin: 0;
                padding: 0;
                box-sizing: border-box;
                cursor: none;
            }
            
            body {
                background: #000;
                overflow: hidden;
                font-family: Arial, sans-serif;
            }
            
            #player-container {
                position: fixed;
                top: 0;
                left: 0;
                width: 100vw;
                height: 100vh;
                display: flex;
                align-items: center;
                justify-content: center;
            }
            
            video, img {
                position: absolute;
                top: 0;
                left: 0;
                width: 100%;
                height: 100%;
                object-fit: cover;
            }
            
            .hidden {
                display: none !important;
            }
            
            #loading {
                color: white;
                font-size: 2em;
                text-align: center;
                position: relative;
                z-index: 10;
            }
            
            #fullscreen-prompt {
                position: fixed;
                top: 50%;
                left: 50%;
                transform: translate(-50%, -50%);
                background: rgba(0,0,0,0.9);
                color: white;
                padding: 40px;
                border-radius: 10px;
                text-align: center;
                font-size: 1.5em;
                z-index: 1000;
            }
            
            #fullscreen-prompt button {
                margin-top: 20px;
                padding: 15px 30px;
                font-size: 1.2em;
                background: #667eea;
                color: white;
                border: none;
                border-radius: 8px;
                cursor: pointer;
            }
            
            #fullscreen-prompt button:hover {
                background: #5568d3;
            }
            
            #resolution-info {
                position: fixed;
                top: 10px;
                left: 10px;
                background: rgba(0,0,0,0.7);
                color: white;
                padding: 10px;
                border-radius: 5px;
                font-size: 0.8em;
                display: none;
                z-index: 100;
            }
            
            #status {
                position: fixed;
                bottom: 10px;
                right: 10px;
                background: rgba(0,0,0,0.7);
                color: white;
                padding: 10px;
                border-radius: 5px;
                font-size: 0.8em;
                display: none;
                cursor: pointer;
                z-index: 100;
            }
        </style>
    </head>
    <body>
        <div id="fullscreen-prompt">
            <div>Click to Start Fullscreen Player</div>
            <button id="fullscreen-btn">Enter Fullscreen</button>
        </div>
        
        <div id="player-container">
            <div id="loading" class="hidden">Loading content...</div>
            <video id="video-player" class="hidden" autoplay></video>
            <img id="image-player" class="hidden">
        </div>
        
        <div id="resolution-info">
            <div>Screen: <span id="screen-res">-</span></div>
            <div>Player: <span id="player-res">-</span></div>
            <div>Mode: cover</div>
        </div>
        
        <div id="status">
            <div>Items: <span id="item-count">0</span></div>
            <div>Current: <span id="current-item">-</span></div>
        </div>

        <script>
            let playlist = [];
            let currentIndex = 0;
            let playlistHash = null;
            let isPlaying = false;  // NEW: Track if content is playing
            const CHECK_INTERVAL = 10000;
            
            const videoPlayer = document.getElementById('video-player');
            const imagePlayer = document.getElementById('image-player');
            const loading = document.getElementById('loading');
            const status = document.getElementById('status');
            const resolutionInfo = document.getElementById('resolution-info');
            const fullscreenPrompt = document.getElementById('fullscreen-prompt');
            const fullscreenBtn = document.getElementById('fullscreen-btn');
            
            function updateResolutionInfo() {
                document.getElementById('screen-res').textContent = 
                    `${window.screen.width}x${window.screen.height}`;
                document.getElementById('player-res').textContent = 
                    `${window.innerWidth}x${window.innerHeight}`;
            }
            
            function enterFullscreen() {
                const elem = document.documentElement;
                
                if (elem.requestFullscreen) {
                    elem.requestFullscreen();
                } else if (elem.webkitRequestFullscreen) {
                    elem.webkitRequestFullscreen();
                } else if (elem.msRequestFullscreen) {
                    elem.msRequestFullscreen();
                }
                
                fullscreenPrompt.classList.add('hidden');
                
                // BUG FIX: Only show loading if not already playing
                if (!isPlaying) {
                    loading.classList.remove('hidden');
                    fetchPlaylist();
                }
                
                setTimeout(updateResolutionInfo, 500);
            }
            
            fullscreenBtn.addEventListener('click', enterFullscreen);
            
            fullscreenPrompt.addEventListener('click', (e) => {
                if (e.target !== fullscreenBtn) {
                    enterFullscreen();
                }
            });
            
            document.addEventListener('fullscreenchange', () => {
                if (!document.fullscreenElement) {
                    // User exited fullscreen
                    setTimeout(() => {
                        fullscreenPrompt.classList.remove('hidden');
                    }, 1000);
                } else {
                    // Entered fullscreen
                    updateResolutionInfo();
                }
            });
            
            window.addEventListener('resize', updateResolutionInfo);
            
            async function fetchPlaylist() {
                try {
                    const response = await fetch('/api/playlist');
                    const data = await response.json();
                    
                    if (data.hash !== playlistHash) {
                        console.log('Playlist updated');
                        playlist = data.playlist;
                        playlistHash = data.hash;
                        
                        if (playlist.length > 0) {
                            // BUG FIX: Hide loading before starting playback
                            loading.classList.add('hidden');
                            currentIndex = 0;
                            playNext();
                        } else {
                            // Show loading only if no content
                            loading.classList.remove('hidden');
                            loading.textContent = 'No content available';
                            isPlaying = false;  // NEW: Mark as not playing
                        }
                    } else if (playlist.length > 0 && !isPlaying) {
                        // BUG FIX: If playlist exists but not playing, start playback
                        loading.classList.add('hidden');
                        playNext();
                    }
                    
                    updateStatus();
                    
                } catch (error) {
                    console.error('Error fetching playlist:', error);
                    loading.classList.remove('hidden');
                    loading.textContent = 'Connection error';
                    isPlaying = false;  // NEW: Mark as not playing
                }
            }
            
            function playNext() {
                if (playlist.length === 0) {
                    loading.classList.remove('hidden');
                    loading.textContent = 'No content available';
                    isPlaying = false;  // NEW: Mark as not playing
                    return;
                }
                
                // BUG FIX: Ensure loading is hidden when playing
                loading.classList.add('hidden');
                isPlaying = true;  // NEW: Mark as playing
                
                const item = playlist[currentIndex];
                console.log('Playing:', item.name);
                
                if (item.type === 'video') {
                    playVideo(item);
                } else if (item.type === 'image') {
                    playImage(item);
                }
                
                currentIndex = (currentIndex + 1) % playlist.length;
                updateStatus();
            }
            
            function playVideo(item) {
                imagePlayer.classList.add('hidden');
                videoPlayer.classList.remove('hidden');
                videoPlayer.src = item.url;
                videoPlayer.play().catch(err => {
                    console.error('Video play error:', err);
                    playNext();
                });
            }
            
            function playImage(item) {
                videoPlayer.classList.add('hidden');
                imagePlayer.classList.remove('hidden');
                imagePlayer.src = item.url;
                
                setTimeout(() => {
                    playNext();
                }, item.duration * 1000);
            }
            
            function updateStatus() {
                document.getElementById('item-count').textContent = playlist.length;
                if (playlist.length > 0) {
                    document.getElementById('current-item').textContent = 
                        `${currentIndex + 1}/${playlist.length} - ${playlist[currentIndex]?.name || 'Loading...'}`;
                }
            }
            
            videoPlayer.addEventListener('ended', () => {
                playNext();
            });
            
            videoPlayer.addEventListener('error', (e) => {
                console.error('Video error:', e);
                playNext();
            });
            
            imagePlayer.addEventListener('error', (e) => {
                console.error('Image error:', e);
                playNext();
            });
            
            // BUG FIX: Fetch playlist immediately on page load
            fetchPlaylist();
            
            // Continue checking for updates
            setInterval(fetchPlaylist, CHECK_INTERVAL);
            
            // Triple-click to toggle debug info
            let clickCount = 0;
            let clickTimer = null;
            document.addEventListener('click', () => {
                clickCount++;
                if (clickTimer) clearTimeout(clickTimer);
                
                clickTimer = setTimeout(() => {
                    if (clickCount >= 3) {
                        const currentDisplay = status.style.display;
                        const newDisplay = currentDisplay === 'none' ? 'block' : 'none';
                        status.style.display = newDisplay;
                        resolutionInfo.style.display = newDisplay;
                        
                        if (newDisplay === 'block') {
                            updateResolutionInfo();
                        }
                    }
                    clickCount = 0;
                }, 500);
            });
            
            document.addEventListener('contextmenu', (e) => e.preventDefault());
            
            updateResolutionInfo();
        </script>
    </body>
    </html>
    WEBPLAYER_HTML_EOF

    echo "✓ HTML templates created"

    # Step 8: Configure FTP/SFTP
    echo ""
    echo "→ Step 8/11: Configuring file access..."
    if systemctl is-active --quiet vsftpd; then
        sudo tee /etc/vsftpd.conf > /dev/null <<EOF
    listen=YES
    anonymous_enable=NO
    local_enable=YES
    write_enable=YES
    local_umask=022
    dirmessage_enable=YES
    use_localtime=YES
    xferlog_enable=YES
    connect_from_port_20=YES
    secure_chroot_dir=/var/run/vsftpd/empty
    pam_service_name=vsftpd
    EOF
        sudo systemctl restart vsftpd
        sudo systemctl enable vsftpd
        echo "✓ FTP configured"
    else
        echo "  ℹ️  Using SFTP (available via SSH)"
    fi

    # Step 9: Create systemd services
    echo ""
    echo "→ Step 9/11: Creating systemd services..."

    # Player service
    sudo tee /etc/systemd/system/signage-player.service > /dev/null <<EOF
    [Unit]
    Description=Digital Signage Player
    After=graphical.target

    [Service]
    Type=simple
    User=$USER
    Environment="DISPLAY=:0"
    Environment="XAUTHORITY=$HOME/.Xauthority"
    WorkingDirectory=$BASE_DIR
    ExecStart=$BASE_DIR/venv/bin/python $BASE_DIR/player.py
    Restart=always
    RestartSec=10

    [Install]
    WantedBy=graphical.target
    EOF

    # Dashboard service (WITH TIMEOUT FIX)
    sudo tee /etc/systemd/system/signage-dashboard.service > /dev/null <<EOF
    [Unit]
    Description=Digital Signage Web Dashboard
    After=network.target

    [Service]
    Type=simple
    User=$USER
    Environment="PYTHONUNBUFFERED=1"
    WorkingDirectory=$BASE_DIR
    ExecStart=$BASE_DIR/venv/bin/gunicorn -w 2 -b 0.0.0.0:5000 --timeout 300 --graceful-timeout 300 --keep-alive 5 dashboard:app
    Restart=always
    RestartSec=10

    [Install]
    WantedBy=multi-user.target
    EOF

    # Web Player service (NEW - FOR NETWORK TVs)
    sudo tee /etc/systemd/system/signage-web-player.service > /dev/null <<EOF
    [Unit]
    Description=Digital Signage Web Player for Network TVs
    After=network.target

    [Service]
    Type=simple
    User=$USER
    Environment="PYTHONUNBUFFERED=1"
    WorkingDirectory=$BASE_DIR
    ExecStart=$BASE_DIR/venv/bin/gunicorn -w 2 -b 0.0.0.0:8080 --timeout 120 web_player:app
    Restart=always
    RestartSec=10

    [Install]
    WantedBy=multi-user.target
    EOF

    sudo systemctl daemon-reload
    echo "✓ Systemd services created"

    # Step 10: Enable and start services
    echo ""
    echo "→ Step 10/11: Enabling auto-start..."
    sudo systemctl enable signage-player
    sudo systemctl enable signage-dashboard
    sudo systemctl enable signage-web-player

    echo "✓ Auto-start enabled"

    # Step 11: Start services
    echo ""
    echo "→ Step 11/11: Starting services..."
    sudo systemctl start signage-dashboard
    sudo systemctl start signage-web-player

    sleep 3

    if curl -s http://localhost:5000 > /dev/null; then
        echo "✓ Dashboard started successfully"
    else
        echo "  ⚠️  Dashboard may take a moment to start"
    fi

    if curl -s http://localhost:8080 > /dev/null; then
        echo "✓ Web Player started successfully"
    else
        echo "  ⚠️  Web Player may take a moment to start"
    fi

    sudo systemctl start signage-player
    echo "✓ Player started"

    # Summary
    echo ""
    echo "=========================================="
    echo "✅ Setup Complete!"
    echo "=========================================="
    echo ""
    echo "📁 Installation: $BASE_DIR"
    echo ""
    echo "📂 Folder Structure:"
    echo "  $BASE_DIR/content/videos/       ← Put videos here"
    echo "  $BASE_DIR/content/presentations/ ← Put PPTX/PDF here"
    echo "  $BASE_DIR/cache/slides/          ← Converted slides cache"
    echo "  $BASE_DIR/logs/                  ← Log files"
    echo ""
    echo "🌐 Web Interfaces:"
    echo "  Admin Dashboard: http://$(hostname -I | awk '{print $1}'):5000"
    echo "    Login: admin / signage"
    echo "    Use this to upload/manage content"
    echo ""
    echo "  TV Web Player: http://$(hostname -I | awk '{print $1}'):8080"
    echo "    Open this URL on Samsung TVs or any browser"
    echo "    Click 'Enter Fullscreen' for kiosk mode"
    echo "    Supports multiple TVs simultaneously"
    echo ""
    echo "📤 Upload Files:"
    if systemctl is-active --quiet vsftpd; then
        echo "  FTP: ftp://$(hostname -I | awk '{print $1}')"
        echo "  Username: $USER"
        echo "  Password: (your system password)"
    else
        echo "  SFTP: sftp://$USER@$(hostname -I | awk '{print $1}')"
        echo "  Port: 22"
    fi
    echo "  Folder: $BASE_DIR/content/videos or presentations"
    echo ""
    echo "📊 Service Status:"
    sudo systemctl status signage-dashboard --no-pager | grep "Active:"
    sudo systemctl status signage-web-player --no-pager | grep "Active:"
    sudo systemctl status signage-player --no-pager | grep "Active:"
    echo ""
    echo "🔧 Useful Commands:"
    echo "  View dashboard logs: sudo journalctl -u signage-dashboard -f"
    echo "  View web player logs: sudo journalctl -u signage-web-player -f"
    echo "  View player logs: tail -f $BASE_DIR/logs/player.log"
    echo "  Restart dashboard: sudo systemctl restart signage-dashboard"
    echo "  Restart web player: sudo systemctl restart signage-web-player"
    echo "  Restart player: sudo systemctl restart signage-player"
    echo ""
    echo "📺 Samsung TV Setup:"
    echo "  1. Open TV browser"
    echo "  2. Navigate to: http://$(hostname -I | awk '{print $1}'):8080"
    echo "  3. Click 'Enter Fullscreen' button"
    echo "  4. (Optional) Save as homepage for auto-load"
    echo ""
    echo "✅ Everything is ready!"
    echo "  Admin: http://$(hostname -I | awk '{print $1}'):5000"
    echo "  TVs:   http://$(hostname -I | awk '{print $1}'):8080"
    echo ""

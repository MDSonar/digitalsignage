#!/bin/bash
# Digital Signage Setup with Web Dashboard - COMPLETE VERSION

echo "=========================================="
echo "Digital Signage Setup with Web Dashboard"
echo "=========================================="
echo ""

# Install required packages
echo "→ Installing packages..."
sudo apt-get update

# Install base packages including ImageMagick for PPT conversion
sudo apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    python3-full \
    feh \
    vlc \
    libreoffice \
    imagemagick

echo "✓ Core packages installed"

# Try to install vsftpd, but don't fail if it's not available
echo "→ Installing FTP server..."
if sudo apt-get install -y vsftpd; then
    echo "✓ vsftpd installed"
    
    # Configure FTP Server
    echo "→ Configuring FTP..."
    sudo tee /etc/vsftpd.conf > /dev/null <<'EOF'
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

    # Restart FTP
    sudo systemctl restart vsftpd
    sudo systemctl enable vsftpd
    echo "✓ FTP server configured"
else
    echo "⚠ vsftpd not available, will use SFTP instead"
    echo "  SFTP is already available via SSH"
fi

# Create directory structure with separate folders
echo "→ Creating directory structure..."
mkdir -p ~/signage/content/videos
mkdir -p ~/signage/content/presentations
mkdir -p ~/signage/cache/slides
mkdir -p ~/signage/logs
mkdir -p ~/signage/templates

echo "✓ Directory structure created:"
echo "  ~/signage/content/videos/ (for video files)"
echo "  ~/signage/content/presentations/ (for PPTX files)"
echo "  ~/signage/cache/slides/ (for converted slides)"
echo "  ~/signage/templates/ (for web dashboard templates)"

# Create Python virtual environment
echo "→ Setting up Python environment..."
cd ~/signage
python3 -m venv venv
source venv/bin/activate

# Install Python packages (including web dashboard dependencies)
echo "→ Installing Python packages..."
pip install --upgrade pip
pip install pillow flask flask-login werkzeug gunicorn

echo "✓ Python environment ready"

# Deactivate venv for now
deactivate

# Create player service
echo "→ Creating player service..."
sudo tee /etc/systemd/system/signage-player.service > /dev/null <<EOF
[Unit]
Description=Digital Signage Player with PPT Support
After=graphical.target

[Service]
Type=simple
User=$USER
Environment="DISPLAY=:0"
Environment="XAUTHORITY=$HOME/.Xauthority"
WorkingDirectory=$HOME/signage
ExecStart=$HOME/signage/venv/bin/python $HOME/signage/player.py
Restart=always
RestartSec=10

[Install]
WantedBy=graphical.target
EOF

echo "✓ Player service created"

# Create dashboard service
echo "→ Creating dashboard service..."
sudo tee /etc/systemd/system/signage-dashboard.service > /dev/null <<EOF
[Unit]
Description=Digital Signage Web Dashboard
After=network.target

[Service]
Type=simple
User=$USER
Environment="PYTHONUNBUFFERED=1"
WorkingDirectory=$HOME/signage
ExecStart=$HOME/signage/venv/bin/gunicorn -w 2 -b 0.0.0.0:5000 --timeout 120 dashboard:app
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

echo "✓ Dashboard service created"

# Enable services
sudo systemctl daemon-reload
sudo systemctl enable signage-player
sudo systemctl enable signage-dashboard

echo "✓ Services enabled"

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""

# Show upload instructions
if systemctl is-active --quiet vsftpd; then
    echo "📤 FTP Upload (vsftpd):"
    echo "  Server: $(hostname -I | awk '{print $1}')"
    echo "  Username: $USER"
    echo "  Password: (your pi password)"
    echo ""
else
    echo "📤 SFTP Upload (recommended):"
    echo "  Host: $(hostname -I | awk '{print $1}')"
    echo "  Port: 22"
    echo "  Username: $USER"
    echo "  Password: (your pi password)"
    echo ""
fi

echo "📁 Upload Locations:"
echo "  Videos:        ~/signage/content/videos/"
echo "  Presentations: ~/signage/content/presentations/"
echo ""
echo "🌐 Web Dashboard:"
echo "  URL: http://$(hostname -I | awk '{print $1}'):5000"
echo "  Login: admin / signage"
echo "  ⚠️  CHANGE DEFAULT PASSWORD in dashboard.py"
echo ""
echo "🚀 Start Services:"
echo "  sudo systemctl start signage-player"
echo "  sudo systemctl start signage-dashboard"
echo ""
echo "📊 Check Status:"
echo "  sudo systemctl status signage-player"
echo "  sudo systemctl status signage-dashboard"
echo ""
echo "📝 View Logs:"
echo "  tail -f ~/signage/logs/player.log"
echo "  sudo journalctl -u signage-dashboard -f"
echo ""
echo "🔧 Manual Run (for testing):"
echo "  Player:    cd ~/signage && source venv/bin/activate && python player.py"
echo "  Dashboard: cd ~/signage && source venv/bin/activate && gunicorn -w 2 -b 0.0.0.0:5000 dashboard:app"
echo ""
echo "=========================================="
echo ""
echo "⚠️  IMPORTANT NOTES:"
echo "  1. Make sure dashboard.py exists in ~/signage/"
echo "  2. Make sure player.py exists in ~/signage/"
echo "  3. Make sure templates/ folder has login.html and dashboard.html"
echo "  4. Change default dashboard password before going live"
echo ""
echo "Next steps:"
echo "  1. Create dashboard.py and templates (if not done)"
echo "  2. Start services"
echo "  3. Test web dashboard access"
echo ""

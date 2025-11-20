#!/bin/bash
# Digital Signage Setup with PPT Support - UPDATED VERSION

echo "=========================================="
echo "Digital Signage Setup with PPT Support"
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

echo "✓ Directory structure created:"
echo "  ~/signage/content/videos/ (for video files)"
echo "  ~/signage/content/presentations/ (for PPTX files)"
echo "  ~/signage/cache/slides/ (for converted slides)"

# Create Python virtual environment
echo "→ Setting up Python environment..."
cd ~/signage
python3 -m venv venv
source venv/bin/activate

# Install Python packages in venv (only Pillow needed for now)
pip install pillow

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

sudo systemctl daemon-reload
sudo systemctl enable signage-player

echo "✓ Systemd service created and enabled"

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
echo "🚀 Start Player:"
echo "  sudo systemctl start signage-player"
echo ""
echo "📊 Check Status:"
echo "  sudo systemctl status signage-player"
echo ""
echo "📝 View Logs:"
echo "  tail -f ~/signage/logs/player.log"
echo ""
echo "🔧 Manual Run (for testing):"
echo "  cd ~/signage"
echo "  source venv/bin/activate"
echo "  python player.py"
echo ""
echo "=========================================="

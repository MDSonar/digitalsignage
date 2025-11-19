#!/bin/bash
# Minimal Digital Signage Setup - FINAL FIXED VERSION

echo "=== Digital Signage Basic Setup ==="

# Install required packages
echo "Installing packages..."
sudo apt-get update

# Install base packages (omxplayer removed - deprecated in newer Pi OS)
sudo apt-get install -y python3 python3-pip python3-venv python3-full feh vlc

# Try to install vsftpd, but don't fail if it's not available
echo "Installing FTP server..."
if sudo apt-get install -y vsftpd; then
    echo "✓ vsftpd installed"
    
    # Configure FTP Server
    echo "Configuring FTP..."
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
    echo "SFTP is already available via SSH"
fi

# Create directories
echo "Creating directories..."
mkdir -p ~/signage/content
mkdir -p ~/signage/logs

# Create Python virtual environment
echo "Setting up Python environment..."
cd ~/signage
python3 -m venv venv
source venv/bin/activate

# Install Python packages in venv
pip install pillow

# Deactivate venv for now
deactivate

# Create player service
echo "Creating player service..."
sudo tee /etc/systemd/system/signage-player.service > /dev/null <<EOF
[Unit]
Description=Digital Signage Player
After=graphical.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME/signage
ExecStart=$HOME/signage/venv/bin/python $HOME/signage/player.py
Restart=always
Environment="DISPLAY=:0"

[Install]
WantedBy=graphical.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable signage-player

echo ""
echo "=== Setup Complete! ==="
echo ""
if systemctl is-active --quiet vsftpd; then
    echo "FTP Upload (vsftpd):"
    echo "  Server: $(hostname -I | awk '{print $1}')"
    echo "  Username: $USER"
    echo "  Password: (your pi password)"
    echo "  Directory: ~/signage/content"
else
    echo "SFTP Upload (use any SFTP client):"
    echo "  Host: $(hostname -I | awk '{print $1}')"
    echo "  Port: 22"
    echo "  Username: $USER"
    echo "  Password: (your pi password)"
    echo "  Directory: ~/signage/content"
fi
echo ""
echo "Add content to: ~/signage/content/"
echo ""
echo "Start player:"
echo "  sudo systemctl start signage-player"
echo ""
echo "Or run manually:"
echo "  cd ~/signage"
echo "  source venv/bin/activate"
echo "  python player.py"

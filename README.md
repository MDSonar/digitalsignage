# digitalsignage


# 1. Create files
mkdir ~/signage
cd ~/signage
nano setup.sh
# Paste the FIXED setup.sh above

nano player.py
# Paste the UPDATED player.py above

# 2. Make setup executable
chmod +x setup.sh

# 3. Run setup
./setup.sh

# 4. Add test content
cp /usr/share/pixmaps/debian-logo.png ~/signage/content/test.png

# 5. Test player manually first
cd ~/signage
source venv/bin/activate
python player.py
# Press Ctrl+C to stop

# 6. Start as service
sudo systemctl start signage-player

# 7. Check status
sudo systemctl status signage-player

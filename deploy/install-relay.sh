#!/bin/sh
# Runs ON the server (make deploy-relay copies it to /tmp and runs it). No root needed.
set -eu

mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
install -m 0755 /tmp/snapcast-relay "$HOME/.local/bin/snapcast-relay"
install -m 0644 /tmp/snapcast-relay.service "$HOME/.config/systemd/user/snapcast-relay.service"

systemctl --user daemon-reload
systemctl --user enable snapcast-relay.service >/dev/null 2>&1
systemctl --user restart snapcast-relay.service

# Without lingering, user services stop at logout and do not start at boot.
if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
  if loginctl enable-linger "$USER" 2>/dev/null; then
    echo "enabled lingering for $USER (relay now survives logout and starts at boot)"
  else
    echo "WARNING: could not enable lingering without root. Run once:"
    echo "  sudo loginctl enable-linger $USER"
    echo "Until then the relay stops when you log out and does not start at boot."
  fi
fi

sleep 1
systemctl --user --no-pager --lines=5 status snapcast-relay.service || true
rm -f /tmp/snapcast-relay /tmp/snapcast-relay.service /tmp/install-relay.sh

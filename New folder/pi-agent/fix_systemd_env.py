import os

TAILSCALE_URL = "https://cicada.tail5c4552.ts.net:8443"
LOCAL_URL = "http://127.0.0.1:11434"

# Fix /etc/systemd/system/cicada-lead-app.service
fpath = '/etc/systemd/system/cicada-lead-app.service'
with open(fpath) as f:
    c = f.read()
c = c.replace(LOCAL_URL, TAILSCALE_URL)
with open(fpath, 'w') as f:
    f.write(c)
print(f"Fixed: {fpath}")

# Fix /etc/cicada-lead-app.env
fpath = '/etc/cicada-lead-app.env'
with open(fpath) as f:
    c = f.read()
c = c.replace(LOCAL_URL, TAILSCALE_URL)
with open(fpath, 'w') as f:
    f.write(c)
print(f"Fixed: {fpath}")

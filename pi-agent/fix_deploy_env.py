TAILSCALE_URL = "https://cicada.tail5c4552.ts.net:8443"
LOCAL_URL = "http://127.0.0.1:11434"

fpath = '/home/cicadaserver/instagram-hashtag-research-tool/deploy/cicada-lead-app.env.example'
with open(fpath) as f:
    c = f.read()
c = c.replace(LOCAL_URL, TAILSCALE_URL)
with open(fpath, 'w') as f:
    f.write(c)
print(f"Fixed: {fpath}")

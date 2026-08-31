import os

TAILSCALE_URL = "https://cicada.tail5c4552.ts.net:8443"
LOCAL_URL = "http://127.0.0.1:11434"

files = [
    '/home/cicadaserver/instagram-hashtag-research-tool/.env',
    '/home/cicadaserver/instagram-hashtag-research-tool/.env.example',
    '/home/cicadaserver/instagram-hashtag-research-tool/src/config/linkClassifier.ts',
    '/home/cicadaserver/instagram-hashtag-research-tool/src/aiCommentProvider.ts',
]

for fpath in files:
    if not os.path.exists(fpath):
        print(f"SKIP (not found): {fpath}")
        continue
    with open(fpath) as f:
        c = f.read()
    if LOCAL_URL in c:
        c = c.replace(LOCAL_URL, TAILSCALE_URL)
        with open(fpath, 'w') as f:
            f.write(c)
        print(f"Fixed: {fpath}")
    else:
        print(f"Already correct or not applicable: {fpath}")

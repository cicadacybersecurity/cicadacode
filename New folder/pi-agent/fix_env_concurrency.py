import os

TAILSCALE_URL = "https://cicada.tail5c4552.ts.net:8443"

fpath = '/etc/cicada-lead-app.env'
with open(fpath) as f:
    c = f.read()

# Update concurrency to Pi-appropriate values
c = c.replace('MAX_CONCURRENT_REQUESTS=6', 'MAX_CONCURRENT_REQUESTS=2')
c = c.replace('GEMINI_MAX_CONCURRENT=3', 'GEMINI_MAX_CONCURRENT=1')
c = c.replace('GROQ_MAX_CONCURRENT=3', 'GROQ_MAX_CONCURRENT=1')

with open(fpath, 'w') as f:
    f.write(c)
print(f"Updated: {fpath}")

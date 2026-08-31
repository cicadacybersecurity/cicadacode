c = open('/home/cicadaserver/instagram-hashtag-research-tool/src/public/app.js').read()
c = c.replace(
    '"Checking Ollama and NVIDIA VRAM…"',
    '"Checking Ollama and GPU runtime…"'
)
c = c.replace(
    '"NVIDIA VRAM unavailable — nvidia-smi was not detected"',
    '"GPU info unavailable on this platform"'
)
open('/home/cicadaserver/instagram-hashtag-research-tool/src/public/app.js', 'w').write(c)
print('done')

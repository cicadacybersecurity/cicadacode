c = open('/home/cicadaserver/instagram-hashtag-research-tool/src/config/linkClassifier.ts').read()
c = c.replace(
    'const DEFAULT_OLLAMA_URL = "https://cicada.tail5c4552.ts.net:8443"',
    'const DEFAULT_OLLAMA_URL = "http://127.0.0.1:11434"'
)
open('/home/cicadaserver/instagram-hashtag-research-tool/src/config/linkClassifier.ts', 'w').write(c)
print('done')

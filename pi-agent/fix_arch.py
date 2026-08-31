c = open('/home/cicadaserver/instagram-hashtag-research-tool/src/server.ts').read()
c = c.replace('process.arch === "aarch64"', 'process.arch === "arm64"')
open('/home/cicadaserver/instagram-hashtag-research-tool/src/server.ts', 'w').write(c)
print('done')

c = open('/home/cicadaserver/instagram-hashtag-research-tool/src/server.ts').read()
idx = c.find('const runState')
print(repr(c[idx-250:idx+100]))

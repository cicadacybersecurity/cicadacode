import json
with open('/home/cicadaserver/instagram-hashtag-research-tool/package.json') as f:
    d = json.load(f)
print(json.dumps(d.get('scripts', {}), indent=2))

import os, re

src_dir = '/home/cicadaserver/instagram-hashtag-research-tool/src'
issues = []

for root, dirs, files in os.walk(src_dir):
    for fname in files:
        if not fname.endswith('.ts') and not fname.endswith('.js'):
            continue
        fpath = os.path.join(root, fname)
        try:
            with open(fpath) as f:
                content = f.read()
        except:
            continue
        # Find relative imports (both .js and .ts extensions)
        for m in re.finditer(r'''from\s+['"]((\.\.?/)[^'"]+\.js)['"]''', content):
            rel_path = m.group(1)
            base_dir = os.path.dirname(fpath)
            parts = rel_path.replace('\\', '/').split('/')
            resolved = base_dir
            for part in parts:
                if part == '..':
                    resolved = os.path.dirname(resolved)
                elif part != '.':
                    resolved = os.path.join(resolved, part)
            if not os.path.exists(resolved):
                issues.append(f"{fpath}: import '{rel_path}' -> resolved to '{resolved}' which doesn't exist")
            else:
                actual_name = os.path.basename(resolved)
                expected_name = os.path.basename(rel_path)
                if actual_name != expected_name:
                    issues.append(f"{fpath}: import '{rel_path}' has case mismatch (file is '{actual_name}')")

if issues:
    for i in issues:
        print(i)
else:
    print("All relative imports verified OK")

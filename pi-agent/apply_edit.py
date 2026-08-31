import re

path = '/home/cicadaserver/.openclaw/workspace/skills/igtocrm/scripts/igtocrm.mjs'
with open(path) as f:
    src = f.read()

old_poll = "console.log(ts(), 'poll:', url.slice(0, 70));"
new_poll = "console.log(ts(), `poll at ${Date.now() - start}ms: ${url.includes('/direct/t/') ? 'THREAD_URL' : url.includes('/direct/requests') ? 'REQUESTS_URL' : 'INBOX_OR_OTHER'}`);"
if old_poll in src:
    src = src.replace(old_poll, new_poll)
    print('Change 1 applied: poll log')
else:
    print('WARNING: old_poll not found')

old_gate = """          if (norm(opened) === target) return 'OK';
          console.log(ts(), `opened wrong thread ("${opened}"), going back to inbox`);
          await gotoInbox();
          break;"""
new_gate = """          const openedNorm = norm(opened);
          console.log(ts(), `header check attempt ${attempt}: got [${openedNorm}] want [${target}]`);
          if (openedNorm === target) return 'OK';
          const longer = openedNorm.length > target.length ? openedNorm : target;
          const shorter = openedNorm.length > target.length ? target : openedNorm;
          if (longer.length > 2 && longer.includes(shorter)) {
            console.log(ts(), `header check: partial match (contained), returning OK`);
            return 'OK';
          }
          console.log(ts(), `header mismatch, polling 600ms more`);"""
if old_gate in src:
    src = src.replace(old_gate, new_gate)
    print('Change 2 applied: header verification gate')
else:
    print('ERROR: old_gate block not found')

with open(path, 'w') as f:
    f.write(src)
print('Done')
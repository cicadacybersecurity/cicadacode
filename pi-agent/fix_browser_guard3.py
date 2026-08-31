with open('/home/cicadaserver/instagram-hashtag-research-tool/src/server.ts', 'r') as f:
    c = f.read()

# 2. Add guard + set flag for Instagram stream (accounting for blank lines in actual file)
old1 = '''  } catch (err) {
    send({ type: "error", message: (err as Error).message })
    res.end()
    return
  }


  const runState: RunState = {
    hashtag,
    maxResults,
    headless,
    startedAt: new Date().toISOString(),
    collectedHandles: [],
    results: [],
    status: "running",
  }

  let context: BrowserContext | undefined
  try {
    context = await chromium.launchPersistentContext(PROFILE_DIR, { headless })
  } catch (err) {
    runState.status = "error"
    writeRunState(runState)
    send({ type: "error", message: "Failed to launch browser: " + (err as Error).message })
    res.end()
    return
  }'''

new1 = '''  } catch (err) {
    send({ type: "error", message: (err as Error).message })
    res.end()
    return
  }

  // Pi has one Xvfb display — only one headful Chromium can run at a time.
  if (browserRunInProgress) {
    send({ type: "error", message: "A collection run is already in progress. Please wait for it to finish." })
    res.end()
    return
  }
  browserRunInProgress = true

  const runState: RunState = {
    hashtag,
    maxResults,
    headless,
    startedAt: new Date().toISOString(),
    collectedHandles: [],
    results: [],
    status: "running",
  }

  let context: BrowserContext | undefined
  try {
    context = await chromium.launchPersistentContext(PROFILE_DIR, { headless })
  } catch (err) {
    browserRunInProgress = false
    runState.status = "error"
    writeRunState(runState)
    send({ type: "error", message: "Failed to launch browser: " + (err as Error).message })
    res.end()
    return
  }'''

if old1 in c:
    c = c.replace(old1, new1)
    print("Instagram guard + flag set added")
else:
    print("WARNING: Instagram pattern not found - checking actual text")
    idx = c.find('const runState: RunState = {')
    print(f"'const runState' found at: {idx}")
    print("Context around it:")
    print(repr(c[idx-200:idx+100]))

with open('/home/cicadaserver/instagram-hashtag-research-tool/src/server.ts', 'w') as f:
    f.write(c)
print("Done")

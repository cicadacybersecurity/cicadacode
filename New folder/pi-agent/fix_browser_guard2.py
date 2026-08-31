with open('/home/cicadaserver/instagram-hashtag-research-tool/src/server.ts', 'r') as f:
    c = f.read()

# 1. Verify flag was added
if 'browserRunInProgress = false' not in c:
    print("ERROR: browserRunInProgress flag not found. Run the first patch first.")
else:
    print("Flag found OK")

# 2. Add guard + set flag for Instagram stream
# Pattern: after initDb() catch, before "const runState"
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
    print("WARNING: Instagram pattern not found")

# 3. Add flag reset to Instagram finally block
old_finally1 = '''  } finally {
    await context.close().catch(() => {})
    if (!res.writableEnded) res.end()
  }
})

app.get("/api/run/stream/maps"'''

new_finally1 = '''  } finally {
    browserRunInProgress = false
    await context.close().catch(() => {})
    if (!res.writableEnded) res.end()
  }
})

app.get("/api/run/stream/maps"'''

if old_finally1 in c:
    c = c.replace(old_finally1, new_finally1)
    print("Instagram finally block updated")
else:
    print("WARNING: Instagram finally block pattern not found")

with open('/home/cicadaserver/instagram-hashtag-research-tool/src/server.ts', 'w') as f:
    f.write(c)
print("Done")

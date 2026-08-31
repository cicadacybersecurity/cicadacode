with open('/home/cicadaserver/instagram-hashtag-research-tool/src/server.ts', 'r') as f:
    c = f.read()

# Instagram stream: add guard after initDb() catch, before const runState
# Two blank lines between catch and const runState in actual file
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
    print("ERROR: Instagram pattern not found")

# Maps stream: add guard after initMapsDb() catch, before send(log)
old_maps = '''  } catch (err) {
    send({ type: "error", message: (err as Error).message })
    res.end()
    return
  }


  send({
    type: "log",
    message:
      'Starting Maps run for "'''

new_maps = '''  } catch (err) {
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

  send({
    type: "log",
    message:
      'Starting Maps run for "'''

if old_maps in c:
    c = c.replace(old_maps, new_maps)
    print("Maps guard added")
else:
    print("ERROR: Maps pattern not found")

# Maps browser launch catch - add flag reset
old_maps_catch = '''  } catch (err) {
    send({ type: "error", message: "Failed to launch browser: " + (err as Error).message })
    res.end()
    return
  }

  let leadCount = 0
  let queuedCount = 0'''

new_maps_catch = '''  } catch (err) {
    browserRunInProgress = false
    send({ type: "error", message: "Failed to launch browser: " + (err as Error).message })
    res.end()
    return
  }

  let leadCount = 0
  let queuedCount = 0'''

if old_maps_catch in c:
    c = c.replace(old_maps_catch, new_maps_catch)
    print("Maps catch block updated")
else:
    print("ERROR: Maps catch pattern not found")

with open('/home/cicadaserver/instagram-hashtag-research-tool/src/server.ts', 'w') as f:
    f.write(c)
print("Done")

with open('/home/cicadaserver/instagram-hashtag-research-tool/src/server.ts', 'r') as f:
    c = f.read()

# 1. Add browser concurrency guard flag after PORT const
old_flag = 'const PORT = Number(process.env.PORT ?? 3001)'
new_flag = '''const PORT = Number(process.env.PORT ?? 3001)
// Guards against concurrent headful Chromium launches on the Pi.
// Only one browser context can run at a time due to Xvfb + limited RAM.
let browserRunInProgress = false'''

if old_flag in c and 'browserRunInProgress' not in c:
    c = c.replace(old_flag, new_flag)
    print("Flag added")
else:
    print("Flag already present or anchor not found:", 'browserRunInProgress' in c)

# 2. Add guard to /api/run/stream (Instagram)
# Find the stream endpoint and add the guard after the send function definition
old_stream1 = '''  const send = (event: Record<string, unknown>) => {
    if (!res.writableEnded && !res.destroyed) {
      res.write("data: " + JSON.stringify(event) + "\\n\\n")
    }
  }

  if (!hashtag) {
    send({ type: "error", message: "A hashtag is required." })
    res.end()
    return
  }

  try {
    await initDb()
  } catch (err) {
    send({ type: "error", message: (err as Error).message })
    res.end()
    return
  }

  try {
    context = await chromium.launchPersistentContext(PROFILE_DIR, { headless })'''

new_stream1 = '''  const send = (event: Record<string, unknown>) => {
    if (!res.writableEnded && !res.destroyed) {
      res.write("data: " + JSON.stringify(event) + "\\n\\n")
    }
  }

  if (!hashtag) {
    send({ type: "error", message: "A hashtag is required." })
    res.end()
    return
  }

  if (browserRunInProgress) {
    send({ type: "error", message: "A collection run is already in progress. Please wait for it to finish." })
    res.end()
    return
  }
  browserRunInProgress = true

  try {
    await initDb()
  } catch (err) {
    browserRunInProgress = false
    send({ type: "error", message: (err as Error).message })
    res.end()
    return
  }

  try {
    context = await chromium.launchPersistentContext(PROFILE_DIR, { headless })'''

if old_stream1 in c:
    c = c.replace(old_stream1, new_stream1)
    print("Instagram stream guard added")
else:
    print("WARNING: Instagram stream anchor not found")

# 3. Find the closing of the Instagram try block to add browserRunInProgress = false
# The Instagram stream has 'context = await chromium.launchPersistentContext' and the try block
# closes after the stream ends. We need to find where to insert the reset.
# Looking at the pattern, the finally block with 'await context?.close()' is the place.
# Let's add the reset before 'context = await chromium.launchPersistentContext' is called
# Actually let's add it to the finally block of the big try.

# Find the Instagram stream's finally block pattern
old_finally_instagram = '''  } finally {
    await context?.close()
  }
})

function normalizeHashtag'''

new_finally_instagram = '''  } finally {
    browserRunInProgress = false
    await context?.close()
  }
})

function normalizeHashtag'''

if old_finally_instagram in c:
    c = c.replace(old_finally_instagram, new_finally_instagram)
    print("Instagram finally block updated")
else:
    print("WARNING: Instagram finally block anchor not found")

with open('/home/cicadaserver/instagram-hashtag-research-tool/src/server.ts', 'w') as f:
    f.write(c)
print("Done")

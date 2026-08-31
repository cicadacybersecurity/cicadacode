with open('/home/cicadaserver/instagram-hashtag-research-tool/src/server.ts', 'r') as f:
    c = f.read()

old = '''// Local-only runtime visibility for Ollama. nvidia-smi is queried with fixed
// arguments; no user input is ever passed to a shell command.
app.get("/api/ollama/runtime", async (_req, res) => {
  const config = getLinkClassifierConfig()
  const result: Record<string, unknown> = {
    model: selectedOllamaModel,
    ollamaUrl: config.baseUrl,
    ollamaReachable: false,
    gpu: null,
    ollamaProcesses: [],
  }

  try {
    const tags = await fetch(config.baseUrl + "/api/tags")
    result.ollamaReachable = tags.ok
  } catch { /* reported as unreachable below */ }

  try {
    const { stdout } = await execFileAsync("nvidia-smi", [
      "--query-gpu=name,memory.used,memory.total,utilization.gpu",
      "--format=csv,noheader,nounits",
    ], { timeout: 4000, windowsHide: true })
    const first = stdout.trim().split(/\\r?\\n/)[0] ?? ""
    const [name, usedMiB, totalMiB, utilization] = first.split(",").map((value) => value.trim())
    if (name && usedMiB && totalMiB) {
      result.gpu = { name, usedMiB: Number(usedMiB), totalMiB: Number(totalMiB), utilization: Number(utilization) || 0 }
    }
  } catch { /* NVIDIA tooling/GPU may not be available */ }

  try {
    const { stdout } = await execFileAsync("nvidia-smi", [
      "--query-compute-apps=pid,process_name,used_memory",
      "--format=csv,noheader,nounits",
    ], { timeout: 4000, windowsHide: true })
    result.ollamaProcesses = stdout.trim().split(/\\r?\\n/).map((line) => {
      const [pid, processName, usedMiB] = line.split(",").map((value) => value.trim())
      return { pid, processName, usedMiB: Number(usedMiB) || 0 }
    }).filter((entry) => /ollama/i.test(entry.processName))
  } catch { /* no active compute processes is a valid idle state */ }

  res.json(result)
})'''

newcode = '''// Portable GPU probe: vcgencmd on ARM (Raspberry Pi), nvidia-smi on x86 Linux,
// nothing elsewhere. No user input reaches the shell.
function parseGpuInfo(): Promise<Record<string, unknown> | null> {
  return new Promise((resolve) => {
    if (process.platform === "linux" && process.arch === "aarch64") {
      // Raspberry Pi — use vcgencmd for temperature as a "GPU is present" signal.
      execFile("vcgencmd", ["measure_temp"], { timeout: 3000 }, (err, stdout) => {
        if (!err && stdout) {
          const match = stdout.match(/temp=([0-9.]+)/)
          const temp = match ? parseFloat(match[1]) : null
          resolve({ name: "Raspberry Pi GPU", usedMiB: 0, totalMiB: 0, utilization: 0, temperature: temp })
        } else {
          resolve(null)
        }
      })
    } else if (process.platform === "linux" && process.arch === "x64") {
      // NVIDIA GPU Linux — use nvidia-smi.
      execFile("nvidia-smi", ["--query-gpu=name,memory.used,memory.total,utilization.gpu", "--format=csv,noheader,nounits"], { timeout: 4000 }, (err, stdout) => {
        if (!err && stdout) {
          const first = stdout.trim().split(/\\r?\\n/)[0] ?? ""
          const [name, usedMiB, totalMiB, utilization] = first.split(",").map((v) => v.trim())
          if (name && usedMiB && totalMiB) {
            resolve({ name, usedMiB: Number(usedMiB), totalMiB: Number(totalMiB), utilization: Number(utilization) || 0 })
          } else { resolve(null) }
        } else { resolve(null) }
      })
    } else {
      resolve(null)
    }
  })
}

// Local-only runtime visibility for Ollama. GPU probe is platform-portable;
// no user input is ever passed to a shell command.
app.get("/api/ollama/runtime", async (_req, res) => {
  const config = getLinkClassifierConfig()
  const result: Record<string, unknown> = {
    model: selectedOllamaModel,
    ollamaUrl: config.baseUrl,
    ollamaReachable: false,
    gpu: null,
    ollamaProcesses: [],
  }

  try {
    const tags = await fetch(config.baseUrl + "/api/tags")
    result.ollamaReachable = tags.ok
  } catch { /* reported as unreachable below */ }

  result.gpu = await parseGpuInfo()

  if (process.platform === "linux" && process.arch === "x64") {
    // Only nvidia-smi can list per-process GPU memory on NVIDIA.
    try {
      const { stdout } = await execFileAsync("nvidia-smi", [
        "--query-compute-apps=pid,process_name,used_memory",
        "--format=csv,noheader,nounits",
      ], { timeout: 4000 })
      result.ollamaProcesses = stdout.trim().split(/\\r?\\n/).map((line) => {
        const [pid, processName, usedMiB] = line.split(",").map((v) => v.trim())
        return { pid, processName, usedMiB: Number(usedMiB) || 0 }
      }).filter((entry) => /ollama/i.test(entry.processName))
    } catch { /* no active compute processes is a valid idle state */ }
  }

  res.json(result)
})'''

if old in c:
    c = c.replace(old, newcode)
    print("Replaced successfully")
else:
    print("WARNING: Pattern not found in file")
    idx = c.find("// Local-only runtime visibility")
    print(f"'// Local-only runtime visibility' found at index: {idx}")

with open('/home/cicadaserver/instagram-hashtag-research-tool/src/server.ts', 'w') as f:
    f.write(c)
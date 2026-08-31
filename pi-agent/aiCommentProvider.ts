import { extractCommentFromReply } from "./messagePrompts"

const COMMENT_MODEL = "qwen3:8b"
const COMMENT_TIMEOUT_MS = 45_000

export async function generateInstagramComment(
  prompt: string,
  onLog?: (message: string) => void,
): Promise<string> {
  const baseUrl = (
    process.env.OLLAMA_URL ?? "http://127.0.0.1:11434"
  ).trim().replace(/\/+$/, "")

  const controller = new AbortController()

  const timer = setTimeout(() => {
    controller.abort()
  }, COMMENT_TIMEOUT_MS)

  try {
    onLog?.(
      `Using local Ollama ${COMMENT_MODEL} for Instagram comment generation...`,
    )

    const response = await fetch(`${baseUrl}/api/generate`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: COMMENT_MODEL,
        prompt,
        stream: false,
        think: false,
        options: {
          temperature: 0.9,
          num_predict: 100,
        },
      }),
      signal: controller.signal,
    })

    const body = (await response.json().catch(() => ({}))) as {
      response?: string
      error?: string
    }

    if (!response.ok) {
      throw new Error(
        `Ollama HTTP ${response.status}: ${
          body.error ?? "comment generation failed"
        }`,
      )
    }

    const comment = extractCommentFromReply(
      String(body.response ?? ""),
    )

    if (!comment) {
      throw new Error(
        "Qwen3 8B did not return a valid marked Instagram comment.",
      )
    }

    onLog?.(
      `Qwen3 8B generated comment: "${comment}"`,
    )

    return comment
  } catch (error) {
    if (
      error instanceof Error &&
      error.name === "AbortError"
    ) {
      throw new Error(
        "Qwen3 8B Instagram comment generation timed out.",
      )
    }

    throw error
  } finally {
    clearTimeout(timer)
  }
}

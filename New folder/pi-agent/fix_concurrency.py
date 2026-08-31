import os

with open('/home/cicadaserver/instagram-hashtag-research-tool/src/util/concurrency.ts', 'r') as f:
    c = f.read()

# Lower Pi defaults: reduce AI concurrency to save RAM
c = c.replace(
    'export const MAX_CONCURRENT_REQUESTS = envInt("MAX_CONCURRENT_REQUESTS", 6)',
    'export const MAX_CONCURRENT_REQUESTS = envInt("MAX_CONCURRENT_REQUESTS", 2)'
)
c = c.replace(
    'export const GEMINI_MAX_CONCURRENT = envInt("GEMINI_MAX_CONCURRENT", 3)',
    'export const GEMINI_MAX_CONCURRENT = envInt("GEMINI_MAX_CONCURRENT", 1)'
)
c = c.replace(
    'export const GROQ_MAX_CONCURRENT = envInt("GROQ_MAX_CONCURRENT", 3)',
    'export const GROQ_MAX_CONCURRENT = envInt("GROQ_MAX_CONCURRENT", 1)'
)
# Update comments to reflect Pi-appropriate defaults
c = c.replace(
    'MAX_CONCURRENT_REQUESTS  — max simultaneous AI calls across all providers (default 6)',
    'MAX_CONCURRENT_REQUESTS  — max simultaneous AI calls across all providers (default 2, Pi-friendly)'
)
c = c.replace(
    'GEMINI_MAX_CONCURRENT     — max simultaneous Gemini calls (default 3)',
    'GEMINI_MAX_CONCURRENT     — max simultaneous Gemini calls (default 1, Pi-friendly)'
)
c = c.replace(
    'GROQ_MAX_CONCURRENT       — max simultaneous Groq calls (default 3)',
    'GROQ_MAX_CONCURRENT       — max simultaneous Groq calls (default 1, Pi-friendly)'
)

with open('/home/cicadaserver/instagram-hashtag-research-tool/src/util/concurrency.ts', 'w') as f:
    f.write(c)
print('done')

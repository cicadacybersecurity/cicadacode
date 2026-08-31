import('./dist/util/concurrency.js').then(m => {
    console.log('concurrency OK')
    console.log('  MAX_CONCURRENT_REQUESTS:', m.MAX_CONCURRENT_REQUESTS)
    console.log('  GEMINI_MAX_CONCURRENT:', m.GEMINI_MAX_CONCURRENT)
    console.log('  GROQ_MAX_CONCURRENT:', m.GROQ_MAX_CONCURRENT)
}).catch(e => console.error('FAIL:', e.message))

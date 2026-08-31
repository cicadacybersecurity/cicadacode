import('./dist/config/linkClassifier.js').then(m => {
    console.log('linkClassifier OK, keys:', Object.keys(m).slice(0, 5))
}).catch(e => console.error('FAIL:', e.message))

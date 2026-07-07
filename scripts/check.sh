#!/usr/bin/env bash
set -euo pipefail
# Pull the contents of the LAST <script>…</script> block out of index.html and node --check it.
node -e '
const fs=require("fs");
const html=fs.readFileSync("index.html","utf8");
const m=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
if(!m.length){console.error("no <script> block found");process.exit(2);}
fs.writeFileSync("/tmp/mm_check.js", m[m.length-1][1]);
'
node --check /tmp/mm_check.js && echo "node --check: OK"

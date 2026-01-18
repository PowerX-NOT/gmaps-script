#!/bin/bash

URL="https://www.google.com/maps/rpc/transit/lines?gl=in&pb=!1m5!7e140!9s4HVsadHhFYXYseMPp6WpQQ%3A933925486775!17s4HVsadHhFYXYseMPp6WpQQ%3A933925486776!24m1!2e1!2m4!1s0x3bae6b6cce624449%3A0x6a0e2b4dbae58776!2s0x3bae6c6c917e3951%3A0xda5bf6ad89b2b656!4j1768724046!5sbABDwibLLBiDtFCnipbvtLN2-TQ%3D%3D!3m3!2m2!3e1!3e0"

OUTPUT="transit_lines.json"

curl "$URL" \
  -X GET \
  -H "accept: */*" \
  -H "accept-language: en-GB,en-US;q=0.9,en;q=0.8" \
  -H "referer: https://www.google.com/" \
  -H "sec-fetch-site: same-origin" \
  -H "sec-fetch-mode: cors" \
  -H "user-agent: Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1" \
  -H "cookie: __Secure-BUCKET=CH0; SID=PASTE_YOUR_COOKIE; HSID=PASTE; SSID=PASTE; APISID=PASTE; SAPISID=PASTE; NID=PASTE" \
  --compressed \
  -o "$OUTPUT"

echo "✅ Transit lines response saved to $OUTPUT"

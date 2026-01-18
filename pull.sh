#!/bin/bash

URL="https://www.google.com/maps/preview/place?gl=in&q=B.T.M+Layout+Water+Tank&pb=!1m10!1s0x0%3A0xccc4fb6e2937b03!3m8!1m3!1d3873.6847592714207!2d77.60605743528066!3d12.915710952084408!3m2!1i342!2i765!4f13.1"

OUTPUT="response.json"

curl "$URL" \
  -X GET \
  -H "accept: */*" \
  -H "accept-language: en-GB,en-US;q=0.9,en;q=0.8" \
  -H "content-type: application/json; charset=UTF-8" \
  -H "referer: https://www.google.com/" \
  -H "sec-fetch-site: same-origin" \
  -H "sec-fetch-mode: cors" \
  -H "user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36" \
  -H "cookie: __Secure-BUCKET=CH0; SID=PASTE_YOUR_COOKIE; HSID=PASTE; SSID=PASTE; APISID=PASTE; SAPISID=PASTE; NID=PASTE" \
  --compressed \
  -o "$OUTPUT"

echo "✅ Response saved to $OUTPUT"

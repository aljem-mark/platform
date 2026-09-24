FROM hardcoreeng/front-base:v20250916
WORKDIR /app

COPY bundle/bundle.js ./
COPY bundle/bundle.js.map ./
COPY dist/ ./dist/
COPY bundle/openapi.yaml ./docs/api/openapi.yaml
COPY bundle/openapi-safe.yaml ./docs/api/openapi-safe.yaml

EXPOSE 8080
CMD [ "node", "./bundle.js" ]

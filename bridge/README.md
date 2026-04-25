# Local bridge

This bridge exposes an HTTP API for the local computer-use stack and shells out to the Swift helper.

## Run

```bash
swift build --package-path ./helper-swift
node ./bridge/server.mjs
```

## Health

```bash
curl http://127.0.0.1:4458/health
curl http://127.0.0.1:4458/health?deep=1
```

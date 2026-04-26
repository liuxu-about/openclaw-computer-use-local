# Computer-use evals

Minimal local eval harness for the bridge.

```bash
npm run eval
```

The runner reads `evals/tasks/*.json`, calls the local bridge, prints a small report, and writes `evals/report.json`.

Useful environment variables:

```bash
COMPUTER_USE_BRIDGE_URL=http://127.0.0.1:4458
COMPUTER_USE_EVAL_TASKS_DIR=./evals/tasks
COMPUTER_USE_EVAL_ACTIONS=1
COMPUTER_USE_EVAL_SCREENSHOT=1
```

Action and screenshot evals are opt-in because they can change the visible UI, require Screen Recording permission, or run slower.

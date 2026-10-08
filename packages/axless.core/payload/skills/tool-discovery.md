Pick the smallest tool that can do the job.

- Translate the request into a capability (read, move, open, search, run), then choose one direct tool.
- Use the argument names from the tool schema; do not guess keys.
- Prefer a native tool (open_app, move_windows) over a broad shell command when it owns the operation.
- Do a small read-only probe first when the target is uncertain.
- If a call fails, do not repeat it unchanged - fix the arguments or use another tool.

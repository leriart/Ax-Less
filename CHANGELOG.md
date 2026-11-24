# Changelog

## 1.2.3

- Fixed AI chat persistence. `saveCurrentChat` started a `Process` with no
  command, so its `onExited` never ran and no chat JSON was ever written. Chat
  files are now written directly through the `FileView`, atomically, and the
  history list is refreshed after the write.
- The chat directory now follows `XDG_DATA_HOME` like the rest of Ambxst,
  instead of always using `~/.local/share`.

## 1.2.2

- Restored the 73 NothingLess compositor keys in `config/defaults/compositor.js`,
  the `Config` adapter and `GlobalStates._compositorProps`. The advanced panel
  could read its fallbacks but could not persist the Hyprland-only controls,
  and Discard did not restore them.
- Fixed agent tool-call round-trips. `Ai.qml` now forwards `toolCallId`,
  `tool_call_id` and `reasoningContent` to the strategies; the shared strategy
  pairs tool results with the assistant call, and DeepSeek reasoning is echoed
  back. Anthropic, Gemini, Groq, Mistral and MiniMax now use the strategy
  overlays that were already shipped but never applied; Anthropic/Gemini/MiniMax
  also parse streamed tool calls.
- Added proper provider labels for DeepSeek, OpenRouter, xAI and LM Studio, and
  made LM Studio a local provider: it enables without a fake API key.
- Added the missing Russian translations for the compositor cooldown, touchpad,
  task board and wallpaper interpolation, and translated the agent settings UI
  in English, Spanish and Russian.
- Added the 14 Phosphor icon aliases the agent UI and stock 1.4 widgets
  reference but the Ambxst icon set does not define.
- Declared the custom AI endpoint/curl config keys used by the AI panel, so the
  fields persist instead of assigning to a non-existent property.

## 1.2.1

- Fixed saving AI provider API keys on a clean Ambxst 1.4 install. The
  daemon's keystore only creates its sqlite schema from `keystore.list`, and
  that path fails before `keys.db` exists, so `keystore.set` returned
  `no such table: api_keys` and the key was discarded. `KeyStore.qml` now
  creates the database and table before the first daemon call, queues writes
  while that happens, and retries once if the table is still missing.
- `KeyStore.setKey` now preserves the provider's existing endpoint and custom
  curl unless new values are passed, instead of clearing them on every key
  update.
- The AI panel clears the key field only after the save succeeds, and logs a
  warning with the backend error when it does not.

## 1.2.0

- Updated the package for Ambxst 1.4.x (tested against 1.4.1,
  `5db90ba000713b5cb991a2abce1b766ab47fbd2b`).
- Moved the package manifest, payload and patches to the repository root, so
  `https://github.com/leriart/Ax-Less` installs directly. The previous layout
  was two directories deep and failed with `archive must contain one package
  manifest`. Existing installations whose source is
  `packages/axless.core` need to be removed and reinstalled from the root; that
  directory no longer exists.
- Regenerated `ipc-no-fork.patch` for the 1.4 compositor writer, keeping the
  Mango layout-state guard while routing writes through `BackendService`.
- Removed `notifications-bounded.patch`. Ambxst 1.4 moved notification history
  and persistence into its daemon, so the rewritten `Notifications.qml` no
  longer has the file-write path that patch bounded.
- Stopped declaring `ollama` and `ffmpeg` as required commands. Both are
  optional features (local Ollama models and the pre-rendered video path), so
  requiring them blocked enabling the mod on systems without them. The hard
  requirements are now `bash`, `curl` and `axctl`.

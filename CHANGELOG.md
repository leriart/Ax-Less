# Changelog

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

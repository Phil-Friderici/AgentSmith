# Cache

This directory documents cache use; it does not contain runtime caches.

Caches are optional, rebuildable performance optimizations. The default host cache root is `~/AgentForge/cache`, configurable at runtime. Level 1 mounts one explicitly selected cache directory at `/cache`; the Puppet workflow derives a per-module Bundler cache path under `/cache/bundler/` from the canonical module path. Persist only selected Ruby/Bundler and PDK caches, scoped by user and project, whose contents, ownership, retention, and invalidation behavior are understood. A cache must never be treated as authoritative project data or secret storage. Copilot's cache remains under `/tmp/copilot-cache` and is not persisted.

Both Compose profiles set Copilot's `COPILOT_CACHE_HOME` to `/tmp/copilot-cache`. CLI 1.0.112 extracts about 282 MiB of bundled runtime data there on first use. Both profiles allocate a 512 MiB `/tmp` tmpfs, and the startup diagnostic enforces this minimum. This runtime scratch is distinct from the host-mounted `/cache`.

Cache contents may include private package metadata or untrusted downloaded artifacts. Do not share writable caches across permission levels or unrelated trust domains, and provide an operator-understood cleanup path. Startup validation scans the selected cache for known Copilot/GitHub authentication files and recognizable token content; any match fails the diagnostic without printing file contents. Do not persist APT authentication files or place Puppet credentials, GitHub tokens, Copilot authentication, or MCP secrets here.

Do not share writable caches across projects or trust levels. To recover a single module, identify and remove only its exact hashed Bundler cache directory; never clear the shared host cache root while other work may be using it.

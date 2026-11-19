# v0.2.0 acceptance — 2026-11-19

## Accepted

- Native main window contains account switching/opening, profile editing, sessions, usage, update and gateway controls. Menu-bar handler opens that window.
- Background login verified with real browser authorization on the rebuilt app: `Token received`, secure field filled, model fetch returned 14 models, profile saved. Existing working profile retained.
- Parser excludes the CLI instruction beginning `Store this token securely.` and rejects incomplete output. Targeted repair of the old appended-Store corruption creates private backups. Finder CLI lookup, PTY dimensions, immediate output flushing, and stale-process callback protection added. Regression fixture emits a token while remaining alive, verifying capture does not depend on process exit.
- Second saved account: official CLI returned OK. Native Claude Desktop Code returned DESKTOP_OK in session local_e889d940-9b63-4810-afd9-a76c89574240. After reopening Claude, the same session and messages remained; continuing it returned RESUME_OK.
- Active configuration verified as second saved profile, Anthropic provider, built-in default endpoint, gateway disabled. Native probe URL was https://api.anthropic.com/v1/messages.
- First saved account: official CLI reported usage_limit_reached, weekly reset Nov 23 at 09:00 America/Los_Angeles. Earlier generic HTTP probe results did not adequately distinguish account usability.
- Automatic update check observed at startup and manually. Default policy checks stable releases every six hours while running and asks before installing; selected release tag is pinned for the installer.
- Native import helper enables supported import/export settings after backup, retaining organization policy. Claude's wizard recognized original sessions. No original sessions were moved or overwritten.
- Gateway integration fixture verifies actual streaming, in-flight route pinning, switching next request without process restart, local authentication, header/credential isolation and refusal to follow redirects.
- 23 Swift tests passed. Universal arm64/x86_64 release build and strict code-signature verification passed.

## Explicit limitations

- Native Claude preflight still shows generic HTTP 429 with account tokens even when the actual Code response succeeds. This is not removed or patched by Switcher; do not call preflight success a prerequisite for proven message success, or model-list success proof of inference availability.
- setup-token usage request returned missing user:profile scope. Display unknown/unavailable; never fabricate remaining quota. Provider-controlled allowance cannot be reset.
- Read-only session index and native import preparation are implemented. Actual bulk import and custom sidebar-group fidelity are not accepted as complete.
- Gateway streaming is integration-tested; native Desktop message acceptance above used direct mode. Keep Switcher running while using optional gateway.
- Six-hour timing was not tested by leaving the app open six hours. Published-new-version upgrade/relaunch must be checked after release.
- App is ad-hoc signed, not notarized. Credentials remain private-permission plaintext in Switcher's profile store.

No raw tokens, OAuth authorization URLs, or private transcripts are included in this record.

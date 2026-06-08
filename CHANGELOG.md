# Changelog

All notable changes to stack-nudge are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Pre-1.0, breaking changes bump the **minor** version.

## [1.15.0](https://github.com/StackOneHQ/stack-nudge/compare/v1.14.2...v1.15.0) (2026-06-08)


### Features

* **widget:** mascot reactions — event arrivals, idle loops, drag, quota stress ([2b97d45](https://github.com/StackOneHQ/stack-nudge/commit/2b97d45d8ec72c826b4386f153013021fdcd73ef))


### Bug Fixes

* **hygiene:** clean up update tempdirs and stale Claude session sidecars ([db8c8cc](https://github.com/StackOneHQ/stack-nudge/commit/db8c8ccb97745f9825748ee3a7c874dd6d48ed13))
* **panel:** row-nav wrap bug, Esc on Permissions window, expand flicker ([a432b9f](https://github.com/StackOneHQ/stack-nudge/commit/a432b9fbb90ee919cd36f812cf620af1318e4dc5))
* **updater:** clean up StackNudge.app.old after successful relaunch ([6f273c2](https://github.com/StackOneHQ/stack-nudge/commit/6f273c2902a0294d50edecbffae621493cd1b432))

## [1.14.2](https://github.com/StackOneHQ/stack-nudge/compare/v1.14.1...v1.14.2) (2026-06-04)


### Bug Fixes

* **1.14.2:** per-session event cap, banner-gate alerts, pin overrides widget ([00111dd](https://github.com/StackOneHQ/stack-nudge/commit/00111ddbc94050278634d28808573156d49891e8))
* **compact:** solid urgency color on quota rings, no wrap-around ([a408e10](https://github.com/StackOneHQ/stack-nudge/commit/a408e10a1457c81ba7662c2c7056cedaa154fb33))
* **events:** raise event history cap from 5 to 20 ([312bda5](https://github.com/StackOneHQ/stack-nudge/commit/312bda50402946546895d5f433e740df5eec783f))

## [1.14.1](https://github.com/StackOneHQ/stack-nudge/compare/v1.14.0...v1.14.1) (2026-06-02)


### Features

* **widget:** Settings → Widget toggle (default on) ([36aae98](https://github.com/StackOneHQ/stack-nudge/commit/36aae98170995246c773851af1c038c6f5bf3c28))


### Bug Fixes

* **sessions:** start polling at app launch, not Sessions tab onAppear ([f8374e1](https://github.com/StackOneHQ/stack-nudge/commit/f8374e13cfb5ef6c87f139b53481d994a14d831e))
* **updater:** explicit bundle relaunch + post-update render order ([eab3ab4](https://github.com/StackOneHQ/stack-nudge/commit/eab3ab455fd616ed6fae8e03892e78fa8269f091))
* **widget:** rename Pill→Widget opacity; toggle-on keeps panel expanded ([533c85d](https://github.com/StackOneHQ/stack-nudge/commit/533c85de33965e89789be04ccbd301147994431a))

## [1.14.0](https://github.com/StackOneHQ/stack-nudge/compare/v1.13.0...v1.14.0) (2026-06-02)


### Features

* **compact:** more mascot hover reactions ([f4a8712](https://github.com/StackOneHQ/stack-nudge/commit/f4a871208face993c770e1f04aa9c0b3993bb8b6))
* **compact:** Settings → Widget → Pill opacity (40/60/80/100%) ([4cdf47b](https://github.com/StackOneHQ/stack-nudge/commit/4cdf47bb3f0e8b1554d825f148c864381a890f75))


### Bug Fixes

* **compact:** banner-veto, pill opacity, mascot reactions, post-update expand ([f7c0262](https://github.com/StackOneHQ/stack-nudge/commit/f7c02624479313927404e955524535e9044b8fb6))
* **compact:** banner-window veto, quota toggle, mascot hover, menu hotkey ([fb1bad6](https://github.com/StackOneHQ/stack-nudge/commit/fb1bad641c4ff6053b5a9b1c823ede0d71f08331))
* **compact:** blur corner radius, draggable full panel, expand on post-update ([264d79a](https://github.com/StackOneHQ/stack-nudge/commit/264d79ac08e75a3b52fab07c75bc6192a17e03d2))

## [1.13.0](https://github.com/StackOneHQ/stack-nudge/compare/v1.12.1...v1.13.0) (2026-06-01)


### Features

* compact pill widget with mascots, ring gauge, drag-snap ([55af219](https://github.com/StackOneHQ/stack-nudge/commit/55af219702cc9c382c11824a50f8cd3c58413fb2))
* **compact:** bigger gauge + mascot, pending-count headline, contentMinSize fix ([670b60a](https://github.com/StackOneHQ/stack-nudge/commit/670b60a79cebf74d5ae187b9db738ab4d963fcba))
* **compact:** mascot picker, always-on widget, M expands from pill, fix overflow ([24e0323](https://github.com/StackOneHQ/stack-nudge/commit/24e03231db5a147a030cec1510a5f296f296bc53))
* **compact:** pinned widget mode with bot mascot, ring gauge, drag-snap ([fc909bb](https://github.com/StackOneHQ/stack-nudge/commit/fc909bb0dabfd3d8fe3861c95ef06048279db94c))


### Performance Improvements

* **compact:** pause decorative animations during drag ([9220d1e](https://github.com/StackOneHQ/stack-nudge/commit/9220d1eb7b05297747c9508a4e89bc60c00b9191))

## [1.12.1](https://github.com/StackOneHQ/stack-nudge/compare/v1.12.0...v1.12.1) (2026-05-27)


### Bug Fixes

* **activator:** correct iTerm2 session-id match + AX-raise specific Cursor window ([d1e5226](https://github.com/StackOneHQ/stack-nudge/commit/d1e5226de503ee47123a7660ee306b8424ef7c33))
* **activator:** route Cursor/VSCode CLI through captured IPC socket ([688641a](https://github.com/StackOneHQ/stack-nudge/commit/688641ade090a0f53cea2145f3cfb27233d90ec5))
* **activator:** route iTerm2 click-to-focus via ITERM_SESSION_ID ([ad34ae4](https://github.com/StackOneHQ/stack-nudge/commit/ad34ae4cdde6ff7d8c8613e8daeaa2d853186f05))
* **events:** dedupe hooks fired twice within 2s ([9a3d846](https://github.com/StackOneHQ/stack-nudge/commit/9a3d84628aa9c84aee4e61f14488ba046b9efc4a))
* **panel:** banner title includes session name; approve keeps panel open when more events remain ([fcb763f](https://github.com/StackOneHQ/stack-nudge/commit/fcb763f3e79c2f488cde1cffdeee3782f96cb394))
* **permissions:** use real AppleEvent to trigger Automation prompt ([33914d8](https://github.com/StackOneHQ/stack-nudge/commit/33914d882a423e540bd9c254bfdcf4217d6d6709))
* quota keychain prompts, permission reset, banner quality, multi-window activation ([e335ee6](https://github.com/StackOneHQ/stack-nudge/commit/e335ee6eeae7f71ff1583fcf84f00d251bbe49db))
* **quota:** prefer ~/.claude/.credentials.json over keychain when present ([32df863](https://github.com/StackOneHQ/stack-nudge/commit/32df863a65d307ee8cc6b9db00da9cadea141832))

## [1.12.0](https://github.com/StackOneHQ/stack-nudge/compare/v1.11.0...v1.12.0) (2026-05-26)


### Features

* **sessions:** display per-session context-window usage from Claude Code transcripts ([24145bc](https://github.com/StackOneHQ/stack-nudge/commit/24145bc570ad6fb959514ae2b422757979a2a6ad))
* **sessions:** live names, busy/idle status, proactive context alerts ([ed2e0e8](https://github.com/StackOneHQ/stack-nudge/commit/ed2e0e8dbde6c44ae6f9ba755cd6d5050d7a04c1))
* **sessions:** per-session context tracking + live names, busy/idle, context alerts ([6a397b3](https://github.com/StackOneHQ/stack-nudge/commit/6a397b3b2c8cdfee5bd3544044f8b237b3621e78))
* **sessions:** sort by activity (busy first, then last-active desc) ([fbf7b6d](https://github.com/StackOneHQ/stack-nudge/commit/fbf7b6ddd70d5a926a24f4478d98f954926c652c))


### Bug Fixes

* **sessions:** tokens-only display + PID-based event→session matching ([662be77](https://github.com/StackOneHQ/stack-nudge/commit/662be77d3558c2629bfd98b66cb5e7c47cd6a16a))

## [1.11.0](https://github.com/StackOneHQ/stack-nudge/compare/v1.10.0...v1.11.0) (2026-05-26)


### Features

* **settings:** "Check for updates…" action + lower default interval to 2h ([39fe656](https://github.com/StackOneHQ/stack-nudge/commit/39fe6565037790fcfd3f7923aaa8ef8456d3483d))
* **settings:** dim gated rows when their controlling toggle is off ([8c19f08](https://github.com/StackOneHQ/stack-nudge/commit/8c19f08336b34beb1c0574241f9d021e92378f3d))
* **settings:** move "Voice notifications" into the Voice section ([7a3cb2a](https://github.com/StackOneHQ/stack-nudge/commit/7a3cb2a6cfbd4fe0ee3ae29e932376c9aa995a2e))
* **settings:** transient feedback on "Check for updates" action ([4b4fdbc](https://github.com/StackOneHQ/stack-nudge/commit/4b4fdbc883647689575e12256156c09dbf2ebae1))


### Bug Fixes

* Settings polish: check-for-updates, faster update interval, gated-row dimming, voice section reshuffle ([63f2b26](https://github.com/StackOneHQ/stack-nudge/commit/63f2b26e2f6c6999ec7d593f522062144e51a7aa))
* **settings:** always surface check-for-updates result in the row ([ad66a5d](https://github.com/StackOneHQ/stack-nudge/commit/ad66a5ddc541e1005cd085596a883729e357b97d))
* **settings:** render value text on action rows ([1a10085](https://github.com/StackOneHQ/stack-nudge/commit/1a10085314897962567583e24c42267658e39d95))

## [1.10.0](https://github.com/StackOneHQ/stack-nudge/compare/v1.9.1...v1.10.0) (2026-05-26)


### Features

* Post-launch polish: launch-at-login toggle + OAuth token caching ([2975466](https://github.com/StackOneHQ/stack-nudge/commit/2975466f20297d92373e8fa1d69dfd7045138663))
* **settings:** add "Launch at login" toggle (on by default) ([4419c70](https://github.com/StackOneHQ/stack-nudge/commit/4419c7097a0534668864e2ed557fa1492b0982a9))
* **settings:** quota tracking toggle, poll frequency cycle, release notes action ([d2c89a8](https://github.com/StackOneHQ/stack-nudge/commit/d2c89a8e226001e7880a0a37340b71eb1166a1b9))
* **usage:** explicit empty state when quota tracking is disabled ([479c24a](https://github.com/StackOneHQ/stack-nudge/commit/479c24adeb0a3eb1a08ddf1575728f16f4ff26ac))
* **usage:** pause/resume keystroke for quota tracking ([c7e251a](https://github.com/StackOneHQ/stack-nudge/commit/c7e251a41f2b2df68d9ff281ead9c912eafe540d))
* **usage:** sync-now keystroke + richer footer status ([a57bcec](https://github.com/StackOneHQ/stack-nudge/commit/a57bcec63976e3f95b946a02f08c431c58b3af1a))


### Bug Fixes

* **usage:** cache OAuth token in memory to reduce keychain prompts ([d2db552](https://github.com/StackOneHQ/stack-nudge/commit/d2db5523c9e70a793da5033772bdc81cb7aa9762))

## [1.9.1](https://github.com/StackOneHQ/stack-nudge/compare/v1.9.0...v1.9.1) (2026-05-22)


### Bug Fixes

* trigger release for README + integration changes since v1.9.0 ([385e128](https://github.com/StackOneHQ/stack-nudge/commit/385e128aefb36681689a82541b9fc622876dcc93))

## [1.9.0](https://github.com/StackOneHQ/stack-nudge/compare/v1.8.0...v1.9.0) (2026-05-20)


### Features

* auto-wire Codex and Gemini CLI hooks; honest README support table ([96b94cb](https://github.com/StackOneHQ/stack-nudge/commit/96b94cb63effc9a8a7daef41b6d00614d4b1dce0))
* surface unwired agents in Settings + one-click reconciliation ([cbbf5e9](https://github.com/StackOneHQ/stack-nudge/commit/cbbf5e9aa1f79828a533de2f2b1445f0c11313c1))


### Bug Fixes

* Codex + Gemini auto-wire, agent reconciliation banner, banner-flash fix ([362a340](https://github.com/StackOneHQ/stack-nudge/commit/362a3407d6b2b2c4880e751b4693c4ef35823f1c))
* Gemini hook timeout is milliseconds, not seconds ([c143d89](https://github.com/StackOneHQ/stack-nudge/commit/c143d893e452b089ec19dd44a71b45bfc3442ccd))
* kill the panel flash on banner click ([ae1f37b](https://github.com/StackOneHQ/stack-nudge/commit/ae1f37b8558f0fdae89a7d158796bd910d95733c))

## [1.8.0](https://github.com/StackOneHQ/stack-nudge/compare/v1.7.2...v1.8.0) (2026-05-20)


### Features

* switch Ghostty tabs on banner click via AppleScript bridge ([0cc97b9](https://github.com/StackOneHQ/stack-nudge/commit/0cc97b95046b60629dbce961504bcef5fbd9423c))


### Bug Fixes

* switch Ghostty tabs on banner click ([8df1405](https://github.com/StackOneHQ/stack-nudge/commit/8df1405b73803da33f76bb8eef122b6b65c5a3b4))

## [1.7.2](https://github.com/StackOneHQ/stack-nudge/compare/v1.7.1...v1.7.2) (2026-05-19)


### Bug Fixes

* invoke stackvox via python3 to bypass pip's baked-in shebang ([f035d60](https://github.com/StackOneHQ/stack-nudge/commit/f035d60d21708feb53316c5277b4b3989272de21))
* **usage:** bound ScrollView height + show indicators ([112b272](https://github.com/StackOneHQ/stack-nudge/commit/112b2720a2771c88450f58ef43a361f0feea62be))
* voice broken on user machines + Usage view scroll clipping ([3da4bf5](https://github.com/StackOneHQ/stack-nudge/commit/3da4bf5126954e89bf2a20cb7e3bba8aa5d30abb))

## [1.7.1](https://github.com/StackOneHQ/stack-nudge/compare/v1.7.0...v1.7.1) (2026-05-19)


### Bug Fixes

* **ci:** manual workflow_dispatch fallback for release.yml ([c978b63](https://github.com/StackOneHQ/stack-nudge/commit/c978b6381b4d9a583644c7bc05c73ed5e94b9e86))
* **ci:** swap PAT for workflow_dispatch fallback ([950d4fe](https://github.com/StackOneHQ/stack-nudge/commit/950d4feed9e7f0bb8accefd9a85921b775f0fe5f))
* **ci:** use PAT in release-please so tag push triggers release.yml ([2a8872d](https://github.com/StackOneHQ/stack-nudge/commit/2a8872d77ec4befe46cacfc76400057c12f7beff))

## [1.7.0](https://github.com/StackOneHQ/stack-nudge/compare/v1.6.0...v1.7.0) (2026-05-19)


### Features

* add Sound toggle in Settings ([f0d44a0](https://github.com/StackOneHQ/stack-nudge/commit/f0d44a082f984566e84288ed394ab8e6aa35dc35))
* Bootstrap UI + first-launch wizard + Settings uninstall row ([f8d796e](https://github.com/StackOneHQ/stack-nudge/commit/f8d796e1c624ce2320f41f8aa704181e8437e0d3))
* Bootstrap.swift core install/uninstall logic ([f7efc06](https://github.com/StackOneHQ/stack-nudge/commit/f7efc061c55660c15b6ecf13912d19b724c8d8a4))
* move audio + voice from notify.sh into the app ([571ccb3](https://github.com/StackOneHQ/stack-nudge/commit/571ccb31ce8fd660c7ce6eca72704f49c5043d1b))
* native Mac install — signed releases + self-install/uninstall + artifact auto-update ([6ec86fd](https://github.com/StackOneHQ/stack-nudge/commit/6ec86fded3c0919d84bab7041e3c0f758bd2bbcd))
* Updater downloads + atomic-swaps signed release artifact ([63bdde2](https://github.com/StackOneHQ/stack-nudge/commit/63bdde2e6f9f23ed950c33df230db2f25b4bfe26))
* voice model download UI + integrity checks ([82fc16a](https://github.com/StackOneHQ/stack-nudge/commit/82fc16a6c47194495ff14a060bd381f2db5d8b3a))


### Bug Fixes

* **ci:** exclude entitlements.plist from SPM + forward win_title ([d1469be](https://github.com/StackOneHQ/stack-nudge/commit/d1469be16a86a605ad196260afdf665e7a3644b3))
* panel auto-resize, dup-instance on reopen, quota alert spam ([9102681](https://github.com/StackOneHQ/stack-nudge/commit/91026819bed7758f7843393d9e12d0a7e6e5264b))

## [1.6.0](https://github.com/StackOneHQ/stack-nudge/compare/v1.5.0...v1.6.0) (2026-05-14)


### Features

* quota tracking via /api/oauth/usage ([6bad9a7](https://github.com/StackOneHQ/stack-nudge/commit/6bad9a7d59230c5eafbe90e30168df9a58fbeeee))
* quota tracking via /api/oauth/usage ([4b69002](https://github.com/StackOneHQ/stack-nudge/commit/4b6900261549359499f7eb23ca4b74f5852abb82))

## [1.5.0](https://github.com/StackOneHQ/stack-nudge/compare/v1.4.2...v1.5.0) (2026-05-12)


### Features

* in-app auto-updater ([aa30bb9](https://github.com/StackOneHQ/stack-nudge/commit/aa30bb9ea70b2532133e70ecdb40270c55796744))
* in-app auto-updater ([d4e4e98](https://github.com/StackOneHQ/stack-nudge/commit/d4e4e98df2ef874c27de5a4c09985140d3142881))

## [1.4.2](https://github.com/StackOneHQ/stack-nudge/compare/v1.4.1...v1.4.2) (2026-05-12)


### Bug Fixes

* report correct CFBundleShortVersionString in installed bundles ([54f9815](https://github.com/StackOneHQ/stack-nudge/commit/54f9815774b6830bcc533311f4dd45e2acebaaeb))
* report correct CFBundleShortVersionString in installed bundles ([1bb25c5](https://github.com/StackOneHQ/stack-nudge/commit/1bb25c55f5639647ee026800dc628290addbaca3))

## [1.4.1](https://github.com/StackOneHQ/stack-nudge/compare/v1.4.0...v1.4.1) (2026-05-06)


### Bug Fixes

* open panel on the screen with the cursor ([56daeb4](https://github.com/StackOneHQ/stack-nudge/commit/56daeb44b6395782a2a91861eee9a48c1caf013f))
* open the panel on the screen with the cursor, not the main display ([a2ac086](https://github.com/StackOneHQ/stack-nudge/commit/a2ac086ab5e38c3f404d8ae82c22efa5005f509b))

## [1.4.0](https://github.com/StackOneHQ/stack-nudge/compare/v1.3.0...v1.4.0) (2026-05-01)


### Features

* customisable voice phrase pools ([a475922](https://github.com/StackOneHQ/stack-nudge/commit/a475922b1385ba2926a8ae9b3648d2b6ba5ebe32))
* customisable voice phrase pools ([6d66495](https://github.com/StackOneHQ/stack-nudge/commit/6d664956fe9b842eaa606014d8e47d224aef814a))

## [1.3.0](https://github.com/StackOneHQ/stack-nudge/compare/v1.2.0...v1.3.0) (2026-05-01)


### Features

* fire a welcome notification at end of install ([08b2621](https://github.com/StackOneHQ/stack-nudge/commit/08b2621926bc4b8eb1ab6027b154070a50de8563))
* install hardening + first-run welcome screen + about footer ([3e93dd3](https://github.com/StackOneHQ/stack-nudge/commit/3e93dd3263aac35b73a4a0d815e80e03f76c71b2))
* opt-in permissions flow + cleaner welcome UX ([37e04df](https://github.com/StackOneHQ/stack-nudge/commit/37e04df9dbe98eea11a25444de21a4a7ceba9536))
* snooze permission events (5 / 15 min) ([761c349](https://github.com/StackOneHQ/stack-nudge/commit/761c349410f425307dada2a925bb93c66e82a433))
* snooze permission events for 5 or 15 minutes ([f15970a](https://github.com/StackOneHQ/stack-nudge/commit/f15970a96ba4575df72eac01a49867177a8ca4f9))
* space activates settings rows alongside enter ([a6870cd](https://github.com/StackOneHQ/stack-nudge/commit/a6870cde483c576945249ef4d99ab5f68bb02abe))


### Bug Fixes

* install hardening + first-run welcome + about footer ([40e9d0a](https://github.com/StackOneHQ/stack-nudge/commit/40e9d0ac2e3b941eb4fa33703d104b914198d1a1))

## [1.2.0](https://github.com/StackOneHQ/stack-nudge/compare/v1.1.2...v1.2.0) (2026-04-30)


### Features

* **#18:** detect Zed as a host editor ([e672ca2](https://github.com/StackOneHQ/stack-nudge/commit/e672ca2c080023f431b7a0ef44b7ea1fc42dbe4e))
* add mute-when-focused toggle ([b9286cc](https://github.com/StackOneHQ/stack-nudge/commit/b9286ccbcd3642d8a152bea1d56dc8468a8cb6dd))
* add mute-when-focused toggle (+ make-dev watcher fix) ([64d70e3](https://github.com/StackOneHQ/stack-nudge/commit/64d70e3702050afe9bd7179ffa123cae77d21fe5))
* add pin panel toggle (auto-hide on focus loss when off) ([b4c4cc7](https://github.com/StackOneHQ/stack-nudge/commit/b4c4cc75de2bf1205d9ac168e8d434c564aab40e))
* blocking permission hook with FIFO-based approval ([84baaea](https://github.com/StackOneHQ/stack-nudge/commit/84baaeaf9c0dd86e85f69a41d42ee873d0f8d868))
* blocking permission hook with FIFO-based approval ([3e1265e](https://github.com/StackOneHQ/stack-nudge/commit/3e1265ecaed73d78bcae2964e3097a8f7a8aa95c))
* bundle StackVox TTS engine into stack-nudge ([dfba23e](https://github.com/StackOneHQ/stack-nudge/commit/dfba23e1bb77c459db5c2e1ce768c6c691e8575e))
* bundle StackVox TTS engine into stack-nudge ([46749a3](https://github.com/StackOneHQ/stack-nudge/commit/46749a3c2504df31ccd3f826004d34d12c8ec9f3))
* detect Zed as a host editor (closes [#18](https://github.com/StackOneHQ/stack-nudge/issues/18)) ([a8c5e5b](https://github.com/StackOneHQ/stack-nudge/commit/a8c5e5bc28f71ee42c7b567e96219d506bd32555))
* hotkey recorder, AX terminal-pane focus, config file watcher ([f201f1b](https://github.com/StackOneHQ/stack-nudge/commit/f201f1b1583864bf0d0f664eee892331d268aa25))
* keyboard-native floating panel ([938d657](https://github.com/StackOneHQ/stack-nudge/commit/938d6576235f86ea8af78e4f1842ba35ed41a5cf))
* keyboard-native floating panel ([94b42d5](https://github.com/StackOneHQ/stack-nudge/commit/94b42d540a3aadae7d33e975b44f8e489b12daaa))
* keyboard-native panel with sessions, settings, voice phrases ([75cf450](https://github.com/StackOneHQ/stack-nudge/commit/75cf450443465349500122c542f1519f2f955183))
* per-language voice phrases, AX terminal focus, polish + refactor ([a00825e](https://github.com/StackOneHQ/stack-nudge/commit/a00825e957ed206cf4b8baca410bebc52c230331))
* sessions, in-panel settings, and PID/session enrichment ([d0c8beb](https://github.com/StackOneHQ/stack-nudge/commit/d0c8beb9949a16910365b6658c419a46f5da0ccf))
* sessions, in-panel settings, and PID/session enrichment ([fed1c70](https://github.com/StackOneHQ/stack-nudge/commit/fed1c7093c70fb15ff03406ba12d6e9a2681a85b))


### Bug Fixes

* **#11:** make Python &lt;3.10 install failure visible ([ac2fe4a](https://github.com/StackOneHQ/stack-nudge/commit/ac2fe4ad881b3312f4df36c506ae50c700c2f4b2))
* **#12:** replace stale stack-nudge hook entries on upgrade ([379d540](https://github.com/StackOneHQ/stack-nudge/commit/379d5404b70f1a0e02b4434d2bef06d8639e9de7))
* auto-reinitialize audio on output device change ([aa3a7f4](https://github.com/StackOneHQ/stack-nudge/commit/aa3a7f4956f475fc28b2ab68859bb130c201a76c))
* auto-reinitialize audio when output device changes (earbuds/speakers) ([c3c7990](https://github.com/StackOneHQ/stack-nudge/commit/c3c7990e06b90891df54502e9a0a58a62dce3d12))
* copy app bundle to ~/Applications and update icon + logo ([46734ce](https://github.com/StackOneHQ/stack-nudge/commit/46734ce3bb7e19165c60d442c8d6e3f0c389370c))
* declare and assign separately to satisfy shellcheck SC2155 ([60e632f](https://github.com/StackOneHQ/stack-nudge/commit/60e632f042b3784a30bc986763378629e44211e2))
* esc closes panel from any tab; preserve active tab on hide ([6b534f6](https://github.com/StackOneHQ/stack-nudge/commit/6b534f681b2918b65eb9528deeae60c34c6931df))
* installer Python detection visibility ([#11](https://github.com/StackOneHQ/stack-nudge/issues/11)) and stale hook cleanup ([#12](https://github.com/StackOneHQ/stack-nudge/issues/12)) ([3c9ed47](https://github.com/StackOneHQ/stack-nudge/commit/3c9ed47b5655265a6e7432b5c2998be9380978f2))
* make dev watcher catches notify.sh + phrases edits ([ebcf747](https://github.com/StackOneHQ/stack-nudge/commit/ebcf747285a764ee4613ac5b97f747d8be541b8d))
* migrate to stackvox 0.3.x unified CLI; voice was silently broken on fresh installs ([68efe9c](https://github.com/StackOneHQ/stack-nudge/commit/68efe9c4200c95467179d2590e9dc1b17cf95912)), closes [#14](https://github.com/StackOneHQ/stack-nudge/issues/14)
* migrate to stackvox 0.4.x unified CLI ([a184b0b](https://github.com/StackOneHQ/stack-nudge/commit/a184b0ba730b8df93d452fced3d68bc3dbe63a32))
* press Enter to approve permission in terminal apps on notification click ([b6d7aaa](https://github.com/StackOneHQ/stack-nudge/commit/b6d7aaab3a8de28ad3739b9132ee47d91708d6ab))
* remove ~/Applications/stack-nudge.app on uninstall ([a1bcc18](https://github.com/StackOneHQ/stack-nudge/commit/a1bcc1874600d7c516eaf03ca841c94afdb49fac))
* remove unused ACTIVATE_IMMEDIATELY variable (shellcheck SC2034) ([2434633](https://github.com/StackOneHQ/stack-nudge/commit/2434633fe932e986c054815ad98cff76de15f208))
* restore STACKNUDGE_ACTIVATE_IMMEDIATELY; document STACKNUDGE_PANEL migration ([349cbe7](https://github.com/StackOneHQ/stack-nudge/commit/349cbe715ee9fa611d12fdf903f26e9bee9f628b))

## [Unreleased]

### Added

- Repo prepared for open-source release: `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `NOTICE`, this changelog, GitHub issue / PR templates, dependabot config for actions, and a CI workflow that verifies the Swift build and shell scripts on macOS.

## [0.3.0] — 2026-04-30

### Added

- **Tabbed keyboard panel** — Events / Sessions / Settings tabs reachable via `Cmd+1` / `Cmd+2` / `Cmd+3` or the in-panel tab strip.
- **Sessions tab** — live list of running `claude` / `gemini` / `codex` agent processes (including node-hosted variants like `gemini-cli`). Polls `ps` + `lsof` every 3 seconds while visible. Supports focus-source-terminal (⏎), inline rename (`n`), and SIGTERM kill (⌫). Closes #3.
- **Settings tab** — keyboard-driven rows for hotkey, banner / voice toggles, sound picks (with audio preview on cycle), voice picker (with conversational-phrase preview on cycle), speed, plus action shortcuts to permissions / open config / quit.
- **Hotkey recorder** — record a new global hotkey from inside Settings; re-registers live and persists to `~/.stack-nudge/config`. Surfaces an inline error when the OS rejects the combo.
- **Per-pane focus in VS Code / Cursor** — before sending the approval keystroke, the panel walks the editor's accessibility tree to focus the terminal pane labelled with the agent's binary name (claude / gemini / codex). Falls back gracefully if no match.
- **Per-language voice phrase pools** — `phrases/{en,fr,hi,it,pt}.sh` provide event-specific (response / notification) phrasing keyed off the configured Kokoro voice's language prefix. Voice messages now sound like *"unified cloud api is ready for you"* or *"unified cloud api requires a decision"* instead of the literal "Done".
- **Config file watcher** — external edits to `~/.stack-nudge/config` flow back into the running panel without a restart. Re-arms on rename/delete so atomic-save editors don't orphan the watcher.
- **Permissions window** with a Reset & prompt action that clears the TCC entry and triggers macOS's standard grant dialog — recovers the rebuild-invalidates-cdhash gotcha that bites every iteration of an ad-hoc-signed dev build.
- **Voice replaces sound** — when `STACKNUDGE_VOICE=true`, the chime is suppressed across all surfaces so the user doesn't get double-cued.
- **`make dev`** watch-loop for inner-loop development; rebuild + reinstall + bounce in ~2s on any `.swift` / `notify.sh` / `phrases/` save.

### Changed

- Default hotkey switched from `cmd+shift+n` (collides with "New Incognito Window" in browsers, "New Window" in many editors, "New Folder" in Finder) to `cmd+opt+n`.
- stackvox vendored copy removed; `install.sh` now pulls `stackvox>=0.3.0` from PyPI into the venv. The `find_python` helper in `install.sh` selects a Python ≥ 3.10 from common Homebrew paths when the system `python3` is too old.

### Fixed

- Permissions window crash on open (`NSInternalInconsistencyException` from setting both `.canJoinAllSpaces` and `.moveToActiveSpace` on `collectionBehavior`).
- Hotkey recording-mode trap — ↑/↓/Tab now cancel recording so users who entered by mistake aren't stuck.
- Banner suppression when source window is frontmost respects the voice / sound interplay.

## [0.2.0] — 2026-04-25

### Added

- **Keyboard-native floating panel** — opt-in `STACKNUDGE_PANEL=true` runs a persistent daemon that surfaces nudges in a borderless HUD-blur window summoned by global hotkey. Acts on events with the keyboard (↑/↓ select, ⏎ approve / focus, ⌫ dismiss, esc hide).
- **Menu bar bell icon** with quick toggles for banner / voice, links to the panel and config file, and a Quit action.
- **Per-event PID / session enrichment** — `notify.sh` walks the parent process tree on each hook and emits `agent_pid`, `shell_pid`, `terminal_pid`, `terminal_app`, `term_program`, and `session_id` alongside the existing fields. Used by the panel for session correlation.

## [0.1.0] — 2026-04-22

### Added

- Initial release. Supports Claude Code, Cursor, Gemini CLI, and Codex via `notify.sh <agent> <event>`.
- macOS native banners with click-to-focus that route back to the source editor / terminal window. Supported apps: VS Code, Cursor, iTerm2, Warp, Ghostty, Terminal.app.
- Voice notifications via [stackvox](https://github.com/StackOneHQ/stackvox) — bundled and set up automatically by `./install.sh`.
- `STACKNUDGE_ACTIVATE_IMMEDIATELY=true` for click-free editor focus.

[Unreleased]: https://github.com/StackOneHQ/stack-nudge/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/StackOneHQ/stack-nudge/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/StackOneHQ/stack-nudge/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/StackOneHQ/stack-nudge/releases/tag/v0.1.0

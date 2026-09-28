# TransDuck inside YouTube for iPad

This branch adds a native TransDuck panel to YouMod's YouTube player overlay. It is built as an arm64 tweak and injected into a local, decrypted YouTube 21.38.3 IPA. The YouTube IPA and account credentials are never committed to this repository.

## Implemented

- TransDuck sign-in using the shared iOS cookie store. Passwords are not persisted by this module.
- Google, Gemini Flash Lite, DeepSeek Flash, GPT Sol/Luna/Terra and Claude Opus/Sonnet/Haiku model selection. The module has no local daily watch or paid-model gate. Server-side authorization and quotas still apply.
- Searchable catalog of 603 Azure voices extracted from the provided extension, with Vietnamese HoaiMy and NamMinh first. Choosing a voice also selects its language. Voice availability still depends on the server.
- Native iPad panel with target language, translation domain, server-side translation-rule toggle, original-audio mute switch, dubbing volume, subtitle size, position, text color, background opacity, bilingual order and subtitle visibility.
- Native glossary, source text replacement and post-translation replacement manager for the selected domain and target language, with create, edit, enable/disable and confirmed deletion.
- Timed subtitles and Azure dubbing for YouTube videos that have subtitles. Translation and TTS process in batches prioritized around the current playback position. Overlapping subtitle times select the most recently started active cue. Audio is prefetched and decoded off the UI thread, and audio time follows the YouTube player when seeking, pausing or changing speed. The caption view reattaches when the native player view changes.
- Video summary with timestamps and details; tapping a row seeks in the native player.
- SRT subtitle editor. Saved user subtitles take priority on subsequent translation and summary requests.
- YouMod features, including its ad-removal hooks, remain in the tweak.

## Remaining differences from the browser extension

The browser extension targets many websites, DOM players and extension APIs. This module targets only the native YouTube app. It does not port the extension's pronunciation editor, all subtitle styling controls, voice-cloning controls, built-in glossary domain manager or every browser preference. Original YouTube audio is kept on by default; the app offers an on/off control rather than independent original-audio gain.

The user excluded local video, notification email and videos without existing subtitles. Those paths are not implemented.

## Validation boundary

The GitHub Actions workflow compiles the tweak for arm64. The latest build at commit `6e5046d` passed. Local packaging checks of the v6 unsigned IPA confirm ZIP integrity, unchanged YouTube Info.plist with iPad device family, unencrypted arm64 YouTube and tweak binaries, injected TransDuck symbols and CydiaSubstrate framework. The current test account signed in and read a 660-cue subtitle list with four overlapping intervals. The revised cue selection was compared with a brute-force reference at 8,960 time points; dynamic batch coverage was checked for 18 cases. A two-cue translation and Azure TTS request starting at subtitle index 300 returned complete results and HTTPS audio URLs. Earlier API checks with the supplied test account confirmed translation for all eight listed AI models, summary response shape and playable TTS URLs for sampled Vietnamese, English, Japanese and French voices. All three preference rule types were tested with temporary create/update/delete entries; cleanup was verified. These checks do not establish unlimited backend use or on-device playback quality. A signed install and playback test on the target iPad remain necessary.

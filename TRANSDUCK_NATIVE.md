# TransDuck inside YouTube for iPad

This branch adds a native TransDuck panel to YouMod's YouTube player overlay. It is built as an arm64 tweak and injected into a local, decrypted YouTube 21.38.3 IPA. The YouTube IPA and account credentials are never committed to this repository.

## Implemented

- TransDuck sign-in using the shared iOS cookie store. Passwords are not persisted by this module.
- Google, Gemini Flash Lite, DeepSeek Flash, GPT Sol/Luna/Terra and Claude Opus/Sonnet/Haiku model selection. The module has no local daily watch or paid-model gate. Server-side authorization and quotas still apply.
- Searchable catalog of 603 Azure voices extracted from the provided extension, with Vietnamese HoaiMy and NamMinh first. Choosing a voice also selects its language. Voice availability still depends on the server.
- Native iPad panel with target language, translation domain, server-side translation-rule toggle, original-audio mute switch, dubbing volume, subtitle size, bilingual display and subtitle visibility.
- Native glossary and text-replacement manager for the selected domain and target language, with create, edit, enable/disable and confirmed deletion.
- Timed subtitles and Azure dubbing for YouTube videos that have subtitles. Translation and TTS process in batches while playback continues. Audio is prefetched and decoded off the UI thread, and audio time follows the YouTube player when seeking, pausing or changing speed.
- Video summary with timestamps and details; tapping a row seeks in the native player.
- SRT subtitle editor. Saved user subtitles take priority on subsequent translation and summary requests.
- YouMod features, including its ad-removal hooks, remain in the tweak.

## Remaining differences from the browser extension

The browser extension targets many websites, DOM players and extension APIs. This module targets only the native YouTube app. It does not port the extension's pronunciation editor, all subtitle styling controls, voice-cloning controls, built-in glossary domain manager or every browser preference. Original YouTube audio is kept on by default; the app offers an on/off control rather than independent original-audio gain.

The user excluded local video, notification email and videos without existing subtitles. Those paths are not implemented.

## Validation boundary

The GitHub Actions workflow compiles the tweak for arm64. Local packaging checks confirm the IPA ZIP, YouTube binary, injected tweak and CydiaSubstrate framework. API checks with the supplied test account confirmed sign-in, translation for all eight listed AI models, summary response shape and playable TTS URLs for sampled Vietnamese, English, Japanese and French voices. Glossary and replacement create/update/delete calls were tested with temporary entries; cleanup was verified. These checks do not establish unlimited backend use or on-device playback quality. A signed install and playback test on the target iPad remain necessary.

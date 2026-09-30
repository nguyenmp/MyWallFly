# MyWallFly

A fly on the wall for your meetings. It listens to the microphone and to system audio, transcribes speech live, labels who spoke when, and streams the result to a web page.

**Status: design stage. No code yet.** Everything below is a decision, a reason, or an open question.

## What it does

- Listens to two sources at once: the microphone and system audio.
- Transcribes speech as it happens.
- Labels who spoke when (this is called diarization).
- Streams the transcript to a web UI.
- Sends audio to hosted AI providers, so the app stays light.
- Runs the server and web layer in Go.

## Why we need diarization

- In-person meetings put many people on one microphone.
- Remote people sharing a conference room are already mixed together before their audio reaches this machine.

## Decisions

1. **Capture in Swift with ScreenCaptureKit, not Go.** Go cannot capture system audio. ScreenCaptureKit is built into macOS and needs no driver. We rejected CoreAudio process taps: they are fragile and their low latency does not help us.
2. **Skip malgo**, the Go audio library. It cannot capture system audio, and the Swift helper can grab the microphone too. This keeps cgo out of the project.
3. **Send only speech.** Run voice detection first and send only speech to the provider. Meetings are mostly silence, and we pay per minute.
4. **Downsample to 16 kHz mono and stream it.** Do not hold raw audio in memory.
5. **Keep audio on the server.** The browser receives text only, over Server-Sent Events or a WebSocket.
6. **Store the transcript on disk.** SQLite is fine. Do not keep it in memory.
7. **Diarize twice.** A streaming diarizer labels speakers live for the UI. When the meeting ends, re-run the saved file through an offline model and replace the labels.
8. **Start with two tracks:** the microphone and one system-audio mix. Per-app audio and multiple microphones come later.

## Still open

- **Which hosted provider.** Streaming diarization support varies a lot between vendors. Test on our own audio before committing.
- **Which diarizer.** Streaming options cap at 4 speakers (Sortformer) or 8 (Nemotron-3-Diarization, LS-EEND). A large in-person meeting can exceed that.
- **Echo handling** for when the user is on speakers rather than headphones.
- **Named speakers.** The open pyannote community-1 model does not do voiceprints. That is a paid feature.

## Next step

Build the Swift capture helper first. It captures the microphone and system audio as two tracks, then sends 16 kHz mono PCM to the Go process over a pipe or socket. Prove that piece before anything else. It is the riskiest part, and it is the part Go cannot do.

## Traps

- **ScreenCaptureKit has no audio-only mode.** A tiny video stream always runs alongside it. Set it to 2x2 pixels at one frame per second and throw the frames away.
- **macOS permissions.** System audio needs Screen Recording approval. The microphone needs its own. There is no headless grant, so someone must click the prompt once. Check the permission live, not from a saved flag, because users can revoke it.
- **The two tracks do not line up.** They start at different moments and drift. Timestamp both from one clock and record each offset, or the speaker labels land on the wrong words.
- **System audio is capped at 48 kHz** by ScreenCaptureKit.
- **DRM-protected audio comes through silent.** Expect a bug report.
- **Provider sockets drop.** Decide now whether to buffer to disk or drop audio. Growing a memory buffer breaks the "light" goal.
- **Recording other people may require all-party consent,** depending on where your users are.
- **Speakers cause echo.** System audio leaks into the microphone and the same words show up twice.
- **Far-field audio is the hardest case.** Room echo and people talking over each other hurt diarization most. Published accuracy numbers will not match your room.

## Links

- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) — the macOS API for system audio capture.
- [malgo](https://github.com/gen2brain/malgo) — the Go audio library we rejected.
- [pyannote community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) — the offline diarizer, CC-BY-4.0, needs a Hugging Face token.
- [Streaming Sortformer](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2) — a streaming diarizer, up to 4 speakers.
- [Nemotron-3-Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization) — a streaming diarizer, up to 8 speakers.
- [LS-EEND](https://arxiv.org/html/2410.06670) — a streaming diarizer, up to 8 to 10 speakers.
- [Voxtral Realtime](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602) and [Kyutai STT](https://kyutai.org/stt/) — open streaming speech-to-text, if we ever run models ourselves.
- [NVIDIA Parakeet unified](https://huggingface.co/nvidia/parakeet-unified-en-0.6b) — one model for both offline and streaming speech-to-text.

## License

GNU Affero General Public License v3.0. See [LICENSE](LICENSE).

If you run this as a network service, the AGPL requires you to offer your modified source to your users.

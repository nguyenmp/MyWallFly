# MyWallFly

A fly on the wall for your meetings. It listens to the microphone and to system audio, transcribes speech live, labels who spoke when, and streams the result to a web page.

**Status: design stage. No code yet.** Everything below is a decision, a reason, or an open question.

## What it does

- Listens to two sources at once: the microphone and system audio.
- Transcribes speech as it happens.
- Labels who spoke when. This is called diarization.
- Streams the transcript to a web page.
- Sends audio to hosted AI providers, so the app stays light.
- Writes everything in Swift, as one process.

## Why we need diarization

- In-person meetings put many people on one microphone.
- Remote people sharing a conference room are already mixed together before their audio reaches this machine.

## Decisions

1. **Write the whole app in Swift, as one process.** One language, one build, and no pipe between two programs. Go added a second runtime and bought us nothing once we chose hosted diarization. Staying in Swift also keeps cgo out of the project.
2. **Capture audio with ScreenCaptureKit.** It ships with macOS, it needs no driver, and it is the only way to get system audio. Go cannot capture system audio at all. We rejected CoreAudio process taps: they are fragile, and their low latency does not help us. We rejected malgo too, because it cannot capture system audio either.
3. **Send only speech.** Run voice detection first, and send only speech to the provider. Meetings are mostly silence, and we pay per minute.
4. **Downsample to 16 kHz mono and stream it.** Do not hold raw audio in memory.
5. **Send the browser text only.** The page receives the transcript, never the audio, over Server-Sent Events or a WebSocket.
6. **Store the transcript on disk.** SQLite is fine. Do not keep it in memory.
7. **Diarize twice, both times with a hosted provider.** A streaming call labels speakers live for the page. When the meeting ends, send the saved audio again and replace the labels with the tighter batch result. Keep the audio on disk only until that second call finishes.
8. **Start with two tracks:** the microphone and one system-audio mix. Per-app audio and multiple microphones come later.
9. **The user brings their own key.** Each person signs up with the provider and supplies their own key. We never hold one, and we never pay for their audio. For now the app reads the key from a `.env` file in the project folder. Move it to the macOS Keychain when the app ships.
10. **Use Speechmatics as the provider.** It takes the live pass and the batch pass. We tested both on a real meeting and dropped Deepgram and AssemblyAI from the shortlist.
11. **Keep the provider's transcript as it comes. Never edit it.** Show the raw text plus the user's changes. The second pass at the end of a meeting replaces the speaker labels, and it would erase any change written into the raw text.
12. **Point changes at a time, not at a speaker name.** The live pass and the batch pass give the same voice different names, so a change marks a stretch of time on a track.
13. **Let people name speakers.** S1 becomes Mark once, and the name stays for the rest of the meeting.

## Edits

People need to fix the transcript, because diarization is not perfect. Three kinds of fix:

- Change who spoke in a stretch of time.
- Merge two speakers into one.
- Fix the words.

Two tables hold it all:

```sql
-- what the provider said, kept as it came
transcript_base (meeting_id, track, start_ms, end_ms, text, speaker_label)

-- what the user changed, applied on top
correction (meeting_id, kind, start_ms, end_ms, value, made_at)
```

`kind` is `speaker`, `merge`, or `words`. Each change gets a revision number so it can be undone. Warn the user that speaker names change when the second pass lands.

## Keys

- Every user signs up with the provider and supplies their own key. We never hold one, and we never pay for their audio.
- For now, keys live in a `.env` file in the project folder. Copy `.env.example` to `.env` and fill in the values.
- The `.gitignore` file ignores it. Check that stays true with `git check-ignore -v .env`. Never force-add the file.
- The app has to read the file itself. Swift gets no help here, so write a small loader that reads `.env` at startup and keeps any value already set in the real environment.
- A `.env` file is fine while we build. It is not good enough for a shipped app, because it sits in plain text next to the code.
- Move the key to the macOS Keychain before release. Add it with `security add-generic-password -a "$USER" -s MyWallFlySpeechmatics -w`.
- Never build a key into the app. Anyone can pull it out, and they would spend your money.
- Treat a key that has been pasted into a chat, an issue, or a log as public. Rotate it.

## Still open

- **Stream limits.** The Speechmatics trial allows 2 streams at once. Two tracks sent as two streams would use the whole quota for one user. Decide whether to mix the tracks or pay for more.
- **Speaker limits.** Live diarization caps vary a lot. Speechmatics allows 50. A large in-person meeting goes past the lower caps we saw elsewhere, so 50 is comfortable. Ask Speechmatics what happens at the limit: does it drop labels, or merge people?
- **One vendor or two.** Speechmatics covers both passes, so one vendor is easier to reason about. Two vendors means two bills and two sets of timestamps to line up.
- **The second pass.** Re-diarizing at the end of a meeting means sending the audio again. Budget for the second bill, and plan to delete the audio after it.
- **Echo handling** for when the user is on speakers rather than headphones.
- **Named speakers.** OpenAI's diarize model takes a reference clip of each person, which is the closest thing to naming speakers we have found. Check whether Speechmatics sells the same.

## Next step

Step 1 is done. Both passes work on a real meeting, so the capture helper is next.

1. Build the Swift capture helper. It captures the microphone and the system audio as two tracks, then sends 16 kHz mono PCM to the rest of the app with the start offset of each track. Prove this piece first. It is the riskiest code in the project.
2. Two quick checks, before or while you build: confirm the 6 speakers against the room you remember, and note what Speechmatics costs per minute.

## Traps

- **ScreenCaptureKit has no audio-only mode.** A small video stream always runs next to the audio. Set it to 2x2 pixels at one frame per second, and throw the frames away.
- **macOS permissions.** System audio needs Screen Recording approval, and the microphone needs its own. Someone must click each prompt once; there is no way to grant them from a script. Check the permission live rather than from a saved flag, because a user can revoke it at any time.
- **The two tracks do not line up.** They start at different moments and drift apart. Keep both on one clock and record each offset, or the speaker labels land on the wrong words.
- **ScreenCaptureKit caps system audio at 48 kHz.**
- **Audio with DRM protection comes through silent.** Expect a bug report about it.
- **Provider sockets drop.** Decide up front whether to buffer to disk or drop the audio. A memory buffer that keeps growing breaks the "stay light" goal.
- **Sending audio to a provider is a bigger deal than storing it yourself.** The recording leaves the machine, so the consent question is sharper. Depending on where your users are, recording other people may require all-party consent.
- **Speakers cause echo.** System audio leaks into the microphone, and the same words show up twice.
- **Far-field audio is the hardest case.** Room echo and people talking over each other hurt diarization most. Published accuracy numbers will not match your room.

## Considered, not using

We looked at running speech and speaker models ourselves. Hosted providers do the same work without a download, a GPU, or a Python runtime, so we are not using these for now.

- [pyannote community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) — offline diarizer, CC-BY-4.0, needs a Hugging Face token.
- [Streaming Sortformer](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2) — streaming diarizer, up to 4 speakers.
- [Nemotron-3-Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization) — streaming diarizer, up to 8 speakers.
- [LS-EEND](https://arxiv.org/html/2410.06670) — streaming diarizer, up to 8 to 10 speakers.
- [Voxtral Realtime](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602) and [Kyutai STT](https://kyutai.org/stt/) — open streaming speech-to-text.
- [NVIDIA Parakeet unified](https://huggingface.co/nvidia/parakeet-unified-en-0.6b) — one model for both offline and streaming speech-to-text.
- [malgo](https://github.com/gen2brain/malgo) — the Go audio library we rejected.

## Links

- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) — the macOS API for system audio capture.
- [Vapor](https://vapor.codes) and [Hummingbird](https://hummingbird.codes) — Swift web frameworks, for the page and the event stream.
- [GRDB](https://github.com/groue/GRDB.swift) — the SQLite library for Swift.

## License

GNU Affero General Public License v3.0. See [LICENSE](LICENSE).

If you run this as a network service, the AGPL requires you to offer your modified source to your users.

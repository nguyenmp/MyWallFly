# MyWallFly

A fly on the wall for your meetings. It listens to the microphone and to system audio, transcribes speech live, labels who spoke when, and streams the result to a web page.

**Status: capture works, and audio comes back from Speechmatics as a labelled transcript. Nothing is stored or shown in a page yet.** Everything below is a decision, a reason, or an open question.

## Try it now

The capture helper opens both tracks and hands the rest of the app 16 kHz mono PCM, along with where each track started. Run it and read the numbers:

```sh
swift run wallfly-capture-probe 20              # both tracks, 20 seconds
swift run wallfly-capture-probe 20 mic-only     # microphone only, no Screen Recording needed
swift run wallfly-capture-probe 20 --wav out    # also write out/mic.wav and out/system.wav
```

Speak, and play something out loud, so both tracks see audio. The microphone needs Microphone approval and system audio needs Screen Recording approval. Nothing can grant either one from a script: a person has to click the prompt once.

The library lives in `Sources/WallFlyCapture`, the command line check in `Sources/wallfly-capture-probe`.

### Transcribe a meeting

`Sources/WallFlyTranscribe` is the Speechmatics client, and `Sources/wallfly-transcribe` runs it. Copy `.env.example` to `.env`, put your key in it, then:

```sh
swift run wallfly-transcribe --check         # open a stream and stop: tests the key
swift run wallfly-transcribe 60              # both tracks, 60 seconds
swift run wallfly-transcribe 60 mic-only     # microphone only, one stream
swift run wallfly-transcribe 60 --partials   # also show words as they land
swift run wallfly-transcribe --file clip.wav # replay a recording, no microphone needed
swift run wallfly-transcribe 60 --verbose    # also log every message from the service
```

`--file` reads any format the system can decode, converts it to 16 kHz mono, and sends it at real time. It is the fastest way to prove the provider path: you get a transcript without a meeting, a microphone, or a permission prompt. To make a clip with two voices:

```sh
say -v Samantha -o /tmp/a.aiff "Hello, this is Samantha speaking."
say -v Daniel -o /tmp/b.aiff "And this is Daniel."
ffmpeg -y -i /tmp/a.aiff -i /tmp/b.aiff -filter_complex "[0:a][1:a]concat=n=2:v=0:a=1" -ar 16000 -ac 1 -c:a pcm_s16le /tmp/two.wav
swift run wallfly-transcribe --file /tmp/two.wav
```

The key is your own. The app never holds one and never pays for your audio. Never paste a key into a chat, an issue, or a log: treat any key that has been pasted as public and rotate it.

Each track goes to its own stream, so the service diarizes each input on its own. Before any real audio, the pipe sends silence at the front of whichever track started later. That puts both streams on the meeting clock, so a timestamp from the service is already a meeting timestamp.

Two streams at once uses the whole Speechmatics trial quota, which allows two. Mixing the tracks instead is still an open question below.

### Run the checks

```sh
swift test
```

The tests need no key and no network. They cover reading a `.env` file, the start message, every message the service sends back, and the rules that join words into transcript lines. They use `swift-testing`, which ships with the toolchain, so a full Xcode install is not needed.

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

## Where we are

The provider test is done. Both passes work on a real meeting. The capture spike answered the riskiest questions, and the real capture helper is now built and running. It opens the microphone and the system audio as two tracks and hands the rest of the app 16 kHz mono PCM, with the start offset of each track.

What the spike and the helper found on real hardware:

- Both tracks work. The mic arrives at 16 kHz mono 16-bit, the format we want, with no conversion.
- System audio arrives at 48 kHz stereo, 32-bit float, one array per channel. It needs a mix down to mono and a drop to 16 kHz.
- The two tracks run on different clocks. Pick one clock — the host clock — and line both tracks up on it. Measure each track's offset at the start of every meeting, because it changes from run to run. We measured 80 to 90 ms between the two tracks on every run.
- A buffer's arrival time is late by about one buffer, and the two tracks use different buffer sizes. So the offset is only good to about 20 ms. That is close enough to tell who spoke.

The pipe to Speechmatics is now built. `Sources/WallFlyTranscribe` opens one real-time stream per track, sends the audio, and turns the replies into transcript lines with speaker labels. It lines the two streams up on the meeting clock by sending silence at the front of whichever track began later. The `wallfly-transcribe` command runs the whole thing.

What is proven:

- 37 tests pass with no key and no network. They cover the `.env` reader, the start and end messages, every message the service sends back, and the rules that join words into lines.
- A bad key comes back as "Not Authorized" in about a second, not as a hang.
- Two voices replayed through the provider came back as two lines, labelled S1 and S2, with the words right.
- A live twelve second run on both tracks reached the provider and ended cleanly: 1841 buffers, none dropped.

What is not:

- No real meeting has been run. That needs the microphone and Screen Recording approvals. They are granted on this machine now, and a live run does open both tracks, but a silent room proves nothing about accuracy.
- The per-minute cost and the long-run drift are still unmeasured. The twelve second run showed 32 ms of drift on the system track, which says nothing at that length.
- Nothing is stored and no page shows the transcript. The live speaker labels are not yet replaced by the end-of-meeting batch pass; that pass is not written.

## Next step

1. Run `wallfly-transcribe` on a real meeting, ten minutes or longer. That answers two open questions at once: does a long run drift, and does the transcript match the room.
2. Confirm the speaker count against the room you remember, and note what Speechmatics costs per minute.
3. Add voice detection before the provider. Every frame is sent today, silence included, and decision 3 says to skip silence because we pay per minute.
4. Store the transcript in SQLite, then add the second pass that replaces the live speaker labels with the tighter batch result.

The spike has been deleted. Its settings and its permission code now live in the helper, so they exist in one place only. Never keep two copies of that code: they drift apart and you fix the same bug twice.

## Traps

- **A muted output gives silent system audio, and it looks healthy.** ScreenCaptureKit taps the sound after the volume and mute stage. With the output muted, the system track records exact zeros: buffers arrive on time, at the right size, carrying nothing. Check the mute state before you believe a silent track, and before you blame your own code. This cost us an hour.
- **Read the audio the way the system means it, not the way it reads.** `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` returns -12737, "array too small", for both tracks here, no matter how much room you offer. Copy with `CMSampleBufferCopyPCMDataIntoAudioBufferList` instead and mix down yourself. Also check the real format rather than trusting it: the microphone sends 16 kHz mono 16-bit, and system audio sends 48 kHz stereo 32-bit float, one array per channel.
- **ScreenCaptureKit has no audio-only mode.** A small video stream always runs next to the audio. Set it to 2x2 pixels at one frame per second, and throw the frames away.
- **macOS permissions.** System audio needs Screen Recording approval, and the microphone needs its own. Someone must click each prompt once; there is no way to grant them from a script. Check the permission live rather than from a saved flag, because a user can revoke it at any time.
- **The two tracks do not line up.** They start at different moments and drift apart. Keep both on one clock and record each offset, or the speaker labels land on the wrong words.
- **ScreenCaptureKit caps system audio at 48 kHz.**
- **Audio with DRM protection comes through silent.** Expect a bug report about it.
- **Provider sockets drop.** Decide up front whether to buffer to disk or drop the audio. A memory buffer that keeps growing breaks the "stay light" goal.
- **Sending audio to a provider is a bigger deal than storing it yourself.** The recording leaves the machine, so the consent question is sharper. Depending on where your users are, recording other people may require all-party consent.
- **Speakers cause echo.** System audio leaks into the microphone, and the same words show up twice.
- **Far-field audio is the hardest case.** Room echo and people talking over each other hurt diarization most. Published accuracy numbers will not match your room.
- **Speechmatics reads text frames as control messages and binary frames as audio.** Send the start message as bytes and the service answers "Unable to process the audio binary message, the recognition session handshake was not completed yet". It looks like a key or permission problem and it is neither. `startMessage()` returns a `String` now, so the mistake does not compile.
- **The end message must name the last audio chunk.** Bare `{"message":"EndOfStream"}` is rejected by the service schema, and the service then drops the words it was still holding: every meeting loses its last few seconds. The reply is easy to miss, because the words simply never arrive. Send `last_seq_no`, the count of audio frames sent, which the service echoes in every `AudioAdded`.
- **A final transcript message is not a whole line.** The service commits a final every second or two, so one sentence arrives as several of them. Joining them at the `EndOfUtterance` message, and when the speaker changes, gives one line per turn. Without that the transcript is a column of two word fragments.
- **A Command Line Tools install can fail to load the swift-testing macros.** With no full Xcode, `swift test` sometimes stopped with "plugin for module 'TestingMacros' not found". That is a toolchain problem, not a test failure, and it hit about a third of runs. `Package.swift` now points the compiler straight at the plugin directory, which fixed it. If it comes back, check that the directory still exists.

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

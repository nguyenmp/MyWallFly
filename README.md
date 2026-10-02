# MyWallFly

A fly on the wall for your meetings. It listens to the microphone and to system audio, transcribes speech live, labels who spoke when, and streams the result to a web page.

**Status: capture works, the transcript comes back from Speechmatics with speaker labels, and a run shows it live in a browser page. Nothing is stored in a database yet, and no audio is read back for the end-of-meeting pass.** Everything below is a decision, a reason, or an open question.

## Try it now

The capture helper opens both tracks and hands the rest of the app 16 kHz mono PCM, along with where each track started. Run it and read the numbers:

```sh
swift run wallfly-capture-probe 20              # both tracks, 20 seconds
swift run wallfly-capture-probe 20 mic-only     # microphone only, no Screen Recording needed
swift run wallfly-capture-probe 20 --out        # also write WAV files here
swift run wallfly-capture-probe 20 --out out    # also write them to out/
```

`--out` on its own writes to the folder you run from. With a folder after it, it writes there. Each run names its files after the moment it started, so runs never overwrite each other and the two tracks of one run sort side by side:

```
out/wallfly-2026-10-01T20-30-46Z-mic.wav
out/wallfly-2026-10-01T20-30-46Z-system.wav
```

It prints each path as it opens the file, and again at the end with how much audio it holds. Buffers go straight to disk, so a long run stays out of memory.

Speak, and play something out loud, so both tracks see audio. The microphone needs Microphone approval and system audio needs Screen Recording approval. Nothing can grant either one from a script: a person has to click the prompt once.

The library lives in `Sources/WallFlyCapture`, the command line check in `Sources/wallfly-capture-probe`.

### Transcribe a meeting

`Sources/WallFlyTranscribe` is the Speechmatics client, and `Sources/wallfly-transcribe` runs it. Copy `.env.example` to `.env`, put your key in it, then:

```sh
swift run wallfly-transcribe --check         # open a stream and stop: tests the key
swift run wallfly-transcribe                 # listen until you press Ctrl-C
swift run wallfly-transcribe 60              # stop by itself after 60 seconds
swift run wallfly-transcribe mic-only        # microphone only, one stream
swift run wallfly-transcribe --file clip.wav # replay a recording, no microphone needed
swift run wallfly-transcribe --out runs/monday # write into that folder instead
swift run wallfly-transcribe --final-only    # do not follow the words being spoken
swift run wallfly-transcribe 60 --verbose    # also log every message from the service
swift run wallfly-transcribe --no-open       # do not open the browser
swift run wallfly-transcribe --port 8765     # serve the page on a fixed port
```

Lines appear as people talk. Nothing waits for the meeting to end.

The line being written sits at the bottom and grows as the service settles it. The words still being spoken follow it, after a `…`. When the speaker changes or pauses, the line is finished and scrolls up.

```
[   0.00s] mic S1: Hello. This is Samantha speaking. We are testing the transcription pipe. And
[   4.68s] mic S2: this is Daniel. Let us see whether the labels come
   … mic S2: out right
```

Press Ctrl-C to stop. It stops in about a third of a second, flushes the last words, and prints the totals. Give it a number if you would rather it stop on its own.

`--partials` adds the words in progress when the output is not a terminal, for example in a log.

### The transcript page

A run also opens the transcript in your browser and shows the meeting there. Settled lines appear as they land, and each track keeps one line for the words still being spoken. The page is the same one the edits are designed for (see "Edits"), so a run and a saved transcript look alike.

The page is served from this machine on the loopback address, on a port picked at random. Only text crosses to it: the audio never leaves the machine (decision 5). Closing the tab does not stop the run, and opening the tab late shows everything so far.

`--no-open` leaves the browser alone and just prints the address. `--port` pins the port, which is handy when you want to reload the page yourself.

### What a run writes

Every run makes a folder named after the moment it started:

```
2026-10-01T20-44-25Z/
  transcript.txt   the transcript as it stands, kept up to date live
  mic.wav          what the microphone heard
  system.wav       what the speakers played
```

The name is the run's start time in UTC, so two runs never land on top of each other. The run prints the folder and each path at the start, and each file again at the end with its length.

The audio is kept because the second pass at the end of a meeting needs it: the tighter batch result replaces the live speaker labels. Delete the folder once that pass is done.

Buffers go straight to disk as they arrive, so a long meeting never sits in memory.

`--out` moves the folder. Point it at a folder and everything goes there. Point it at a path ending in `.txt` and you get that transcript file on its own, with no audio and no folder:

```sh
swift run wallfly-transcribe --out runs/monday   # a folder with a name you choose
swift run wallfly-transcribe --out notes.txt     # one transcript file, no audio
```

### Reading the transcript while it runs

`transcript.txt` always holds the transcript as it stands: every settled line, plus the words still being spoken on the last line.

```
[   0.00s] mic S1: Hello. This is Samantha speaking. We are testing the transcription pipe. And
   … mic S2: Let us see whether the labels come
```

The service settles a turn in pieces, every second or two. Each piece joins the line above it, so one turn still reads as one line, and the line is rewritten in place as it grows. Nothing is appended for it, and the file does not grow while one line is being spoken.

A line ends when the speaker changes, or after a pause. That is when its timestamp is fixed and the next line starts below it.

The open line, the one with the `…`, holds only the words that have not settled. The service trims the words it has already committed off the front of each partial, so only the new ones show, using the word times to tell them apart. The settled words are already in the line above. Nothing is lost and nothing repeats.

One thing does look unsettled: the speaker label can flip between two similar voices while a sentence is still being decided. The settled lines are the ones to trust.

`--final-only` does not follow the words being spoken, so no `…` line appears. Settled pieces still arrive as the service sends them.

Notes about the run — settings, totals, warnings — go to standard error, so the transcript is the only thing on standard output. The in-place update needs a real file to seek in, so write to one with `--out`. If you redirect standard output instead, lines are added as they settle:

```sh
swift run wallfly-transcribe > notes.txt      # added lines, no in-place update
swift run wallfly-transcribe --out notes.txt  # one open line, rewritten in place
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
5. **Send the browser text only.** The page receives the transcript, never the audio, over Server-Sent Events. A run serves the page and the stream from the same small HTTP server on the loopback address.
6. **Store the transcript on disk.** SQLite is fine. Do not keep it in memory.
7. **Diarize twice, both times with a hosted provider.** A streaming call labels speakers live for the page. When the meeting ends, send the saved audio again and replace the labels with the tighter batch result. Keep the audio on disk only until that second call finishes.
8. **Start with two tracks:** the microphone and one system-audio mix. Per-app audio and multiple microphones come later.
9. **The user brings their own key.** Each person signs up with the provider and supplies their own key. We never hold one, and we never pay for their audio. For now the app reads the key from a `.env` file in the project folder. Move it to the macOS Keychain when the app ships.
10. **Use Speechmatics as the provider.** It takes the live pass and the batch pass. We tested both on a real meeting and dropped Deepgram and AssemblyAI from the shortlist.
11. **Keep the provider's transcript as it comes. Never edit it.** Show the raw text plus the user's changes. The second pass at the end of a meeting replaces the speaker labels, and it would erase any change written into the raw text.
12. **Point changes at a time, not at a speaker name.** The live pass and the batch pass give the same voice different names, so a change marks a stretch of time on a track.
13. **Let people name speakers.** S1 becomes Mark once, and the name stays for the rest of the meeting.
14. **Give every run its own folder, named after the moment it started.** Putting the run's start time in the name is simpler than a queue of numbers, it keeps two runs apart without any bookkeeping, and it sorts by itself. The folder holds the transcript and each track's audio.
15. **Write WAV files at 16 kHz mono.** The provider says that is the format it handles best, and it is what capture already produces, so nothing has to be converted and nothing has to be encoded. See "Do we need a compressed format?" below.

## Edits

People need to fix the transcript, because diarization is not perfect. Three kinds of fix:

- Change who spoke in a stretch of time.
- Merge two speakers into one.
- Fix the words.

### Every change points at a time

A change marks a stretch of time on a track. It never marks a place in the text.

The rest of the design follows from this rule. The provider's words are kept as they came and are never edited. The end-of-meeting pass rewrites both the text and the labels. A change stored as character positions would break as soon as the text shifts. A change stored as a time does not move.

Speechmatics already gives the time of each word, so turning a highlight on the page into a start and an end time is straightforward.

### Pieces tile the timeline

The transcript is a row of pieces. A piece is a stretch of time with one speaker. The pieces cover the meeting with no gaps and no overlaps.

A change to part of a turn splits it. Reassign the middle of a turn from Mark to Sarah, and one piece becomes three:

- `0:00–0:05` Mark
- `0:05–0:07` Sarah
- `0:07–0:10` Mark

This is why two changes never fight over a moment. Each piece already belongs to one speaker, so the next change just splits the piece it lands in. There is no tie to break, and no rule for who wins.

### Two tables and one rule for using them

```sql
-- what the provider said, kept as it came
transcript_base (meeting_id, track, start_ms, end_ms, text, speaker_label)

-- what the user changed, applied on top
correction (meeting_id, revision, track, kind, start_ms, end_ms, value, made_at)
```

`kind` is `speaker`, `merge`, or `words`. Each change gets a revision number.

Stored changes can overlap: someone can edit a stretch, then edit it again. The applied result never overlaps. Apply the changes in revision order, and rebuild the pieces each time. The last change to touch a moment sets the speaker. Undo means replaying the list without that revision.

### The speaker list is a view, not a table

The list at the top of the page shows every speaker and the times they spoke. Build it from the pieces; do not store it. After the split above, Mark's entry goes from one time to two, with Sarah's between them, and nothing needs updating by hand.

### A merge is a record

Merging two speakers records that the two labels are one person. It does not rewrite the ranges where each one spoke. A record is one change to undo rather than one per turn, and it does not care which labels the current pass happens to use.

### The page

The transcript streams into an HTML page, text only and never audio (decision 5). The speaker list sits at the top. Six gestures cover the three kinds of fix:

- Rename a speaker. Type a name, and it applies to that speaker for the rest of the meeting.
- Merge two speakers. Drag one name onto another.
- Reassign a whole turn. Click the speaker on a line and pick a new one.
- Reassign a stretch. Highlight text, then pick a name.
- Add a speaker. Pick "New person" while reassigning, and name a voice the service did not tell apart.
- Fix the words. Type over them.

Four rules keep the page honest:

- **Only settled words take edits.** The open line's words are still changing, so they cannot be reassigned and cannot be typed over. Its speaker can be named while someone is talking, and the words take edits once they settle, a second or two later.
- **Show the track.** Each track is diarized on its own, so "S1" on the mic is not the same person as "S1" on system audio. The speaker list must say which track a name belongs to.
- **Warn when the second pass lands.** It replaces the live speaker labels, so the names a user set will move.
- **Keep an added speaker apart from the service's labels.** A speaker the reader adds carries a label like `new-1`, which the provider never sends, so a name the reader invented can never clash with a label the service picks later.

## Keys

- Every user signs up with the provider and supplies their own key. We never hold one, and we never pay for their audio.
- For now, keys live in a `.env` file in the project folder. Copy `.env.example` to `.env` and fill in the values.
- The `.gitignore` file ignores it. Check that stays true with `git check-ignore -v .env`. Never force-add the file.
- The app has to read the file itself. Swift gets no help here, so write a small loader that reads `.env` at startup and keeps any value already set in the real environment.
- A `.env` file is fine while we build. It is not good enough for a shipped app, because it sits in plain text next to the code.
- Move the key to the macOS Keychain before release. Add it with `security add-generic-password -a "$USER" -s MyWallFlySpeechmatics -w`.
- Never build a key into the app. Anyone can pull it out, and they would spend your money.
- Treat a key that has been pasted into a chat, an issue, or a log as public. Rotate it.

## Do we need a compressed format?

No, not now.

WAV at 16 kHz mono costs 115 MB per track per hour, so 230 MB for the two tracks of a meeting. A two hour meeting is about half a gigabyte. That sounds like a lot next to a compressed file, but the folder is deleted as soon as the end-of-meeting pass is done, so it never piles up on disk.

The provider is clear that 16-bit 16 kHz mono WAV is the best input. Anything else it transcodes on its own side, which trades disk space for server time. Capture already produces exactly that format, so WAV means no encoder, no decoder, and one file you can open in any tool.

If size ever does bite, the safe next step is FLAC. It is lossless, macOS can write it without a new dependency, and the batch API accepts it. Going lossy is a bigger change than it looks: the saved audio is what the second pass reads, and what a later provider change would read, so a lossy file puts a step between us and the only copy of the meeting.

What would change the answer: keeping the audio after the second pass, a provider that charges by upload size, or a meeting long enough that half a gigabyte matters.

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

The pipe to Speechmatics is now built. `Sources/WallFlyTranscribe` opens one real-time stream per track, sends the audio, and turns the replies into transcript lines with speaker labels. It lines the two streams up on the meeting clock by sending silence at the front of whichever track began later. The `wallfly-transcribe` command runs the whole thing, and writes the transcript and both tracks' audio into a folder named after the moment the run started.

What is proven:

- 48 tests pass with no key and no network. They cover the `.env` reader, the start and end messages, every message the service sends back, the rules that join words into lines, and the WAV writer.
- A bad key comes back as "Not Authorized" in about a second, not as a hang.
- Two voices replayed through the provider came back as two lines, labelled S1 and S2, with the words right.
- A live run on both tracks reaches the provider and ends cleanly: 1841 buffers, none dropped. Ctrl-C stops it in about a third of a second and the last words still arrive.

What is not:

- No real meeting has been run. That needs the microphone and Screen Recording approvals. They are granted on this machine now, and a live run does open both tracks, but a silent room proves nothing about accuracy.
- The per-minute cost and the long-run drift are still unmeasured. The twelve second run showed 32 ms of drift on the system track, which says nothing at that length.
- The page shows the transcript live, and the changes made on the page are kept beside the transcript in the run's folder (`edits.json`), so a reload or a crash does not lose them. Nothing is in a database yet. A run keeps the transcript and the audio on disk, but nothing reads the saved audio back: the second pass that replaces the live speaker labels with the tighter batch result is not written.

## Next step

1. Run `wallfly-transcribe` on a real meeting, ten minutes or longer. That answers two open questions at once: does a long run drift, and does the transcript match the room.
2. Confirm the speaker count against the room you remember, and note what Speechmatics costs per minute.
3. Add voice detection before the provider. Every frame is sent today, silence included, and decision 3 says to skip silence because we pay per minute.
4. Send the saved audio through the batch pass and replace the live speaker labels with the result. Delete the folder once that lands.
5. Store the transcript in SQLite, and save the changes made on the page.

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
- **A final transcript message is not a whole line.** The service commits a final every second or two, so one sentence arrives as several of them. Settling each one at once names a new speaker and puts them on the clock early, and folding neighbours back together keeps one line per turn. Waiting for `EndOfUtterance` instead made a new speaker wait for someone else to speak before they could be named.
- **Wait for `EndOfTranscript`, not for the socket to close.** The service sends everything it has, then keeps the socket open. Waiting for the close made Ctrl-C take five seconds instead of a third of one. Treat `EndOfTranscript` as the end of the meeting.
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

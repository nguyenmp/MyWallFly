# Capture spike

Throwaway code. It answers one question before we design the real capture helper:

**Can we get the microphone and system audio as two tracks, and can we record where each one starts on one shared clock?**

The answer is yes, with caveats. Those caveats now live in the Next step section of the [top-level README](../../README.md), because this folder is going away once the real capture helper works.

It does not convert audio, store audio, or talk to a provider. It prints numbers.

## Run it

```sh
cd spike/capture-offset
swift run capture-offset 20          # both tracks, 20 seconds
swift run capture-offset 20 mic-only # microphone only, no Screen Recording needed
```

Talk, and play something out loud, so both tracks see audio.

## What you need to grant first

- **Microphone.** The run asks for it the first time.
- **Screen Recording.** System audio needs it. The run asks, and then you grant it in System Settings and run again.

No script can grant either one. Someone has to click the prompt.

## What to look for

- **Offsets.** Each track prints the host time of its first buffer. The gap between them is the offset to record.
- **Format.** The microphone should print `16000 Hz, 1 ch, 16-bit int`. System audio should print `48000 Hz` — ScreenCaptureKit caps it there.
- **Drift.** Each track prints how far its own clock has moved from the host clock. If this grows over a long run, the two tracks will not line up on their own.
- **Video frames.** ScreenCaptureKit sends video next to the audio. The count at the end shows how many frames we paid for and threw away.

## One trap this code already hit

`AVCaptureAudioDataOutput` holds its delegate weakly. A delegate kept in a local variable dies as soon as that scope ends, and no audio ever arrives. The delegate is a top-level value here for that reason.

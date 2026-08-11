# ScaleBench Help

ScaleBench records Bluetooth scale data and turns it into a repeatable quality score. Use it when you want to compare scales, protocols, firmware builds, or Bluetooth behavior.

## Quick start

1. Turn on the scale.
2. Open ScaleBench.
3. Tap **Scan**.
4. Tap your scale when it appears.
5. Leave **Scoring** on **ScaleBench Standard v1** for public/comparable results.
6. Choose a recording mode.
7. Tap **Start Recording**.
8. Run the test.
9. Tap **Stop and View Results**.
10. Save the recording, export JSON, or export the official scorecard.

## Which mode should I use?

Most users should start with **Shot / Pour**.

| Mode | Use it for | What to do |
| --- | --- | --- |
| **Shot / Pour** | Normal public comparison score | Start before the shot or pour, stop after it finishes. |
| **Idle Stability** | Noise, drift, and still-scale behavior | Leave the scale untouched for 30–60 seconds. |
| **Tare Latency** | Capturing tare behavior | Start recording, trigger tare, wait for it to settle, stop recording. |
| **Transport Stress** | Bluetooth gap/jitter testing | Move the phone, change distance, or add interference while recording. |
| **Battery Logging** | Battery telemetry capture | Leave the scale running while battery values are reported. |

The modes label the recording and select the appropriate stability calculation. Idle Stability scores noise and drift; the dynamic modes avoid treating normal weight movement as drift. They do not yet run fully guided test procedures.

## What happens when I start recording?

ScaleBench opens a live recording screen showing:

- elapsed recording time
- parsed sample count
- raw packet count
- latest weight
- flow, if available
- battery, if available

This confirms that the app is actively recording.

## What happens when I stop?

ScaleBench shows a results screen with:

- score for the selected profile, clearly marked as Standard v1 or custom
- duration
- protocol
- sample and packet counts
- effective sample rate
- p95 packet interval
- max packet gap
- long gaps
- rejected packets
- a short explanation of what affected this recording

From there you can save, export JSON, export the official scorecard, or open the score explanation.

## Saved recordings

Saved recordings keep:

- raw BLE packets
- parsed samples
- score snapshot
- scoring profile
- recording mode
- device/protocol identity
- notes

Tap a saved recording to open its detail view.

## Packet visualizer

The packet visualizer explains why a recording scored well or poorly.

Color meaning:

| Color | Meaning |
| --- | --- |
| Blue | normal parsed weight packet |
| Green | battery or metadata packet |
| Purple | capability or command acknowledgement packet |
| Orange | warning or near-threshold interval |
| Red | score-impacting problem, such as rejected packet or long gap |
| Gray | unknown packet |

The visualizer includes:

- **Score evidence**: counts of rejected packets, long gaps, missing sequence steps, timestamp issues, bump flags, and near gaps.
- **Weight stream**: parsed weight over time.
- **Packet cadence**: interval before each parsed sample, with the long-gap threshold marked.
- **Packet timeline**: dense packet raster showing where normal packets, metadata, warnings, and penalties occurred.
- **Packet inspector**: tap packet chips to inspect raw hex, UUID, interval, and score evidence.

## Official scorecards

The official scorecard always uses **ScaleBench Standard v1**, even if you are viewing or experimenting with a custom scoring profile.

Use official scorecards for tester comparisons and public claims.

## JSON export

Use JSON export when you want deeper analysis or want to share the full recording with someone else.

The JSON includes raw packets, parsed samples, protocol identity, notes, scoring profile, and calculated metrics.

## Troubleshooting

### I do not see my scale

- Make sure Bluetooth is enabled.
- Power-cycle the scale.
- Tap **Scan** again.
- Keep the phone close to the scale.
- Check whether another app is already connected to the scale.

### The score is lower than expected

Open the saved recording and check:

- red packet markers
- long-gap count
- rejected packet count
- max gap
- p95 interval
- packet cadence chart

Low phone power mode, poor Bluetooth conditions, distance, interference, and app backgrounding can all affect the score.

### Battery is missing

Not every scale exposes battery over Bluetooth. ScaleBench can only show battery when the connected protocol provides it.

### Flow is missing

Flow appears only when the scale or protocol reports it. Otherwise ScaleBench records weight and packet timing.

### Saved recordings are local

Saved recordings are stored locally on the device. Export JSON if you want a portable copy.

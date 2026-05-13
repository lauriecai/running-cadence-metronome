# iOS Audio Regression Isolation Plan

## Goal
Identify exactly which runtime change caused iPhone background playback to regress.

## Scope
- Read-only diagnosis and controlled A/B testing order
- No product behavior redesign in this phase
- Record outcomes for each step before proceeding

## Latest Findings To Fold In
- The committed iOS “persist audio” commit (`288846e`) did not materially change iOS playback persistence logic.
- Current iOS regression is more likely from subsequent local runtime-recovery edits (observer/recovery churn risk).

## Test Matrix
- Devices:
  - iPhone (current iOS target)
- Routes:
  - Built-in speaker
  - Bluetooth headphones
- App state transitions:
  - Home button/swipe away from app
  - Foreground return

## Baseline Capture (before toggles)
1. Confirm current behavior on iPhone with representative BPM/preset/volume.
2. Capture logs around:
   - session activation success/failure
   - interruption begin/end
   - route-change reason
   - engine running state
3. Note exact failure trigger:
   - immediate stop on background
   - delayed stop after N seconds/minutes
   - stop only on specific route
4. Capture route snapshot at failure moments:
   - current output route type
   - whether Bluetooth is connected/selected
5. Verify session ordering at each playback start path:
   - `setCategory(...)` happens before activation
   - activation succeeds before calling `play` / enabling render

## iPhone Isolation Order (highest signal first)
0. **Trace anchor check (commit vs local)**
   - Compare `RunningCadenceMetronomeIOS/MetronomeAudioService.swift` at `288846e` to current working copy.
   - Treat current uncommitted recovery logic as primary suspect until disproven.

1. **A/B: recovery observers OFF vs ON**
   - Compare current iOS `MetronomeAudioService` with a variant that removes runtime recovery handlers:
     - interruption observer
     - route-change observer
     - engine-config observer
     - didBecomeActive observer
   - Hypothesis: regression is introduced by recovery churn loops.

2. **A/B: route-change handling granularity**
   - Keep observers, but remove `.categoryChange` from the recovery-trigger set.
   - Hypothesis: category changes are self-induced and repeatedly trigger restart/reschedule.

3. **A/B: engine restart aggressiveness**
   - Keep session reactivation but skip unconditional `engine.stop()` + `engine.start()` in recovery.
   - Hypothesis: full restarts in background destabilize scheduled buffers.

4. **A/B: scheduling resilience**
   - Compare timer-driven refill (`asyncAfter`) vs completion-driven refill for `AVAudioPlayerNode` queue upkeep.
   - Hypothesis: background timer throttling plus recovery churn leads to starvation.

5. **Session-order sanity pass**
   - Ensure iOS start/recover path keeps strict ordering:
     - category set
     - session active
     - engine/player start
   - Reject variants that recover “eventually” but violate ordering.

6. Promote the first variant that restores persistence with minimal complexity.

## Acceptance Criteria
- iPhone: ticks continue for 2+ minutes while app is backgrounded.
- No restart loops or repeated session/category churn in logs.
- Session-order invariant holds in logs for all playback entry points (start/recover/restart).

## Deliverables
- One-page findings summary:
  - failing variant(s)
  - passing variant(s)
  - minimal fix set
  - route limitations/user messaging requirements

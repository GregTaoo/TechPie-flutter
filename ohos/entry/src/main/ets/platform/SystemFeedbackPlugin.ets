import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos';
import MethodChannel, { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import vibrator from '@ohos.vibrator';
import deviceInfo from '@ohos.deviceInfo';
import { BusinessError } from '@kit.BasicServicesKit';

/** One vibration pulse, as the Dart side sends it (lib/utils/haptics.dart). */
interface FeedbackPulse {
  atMs: number;
  durationMs: number;
  intensity: number;
}

/**
 * Plays the app's waveforms on HarmonyOS NEXT.
 *
 * The engine's own HapticFeedback answers every type with one fixed vibration —
 * 100 ms for a selection click, 150 ms for a medium impact, both at full
 * strength — so a light tap and a held button feel the same, and both feel like
 * a long buzz. This plugin is told what to play instead of asked to decide:
 *
 *  - The two designed patterns (`paymentSuccess`, `networkDisconnected`) on an
 *    HD motor: the whole pattern goes to the motor in one piece, with the
 *    intensity each pulse asked for (`VibratorPatternBuilder`) — these are the
 *    only waveforms whose strength carries meaning.
 *  - Everything else, and any device that will not take a pattern: the pulses
 *    are scheduled as short `time` vibrations. Durations stay ours, intensity
 *    does not, so those play at the device's own strength — which is what the
 *    light ticks want anyway.
 *  - A device that refuses either: nothing. Feedback never fails the action that
 *    asked for it, and it is not faked with a fallback that would feel different
 *    again.
 *
 * Sound is not played here: the OHOS engine's `playSystemSound` is an empty
 * implementation, so a sound path would have to be written from scratch.
 */
export default class SystemFeedbackPlugin implements FlutterPlugin, MethodCallHandler {
  /**
   * The version the pattern types arrive with (`VibratorPatternBuilder`,
   * `VibratorPattern`, and their events are documented from API 18; the
   * reference also carries an API 22 revision of the effect form). A device that
   * will not take it is caught and replayed on the scheduled path, so the
   * ambiguity costs a call, never the feedback.
   */
  private static readonly HD_PATTERN_API = 18;
  /**
   * The waveforms whose strength carries meaning — a card payment landing, and
   * the app noticing it went offline. The light ticks are deliberately not here:
   * their feel comes from the duration, and the scheduled path already plays
   * that exactly.
   */
  private static readonly DESIGNED_PATTERNS: string[] = [
    'paymentSuccess',
    'networkDisconnected',
  ];
  /** A pulse this short reads as a tick; anything longer is a sustained event. */
  private static readonly TRANSIENT_MS = 24;
  /**
   * The shortest pulse this platform will actually play. The waveform set is
   * built from pulses of 5-20 ms (that is what makes them ticks), and asking for
   * 5 ms on a phone here produced nothing at all — the shortest that was felt
   * was around 20 ms, so that is the floor we send.
   */
  private static readonly MIN_PULSE_MS = 20;
  private static readonly MAX_PULSE_MS = 60;
  /** Capability not supported: stop asking this device for vibrations. */
  private static readonly ERROR_UNSUPPORTED = 801;

  private channel: MethodChannel | null = null;
  private timers: number[] = [];
  private unsupported: boolean = false;
  private hdChecked: boolean = false;
  private hdSupported: boolean = false;
  private described: boolean = false;

  getUniqueClassName(): string {
    return 'SystemFeedbackPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'techpie/feedback');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.cancel();
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'play') {
      result.notImplemented();
      return;
    }
    this.cancel();
    const vibration = call.argument('vibration') === true;
    const rawId: Object | null = call.argument('id');
    const id: string = typeof rawId === 'string' ? rawId as string : '';
    const pulses = this.parsePulses(call.argument('pulses'));
    this.describeDevice();
    if (vibration && !this.unsupported && pulses.length > 0) {
      const pattern = this.isDesigned(id) && this.canPlayPattern();
      console.info(`SystemFeedback: playing ${pulses.length} pulse(s) via ${pattern ? 'pattern' : 'time'}`);
      if (pattern) {
        this.playPattern(pulses);
      } else {
        this.playScheduled(pulses);
      }
    }
    result.success(null);
  }

  private parsePulses(raw: Object | null): FeedbackPulse[] {
    const pulses: FeedbackPulse[] = [];
    if (raw === null || raw === undefined) {
      return pulses;
    }
    try {
      for (const entry of raw as Object[]) {
        const pulse = entry as Map<string, Object>;
        const intensity = this.toNumber(pulse.get('intensity'));
        pulses.push({
          atMs: Math.max(0, Math.round(this.toNumber(pulse.get('atMs')))),
          durationMs: Math.round(this.toNumber(pulse.get('durationMs'))),
          intensity: Math.min(Math.max(intensity, 0), 1),
        });
      }
    } catch (error) {
      console.error(`SystemFeedback: could not read the waveform (${error})`);
    }
    return pulses;
  }

  private toNumber(value: Object | undefined): number {
    return typeof value === 'number' ? value as number : 0;
  }

  /** Whether this waveform is one of the two that want per-pulse strength. */
  private isDesigned(id: string): boolean {
    return SystemFeedbackPlugin.DESIGNED_PATTERNS.indexOf(id) >= 0;
  }

  /** What this phone can do, once, in the log a device test can be read from. */
  private describeDevice(): void {
    if (this.described) {
      return;
    }
    this.described = true;
    this.probeHd();
    console.info(`SystemFeedback: api=${deviceInfo.sdkApiVersion} hd=${this.hdSupported} ` +
      `designed=${SystemFeedbackPlugin.DESIGNED_PATTERNS.join('|')}`);
  }

  /** Whether the motor reports HD haptic support (API 19 or newer only). */
  private probeHd(): void {
    if (this.hdChecked) {
      return;
    }
    this.hdChecked = true;
    if (deviceInfo.sdkApiVersion < 19) {
      return;
    }
    try {
      const devices = vibrator.getVibratorInfoSync();
      this.hdSupported = devices.some((device) => device.isHdHapticSupported === true);
    } catch (error) {
      this.hdSupported = false;
    }
  }

  /** API 18 or newer, on a motor that reports HD haptic support. */
  private canPlayPattern(): boolean {
    if (deviceInfo.sdkApiVersion < SystemFeedbackPlugin.HD_PATTERN_API) {
      return false;
    }
    this.probeHd();
    return this.hdSupported;
  }

  private playPattern(pulses: FeedbackPulse[]): void {
    try {
      const builder = new vibrator.VibratorPatternBuilder();
      for (const pulse of pulses) {
        const duration = this.clampDuration(pulse.durationMs);
        if (duration <= SystemFeedbackPlugin.TRANSIENT_MS) {
          builder.addTransientEvent(pulse.atMs, { intensity: pulse.intensity });
        } else {
          builder.addContinuousEvent(pulse.atMs, duration, { intensity: pulse.intensity });
        }
      }
      vibrator.startVibration({ type: 'pattern', pattern: builder.build() }, { id: 0, usage: 'touch' })
        .catch((error: BusinessError) => {
          // A pattern this device will not take must not become silence: replay
          // the same pulses on the path that always works here.
          this.failed('pattern', error);
          this.hdSupported = false;
          this.playScheduled(pulses);
        });
    } catch (error) {
      // A device that cannot build the pattern at all: fall back for this play.
      this.hdSupported = false;
      this.hdChecked = true;
      this.playScheduled(pulses);
    }
  }

  /** One short vibration per pulse, scheduled on our own clock. */
  private playScheduled(pulses: FeedbackPulse[]): void {
    for (const pulse of pulses) {
      const duration = this.clampDuration(pulse.durationMs);
      if (pulse.atMs === 0) {
        this.buzz(duration);
      } else {
        this.timers.push(setTimeout(() => { this.buzz(duration); }, pulse.atMs));
      }
    }
  }

  private buzz(duration: number): void {
    vibrator.startVibration({ type: 'time', duration: duration }, { id: 0, usage: 'touch' })
      .catch((error: BusinessError) => { this.failed('time', error); });
  }

  private clampDuration(durationMs: number): number {
    if (durationMs < SystemFeedbackPlugin.MIN_PULSE_MS) {
      return SystemFeedbackPlugin.MIN_PULSE_MS;
    }
    if (durationMs > SystemFeedbackPlugin.MAX_PULSE_MS) {
      return SystemFeedbackPlugin.MAX_PULSE_MS;
    }
    return durationMs;
  }

  private failed(kind: string, error: BusinessError): void {
    if (error.code === SystemFeedbackPlugin.ERROR_UNSUPPORTED) {
      // Capability not supported: this device has no vibrator we can drive.
      this.unsupported = true;
      console.warn(`SystemFeedback: vibration is unsupported here (${kind})`);
      return;
    }
    console.error(`SystemFeedback: ${kind} vibration failed (${error.code})`);
  }

  private cancel(): void {
    for (const timer of this.timers) {
      clearTimeout(timer);
    }
    this.timers = [];
    vibrator.stopVibration().catch((error: BusinessError) => {
      // Nothing playing is not a failure.
      console.debug(`SystemFeedback: stop returned ${error.code}`);
    });
  }
}

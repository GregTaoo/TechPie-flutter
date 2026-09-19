import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos';
import MethodChannel, { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import vibrator from '@ohos.vibrator';
import deviceInfo from '@ohos.deviceInfo';
import fs from '@ohos.file.fs';
import media from '@ohos.multimedia.media';
import resourceManager from '@ohos.resourceManager';
import { BusinessError } from '@kit.BasicServicesKit';
import { Context } from '@kit.AbilityKit';

/** One vibration pulse, as the Dart side sends it (lib/utils/haptics.dart). */
interface FeedbackPulse {
  atMs: number;
  durationMs: number;
  intensity: number;
}

/** The haptic configuration file's shape, as the vibrator guideline defines it. */
interface HapticParameters {
  Intensity: number;
  Frequency: number;
}

interface HapticEvent {
  Type: string;
  StartTime: number;
  Duration?: number;
  Parameters: HapticParameters;
}

interface HapticPattern {
  Event: HapticEvent;
}

interface HapticChannel {
  Parameters: HapticChannelIndex;
  Pattern: HapticPattern[];
}

interface HapticChannelIndex {
  Index: number;
}

interface HapticMetaData {
  Version: number;
  ChannelNumber: number;
  Description?: string;
}

interface HapticDocument {
  MetaData: HapticMetaData;
  Channels: HapticChannel[];
}

/**
 * Plays the app's waveforms on HarmonyOS NEXT.
 *
 * The engine's own HapticFeedback answers every type with one fixed vibration —
 * 100 ms for a selection click, 150 ms for a medium impact, both at full
 * strength — so a light tap and a held button feel the same, and both feel like
 * a long buzz. This plugin takes the waveform instead and plays it through the
 * three forms the vibrator guideline actually defines:
 *
 *  - `time`: a fixed duration at the device's own strength. This is what the
 *    ticks use, and the shortest we send is 20 ms: the waveform set is built
 *    from 5-20 ms pulses, and 5 ms played nothing at all on the phone we tested.
 *  - `file`: a haptic configuration file — the guideline's custom-vibration
 *    form, available since API 10 — written from the pulses the Dart side sent,
 *    so per-pulse intensity and timing survive. The two designed patterns
 *    (`paymentSuccess`, `networkDisconnected`) use this, because they are the
 *    waveforms whose strength carries meaning.
 *  - `preset`: system effects (`haptic.clock.timer`, `haptic.notice.*`). Not
 *    used: their character is the system's, not the one we designed, and a
 *    device test is cheaper than guessing which ids exist on which phones.
 *
 * A device that will not take the file form is caught, replayed through `time`
 * in the same call, and remembered — a rejected form costs a call, never the
 * feedback. The motor-pattern builder (`VibratorPatternBuilder`) is deliberately
 * absent: the guideline does not use it for this, and on the hardware we can
 * test it played nothing at all.
 *
 * Sound: the engine's `playSystemSound` is an empty implementation, so the two
 * designed patterns play their asset through AVPlayer instead, from the copy the
 * build puts in the module's rawfile (`flutter_assets/<asset>`). A sound that
 * will not play is logged and dropped: it never takes the vibration with it.
 */
export default class SystemFeedbackPlugin implements FlutterPlugin, MethodCallHandler {
  /**
   * The shortest pulse this platform will actually play. Asking for 5 ms on a
   * phone here produced nothing at all; the shortest that was felt was around
   * 20 ms, so that is the floor we send.
   */
  private static readonly MIN_PULSE_MS = 20;
  private static readonly MAX_PULSE_MS = 60;
  /**
   * A pulse at or below this reads as a tick, and the guideline's `transient`
   * event is exactly that: a single short hit. Longer pulses are `continuous`,
   * which is the only form that takes a duration.
   */
  private static readonly TRANSIENT_MS = 24;
  /** Intensity and Frequency are both a percentage, 0-100. */
  private static readonly MAX_PERCENT = 100;
  /** `VibratorPatternBuilder` and its events arrive with API 18. */
  private static readonly PATTERN_API = 18;
  /** 55 is where a motor with frequency control reaches resonance. */
  private static readonly RESONANT_FREQUENCY = 55;
  /** Capability not supported: stop asking this device for vibrations. */
  private static readonly ERROR_UNSUPPORTED = 801;

  /**
   * The waveforms whose strength carries meaning — a card payment landing, and
   * the app noticing it went offline. The light ticks are deliberately not here:
   * their feel comes from the duration, and `time` already plays that exactly.
   */
  private static readonly DESIGNED_PATTERNS: string[] = [
    'paymentSuccess',
    'networkDisconnected',
  ];

  private channel: MethodChannel | null = null;
  private context: Context | null = null;
  private timers: number[] = [];
  private unsupported: boolean = false;
  private fileUnusable: boolean = false;
  private patternUnusable: boolean = false;
  private described: boolean = false;
  private readonly files: Map<string, string> = new Map();
  private soundPlayer: media.AVPlayer | null = null;
  private soundPath: string = '';
  private soundWatchdog: number = -1;
  /** Bumped whenever a sound is stopped or replaced, so a late player cannot
   *  stop the sound that replaced it. */
  private soundGeneration: number = 0;

  getUniqueClassName(): string {
    return 'SystemFeedbackPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'techpie/feedback');
    this.channel.setMethodCallHandler(this);
    this.context = binding.getApplicationContext();
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.cancel();
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.context = null;
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
    if (call.argument('sound') === true) {
      const rawAsset: Object | null = call.argument('soundAsset');
      const asset: string = typeof rawAsset === 'string' ? rawAsset as string : '';
      const durationMs = this.toNumber(call.argument('soundDurationMs'));
      this.playSound(asset, durationMs);
    }
    if (vibration && !this.unsupported && pulses.length > 0) {
      if (this.isDesigned(id)) {
        const file = this.hapticFile(id, pulses);
        if (file.length > 0) {
          console.info(`SystemFeedback: playing ${id} via file (${pulses.length} pulse(s))`);
          this.playFile(file, pulses);
          result.success(null);
          return;
        }
      }
      console.info(`SystemFeedback: playing ${id} via time (${pulses.length} pulse(s))`);
      this.playScheduled(pulses);
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

  private isDesigned(id: string): boolean {
    return SystemFeedbackPlugin.DESIGNED_PATTERNS.indexOf(id) >= 0;
  }

  /**
   * The haptic configuration file for a waveform, written once per id into the
   * app's cache directory. An empty string means it could not be written, and
   * the caller falls back to `time`.
   */
  private hapticFile(id: string, pulses: FeedbackPulse[]): string {
    if (this.fileUnusable) {
      return '';
    }
    const cached = this.files.get(id);
    if (cached !== undefined) {
      return cached;
    }
    const cacheDir = this.context?.cacheDir;
    if (cacheDir === undefined || cacheDir.length === 0) {
      return '';
    }
    try {
      const document = this.hapticDocument(id, pulses);
      const json = JSON.stringify(document);
      // Keyed by content, not only by name: a waveform we tune later must not
      // keep playing the file an older build wrote.
      const path = `${cacheDir}/techpie-haptics-${id}-${SystemFeedbackPlugin.fingerprint(json)}.json`;
      const previous = this.files.get(id);
      if (previous !== undefined && previous !== path) {
        this.remove(previous);
      }
      this.files.set(id, path);
      if (!fs.accessSync(path)) {
        const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, json);
        fs.closeSync(file);
      }
      return path;
    } catch (error) {
      console.error(`SystemFeedback: could not write the haptic file for ${id} (${error})`);
      this.fileUnusable = true;
      return '';
    }
  }

  /** A short, stable name for one configuration, so a changed one is a new file. */
  private static fingerprint(text: string): string {
    let hash = 2166136261;
    for (let index = 0; index < text.length; index++) {
      hash = ((hash ^ text.charCodeAt(index)) * 16777619) & 0xFFFFFFFF;
    }
    return hash.toString(16);
  }

  private remove(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (error) {
      console.debug(`SystemFeedback: could not remove ${path}`);
    }
  }

  private hapticDocument(id: string, pulses: FeedbackPulse[]): HapticDocument {
    const pattern: HapticPattern[] = [];
    for (const pulse of pulses) {
      const duration = this.clampDuration(pulse.durationMs);
      const parameters: HapticParameters = {
        Intensity: Math.max(1, Math.round(pulse.intensity * SystemFeedbackPlugin.MAX_PERCENT)),
        Frequency: SystemFeedbackPlugin.RESONANT_FREQUENCY,
      };
      if (duration <= SystemFeedbackPlugin.TRANSIENT_MS) {
        pattern.push({ Event: { Type: 'transient', StartTime: pulse.atMs, Parameters: parameters } });
      } else {
        pattern.push({
          Event: { Type: 'continuous', StartTime: pulse.atMs, Duration: duration, Parameters: parameters },
        });
      }
    }
    const channel: HapticChannel = { Parameters: { Index: 0 }, Pattern: pattern };
    return {
      MetaData: { Version: 1.0, ChannelNumber: 1, Description: `techpie ${id}` },
      Channels: [channel],
    };
  }

  private playFile(path: string, pulses: FeedbackPulse[]): void {
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const length = fs.statSync(path).size;
      vibrator.startVibration(
        { type: 'file', hapticFd: { fd: file.fd, offset: 0, length: length } },
        { id: 0, usage: 'touch' },
      )
        .then(() => { fs.closeSync(file); })
        .catch((error: BusinessError) => {
          // A file this device will not take must not become silence: the same
          // pulses are replayed on the other forms before giving up.
          this.failed('file', error);
          this.fileUnusable = true;
          fs.closeSync(file);
          this.playAfterFile(pulses);
        });
    } catch (error) {
      this.failed('file', error as BusinessError);
      this.fileUnusable = true;
      this.playAfterFile(pulses);
    }
  }

  /** What to do when the file form is not available here. */
  private playAfterFile(pulses: FeedbackPulse[]): void {
    if (deviceInfo.sdkApiVersion >= SystemFeedbackPlugin.PATTERN_API &&
        !this.patternUnusable) {
      console.info('SystemFeedback: falling back to the pattern form');
      this.playPattern(pulses);
      return;
    }
    this.playScheduled(pulses);
  }

  /**
   * The programming form of the same idea (the guideline's own sample): the
   * builder arrives with API 18. Its transient parameter wants the strength as a
   * percentage — 0-100, the same scale the configuration file uses — plus a
   * frequency and the channel index, and the attribute names the device.
   */
  private playPattern(pulses: FeedbackPulse[]): void {
    try {
      const builder = new vibrator.VibratorPatternBuilder();
      for (const pulse of pulses) {
        const duration = this.clampDuration(pulse.durationMs);
        const intensity = Math.max(1, Math.round(pulse.intensity * SystemFeedbackPlugin.MAX_PERCENT));
        if (duration <= SystemFeedbackPlugin.TRANSIENT_MS) {
          builder.addTransientEvent(pulse.atMs, {
            intensity: intensity,
            frequency: SystemFeedbackPlugin.RESONANT_FREQUENCY,
            index: 0,
          });
        } else {
          builder.addContinuousEvent(pulse.atMs, duration, {
            intensity: intensity,
            frequency: SystemFeedbackPlugin.RESONANT_FREQUENCY,
            index: 0,
          });
        }
      }
      vibrator.startVibration(
        { type: 'pattern', pattern: builder.build() },
        { id: 0, deviceId: -1, usage: 'touch' },
      )
        .catch((error: BusinessError) => {
          this.failed('pattern', error);
          this.patternUnusable = true;
          this.playScheduled(pulses);
        });
    } catch (error) {
      this.failed('pattern', error as BusinessError);
      this.patternUnusable = true;
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

  /** What this phone can do, once, in the log a device test can be read from. */
  private describeDevice(): void {
    if (this.described) {
      return;
    }
    this.described = true;
    console.info(`SystemFeedback: api=${deviceInfo.sdkApiVersion} ` +
      `designed=${SystemFeedbackPlugin.DESIGNED_PATTERNS.join('|')} file=${!this.fileUnusable}`);
  }

  private failed(kind: string, error: BusinessError): void {
    if (error !== undefined && error.code === SystemFeedbackPlugin.ERROR_UNSUPPORTED) {
      // Capability not supported: this device has no vibrator we can drive.
      this.unsupported = true;
      console.warn(`SystemFeedback: vibration is unsupported here (${kind})`);
      return;
    }
    console.error(`SystemFeedback: ${kind} vibration failed ` +
      `(${error === undefined ? 'unknown' : error.code})`);
  }

  /**
   * Plays one of the app's sound assets through AVPlayer, from the copy the
   * build leaves in the module's rawfile (`flutter_assets/<asset>` — the hap
   * carries it, verified).
   *
   * Fire and forget: a sound that fails is logged and dropped. It is never
   * surfaced to the caller and never takes the vibration with it, and the file
   * descriptor is closed when the player is released rather than right after the
   * call, so playback cannot read a closed file.
   */
  private playSound(asset: string, durationMs: number): void {
    const resources = this.context?.resourceManager;
    if (resources === undefined || asset.length === 0) {
      return;
    }
    const path = `flutter_assets/${asset}`;
    let descriptor: resourceManager.RawFileDescriptor;
    try {
      descriptor = resources.getRawFdSync(path);
    } catch (error) {
      console.error(`SystemFeedback: no sound asset at ${path} (${error})`);
      return;
    }
    this.soundPath = path;
    const generation = ++this.soundGeneration;
    media.createAVPlayer()
      .then((player: media.AVPlayer) => {
        if (generation !== this.soundGeneration) {
          // Superseded while the player was being created.
          player.release().catch((error: BusinessError) => {
            console.debug(`SystemFeedback: early release returned ${error.code}`);
          });
          return;
        }
        this.soundPlayer = player;
        player.on('stateChange', (state: string) => {
          if (generation !== this.soundGeneration) {
            return;
          }
          console.info(`SystemFeedback: sound state=${state}`);
          if (state === 'initialized') {
            // AVPlayer will not play straight from 'initialized': prepare first
            // and play once it is 'prepared' (playing early is 5400102,
            // "operation not allowed", which is what this used to do).
            player.prepare().catch((error: BusinessError) => {
              if (generation === this.soundGeneration) {
                this.soundFailed(error);
              }
            });
          } else if (state === 'prepared') {
            console.info(`SystemFeedback: playing sound ${asset}`);
            player.play().catch((error: BusinessError) => {
              if (generation === this.soundGeneration) {
                this.soundFailed(error);
              }
            });
          } else if (state === 'completed' || state === 'error') {
            this.stopSound();
          }
        });
        player.fdSrc = { fd: descriptor.fd, offset: descriptor.offset, length: descriptor.length };
        // Some devices never report completion; the declared window is the
        // authority, with a little room for the tail.
        const window = durationMs > 0 ? durationMs : 1000;
        this.soundWatchdog = setTimeout(() => {
          if (generation === this.soundGeneration) {
            this.stopSound();
          }
        }, window + 250);
      })
      .catch((error: BusinessError) => {
        if (generation === this.soundGeneration) {
          this.soundFailed(error);
        }
      });
  }

  private soundFailed(error: BusinessError): void {
    console.error(`SystemFeedback: sound failed ` +
      `(${error === undefined ? 'unknown' : error.code})`);
    this.stopSound();
  }

  private stopSound(): void {
    this.soundGeneration++;
    if (this.soundWatchdog !== -1) {
      clearTimeout(this.soundWatchdog);
      this.soundWatchdog = -1;
    }
    const player = this.soundPlayer;
    this.soundPlayer = null;
    if (player !== null) {
      player.release().catch((error: BusinessError) => {
        console.debug(`SystemFeedback: player release returned ${error.code}`);
      });
    }
    const path = this.soundPath;
    this.soundPath = '';
    if (path.length > 0) {
      try {
        this.context?.resourceManager.closeRawFdSync(path);
      } catch (error) {
        // Already closed, or closed by the platform: nothing to do about it.
      }
    }
  }

  private cancel(): void {
    this.stopSound();
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

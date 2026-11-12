"""Synthesises the slot machine sounds for the questionnaire onboarding.

    python3 tool/make_onb_sounds.py                 # writes assets/sounds/
    python3 tool/make_onb_sounds.py --preview x.wav # plus the whole sequence

Pure Python (no numpy) and seeded, so the output is the same on every run.
Everything is synthesised: there is no sample library or licence behind it.

The files and when OnbSounds plays them:
  lever_pull.wav   on the pull: a few ratchet clicks, a clunk as the knob
                   bottoms out
  reels_spin.wav   seamless loop while the reels roll, waiting on the code
  reels_land.wav   when the code arrives: the reels slow down and each one
                   stops with a "thock", rising in pitch
  code_reveal.wav  when the last tile settles: a chime, then the reveal —
                   each tile flipping out and locking in, the saucer's
                   loop, the sheen

Timings mirror lib/features/onboarding_v2/widgets/onb_slot_machine.dart —
regenerate after changing the lever or reel timings there:
  lever    the knob eases down over 225 ms (_fireLever: 900 ms x 0.25)
  rolling  22 symbols/s per reel (_rollSpeed)
  landing  reel i runs for 1300 + 150 i ms (_spinMs, _staggerMs):
           easeOutCubic to an overshoot at 88 %, snapping back by 100 %
and lib/features/onboarding_v2/widgets/onb_code_reveal.dart for the reveal
(the REVEAL_* constants below).
"""
import math
import random
import struct
import sys
import wave
from pathlib import Path

SR = 44100

# Phones play audio ~20-50 ms after it is asked for; land hits a bit early.
LATENCY = 0.018

KNOB_DOWN = 0.225
ROLL_SPEED = 22.0
REELS = 6
SPIN_S, STAGGER_S = 1.3, 0.15
RUN_END, OVERSHOOT = 0.88, 0.32

# When OnbSounds starts the loop after a pull: just after the clunk, so the
# two don't pile up. It swells in over SPIN_FADE_IN.
SPIN_DELAY = 0.26
SPIN_FADE_IN = [(0.0, 0.4), (0.04, 0.7), (0.08, 1.0)]
# How long the loop and the landing track overlap at the hand-off.
HANDOFF = 0.04
SPIN_LOOP_S = 2.0  # a whole number of ticks per reel: 44 at 22/s

# The reveal's timeline (onb_code_reveal.dart), seconds from landing.
REVEAL_TILE_LAUNCH, REVEAL_TILE_STAGGER, REVEAL_TILE_FLIGHT = 0.06, 0.055, 0.62
REVEAL_UFO_LOOP = (0.12, 1.32)
REVEAL_SHEEN = (1.0, 1.45)

# C major pentatonic, rising reel by reel, resolving on the chime's C.
STOP_NOTES = [392.0, 440.0, 523.25, 587.33, 659.25, 783.99]
CHIME_NOTES = [1046.5, 1318.5, 1568.0, 2093.0]
# The tiles lock in up the same scale, an octave above the reel stops.
LOCK_NOTES = [n * 2 for n in STOP_NOTES]


# ---------------------------------------------------------------------------
# Building blocks
# ---------------------------------------------------------------------------

def frames(sec):
    return int(round(sec * SR))


def mix(buf, at, samples, gain=1.0, wrap=False):
    i0 = frames(at)
    n = len(buf)
    for k, s in enumerate(samples):
        j = i0 + k
        if wrap:
            buf[j % n] += s * gain
        elif 0 <= j < n:
            buf[j] += s * gain


class Biquad:
    """RBJ cookbook filter: 'lp', 'hp' or 'bp' (0 dB peak)."""

    def __init__(self, kind, f0, q=0.707):
        w = 2 * math.pi * f0 / SR
        cw, alpha = math.cos(w), math.sin(w) / (2 * q)
        if kind == 'lp':
            b = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]
        elif kind == 'hp':
            b = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]
        else:
            b = [alpha, 0.0, -alpha]
        a0 = 1 + alpha
        self.b = [x / a0 for x in b]
        self.a = [-2 * cw / a0, (1 - alpha) / a0]
        self.x1 = self.x2 = self.y1 = self.y2 = 0.0

    def __call__(self, x):
        y = (self.b[0] * x + self.b[1] * self.x1 + self.b[2] * self.x2
             - self.a[0] * self.y1 - self.a[1] * self.y2)
        self.x2, self.x1, self.y2, self.y1 = self.x1, x, self.y1, y
        return y

    def run(self, xs):
        return [self(x) for x in xs]


def tone(freq, tau, length, amp=1.0, attack=0.0008, glide=None, phase=0.0):
    """A decaying sine. glide=(start ratio, time constant) slides the pitch
    down onto freq."""
    out, ph = [], phase
    for n in range(frames(length)):
        t = n / SR
        f = freq
        if glide:
            f *= 1 + (glide[0] - 1) * math.exp(-t / glide[1])
        ph += 2 * math.pi * f / SR
        env = min(1.0, t / attack) * math.exp(-t / tau)
        out.append(amp * env * math.sin(ph))
    return out


def noise_hit(rng, tau, length, amp, band=None, q=1.0, attack=0.0003):
    """A burst of noise, optionally band-passed around `band` Hz."""
    bp = Biquad('bp', band, q) if band else None
    out = []
    for n in range(frames(length)):
        t = n / SR
        x = rng.uniform(-1, 1)
        if bp:
            x = bp(x) * 2.2  # make up for the narrow band
        out.append(amp * min(1.0, t / attack) * math.exp(-t / tau) * x)
    return out


def layered(*parts):
    n = max(len(p) for p in parts)
    return [sum(p[i] for p in parts if i < len(p)) for i in range(n)]


def reverb(x, wet_ratio, feedback=0.74, damp=0.35, circular=False):
    """A small, dark room (Freeverb-style combs + all-passes), mixed in at
    `wet_ratio` of the dry signal's loudness. `circular` settles it over a
    loop so the tail wraps cleanly onto the start."""
    combs = [[[0.0] * d, 0, 0.0] for d in (1116, 1188, 1277, 1356)]
    alls = [[[0.0] * d, 0] for d in (556, 441)]

    def step(s):
        acc = 0.0
        for c in combs:
            buf, i, store = c
            y = buf[i]
            store = y * (1 - damp) + store * damp
            buf[i] = s * 0.25 + store * feedback
            c[1], c[2] = (i + 1) % len(buf), store
            acc += y
        for a in alls:
            buf, i = a
            y = buf[i]
            buf[i] = acc + y * 0.5
            a[1] = (i + 1) % len(buf)
            acc = y - acc
        return acc

    if circular:
        for s in x:
            step(s)
    wet = [step(s) for s in x]
    dry_rms = rms(x)
    wet_rms = rms(wet) or 1.0
    g = wet_ratio * dry_rms / wet_rms
    return [d + g * w for d, w in zip(x, wet)]


def rms(x):
    return math.sqrt(sum(s * s for s in x) / max(1, len(x)))


def peak(x):
    return max(abs(s) for s in x)


def master(x, target_db, gains=None, circular=False):
    """Rolls off rumble no phone speaker can play, brings the peak to 0 dB,
    soft-limits the top of it and sets the final level. Pass another
    track's `gains` to match its level exactly. Returns (signal, gains)."""
    hp = Biquad('hp', 70)
    if circular:
        hp.run(x)
    x = hp.run(x)
    pre = gains[0] if gains else 1 / peak(x)
    out = []
    for s in x:
        s *= pre
        a = abs(s)
        if a > 0.7:
            s = math.copysign(0.7 + 0.3 * math.tanh((a - 0.7) / 0.3), s)
        out.append(s)
    post = gains[1] if gains else 10 ** (target_db / 20) / peak(out)
    return [s * post for s in out], (pre, post)


def fade_tail(x, sec):
    n = frames(sec)
    for k in range(n):
        x[len(x) - 1 - k] *= (k / n) ** 2


def write(path, x):
    pcm = b''.join(struct.pack('<h', int(max(-1.0, min(1.0, s)) * 32767))
                   for s in x)
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm)


def cubic_bezier(x1, y1, x2, y2):
    """Flutter's Cubic(x1, y1, x2, y2) curve as a function of t."""
    def at(a, b, m):
        return 3 * a * (1 - m) ** 2 * m + 3 * b * (1 - m) * m * m + m ** 3

    def curve(t):
        lo, hi = 0.0, 1.0
        for _ in range(40):
            m = (lo + hi) / 2
            if at(x1, x2, m) < t:
                lo = m
            else:
                hi = m
        return at(y1, y2, (lo + hi) / 2)
    return curve


ease_in = cubic_bezier(0.42, 0.0, 1.0, 1.0)


def ease_out_cubic(u):
    return 1 - (1 - u) ** 3


def ease_in_out_cubic(u):
    return 4 * u ** 3 if u < 0.5 else 1 - (-2 * u + 2) ** 3 / 2


# ---------------------------------------------------------------------------
# Sounds
# ---------------------------------------------------------------------------

def ratchet_click(rng, amp):
    return layered(
        noise_hit(rng, 0.0011, 0.015, amp * 0.8, band=3000, q=1.2),
        tone(2600 * rng.uniform(0.97, 1.03), 0.004, 0.025, amp * 0.35,
             phase=rng.random() * 6.28),
    )


def reel_tick(rng, center, amp):
    """One symbol passing: a soft, short plastic tick."""
    c = center * rng.uniform(0.95, 1.05)
    a = amp * rng.uniform(0.85, 1.1)
    return layered(
        noise_hit(rng, 0.0014, 0.012, a, band=c, q=1.8),
        tone(c * 0.81, 0.0028, 0.012, a * 0.4, phase=rng.random() * 6.28),
    )


def reel_thock(rng, note, amp):
    """A reel dropping into place: a weighty knock with a tuned top."""
    return layered(
        tone(230, 0.035, 0.25, amp * 0.85, glide=(1.7, 0.01)),
        tone(note, 0.075, 0.45, amp * 0.5),
        tone(note * 2.0, 0.03, 0.2, amp * 0.12),
        tone(note * 3.98, 0.014, 0.08, amp * 0.16),
        noise_hit(rng, 0.003, 0.03, amp * 0.45, band=1500, q=0.9),
        noise_hit(rng, 0.0009, 0.01, amp * 0.25, band=3400, q=1.5),
    )


def whir(rng, length, circular=False):
    """The faint air-and-bearing hum under rolling reels."""
    n = frames(length)
    raw = [rng.uniform(-1, 1) for _ in range(n)]
    lo, hi = Biquad('bp', 380, 0.6), Biquad('bp', 2300, 0.9)
    if circular:
        for s in raw:  # settle the filters over the loop first
            lo(s), hi(s)
    return [lo(s) * 0.9 + hi(s) * 0.35 for s in raw]


def lever_pull(rng):
    """Kept short and dry: the reels' rattle comes in right after the
    clunk, so anything ringing on would play over it."""
    x = [0.0] * frames(0.45)
    # Ratchet: a click each quarter of the knob's travel, so they bunch up
    # as it speeds up.
    for k in range(1, 4):
        u = k / 4
        lo, hi = 0.0, 1.0
        for _ in range(40):
            m = (lo + hi) / 2
            lo, hi = (m, hi) if ease_in(m) < u else (lo, m)
        mix(x, lo * KNOB_DOWN - LATENCY, ratchet_click(rng, 0.2 + 0.05 * k))
    # Clunk: the arm hits its stop.
    mix(x, KNOB_DOWN - LATENCY, layered(
        tone(120, 0.045, 0.3, 0.85, glide=(1.8, 0.012)),
        tone(400, 0.025, 0.15, 0.4),
        noise_hit(rng, 0.004, 0.04, 0.35, band=1400, q=0.8),
    ))
    x = reverb(x, 0.06)
    fade_tail(x, 0.12)
    return x


REEL_TICK_HZ = [1900, 2150, 2400, 2050, 2300, 2600]
TICK_AMP = 0.34
WHIR_AMP = 0.15


def reels_spin(rng):
    """Every reel at full speed. Built circularly: ticks and the room's tail
    wrap from the end onto the start, so the loop has no seam."""
    x = [0.0] * frames(SPIN_LOOP_S)
    per_loop = int(round(ROLL_SPEED * SPIN_LOOP_S))
    for i in range(REELS):
        phase = rng.random()
        for k in range(per_loop):
            at = (k + phase) / ROLL_SPEED
            mix(x, at, reel_tick(rng, REEL_TICK_HZ[i], TICK_AMP), wrap=True)
    hum = whir(rng, SPIN_LOOP_S, circular=True)
    x = [s + h * WHIR_AMP for s, h in zip(x, hum)]
    return reverb(x, 0.12, circular=True)


def reel_motion(i):
    """Position (symbols) and speed of reel i, t seconds into the landing,
    for the nominal travel the slot machine aims for."""
    dur = SPIN_S + STAGGER_S * i
    run = RUN_END * dur
    travel = ROLL_SPEED * run / 3
    total = travel + OVERSHOOT

    def pos(t):
        if t <= 0:
            return 0.0
        if t < run:
            return total * ease_out_cubic(t / run)
        if t < dur:
            return total - OVERSHOOT * ease_in_out_cubic((t - run) / (dur - run))
        return travel

    def speed(t):
        if t < run:
            return 3 * total * (1 - t / run) ** 2 / run
        return 0.0
    return dur, travel, pos, speed


def reels_land(rng):
    x = [0.0] * frames(SPIN_S + STAGGER_S * (REELS - 1) + 0.6)
    step = 0.0002
    envelope = [0.0] * len(x)
    for i in range(REELS):
        dur, travel, pos, speed = reel_motion(i)
        # Offset so the reel rests exactly on a symbol; a tick each time a
        # symbol boundary passes the window.
        offset = (-travel) % 1.0
        last = math.floor(offset + 0.5)
        t = 0.0
        while t < dur:
            now = math.floor(pos(t) + offset + 0.5)
            if now != last:
                mix(x, t, reel_tick(rng, REEL_TICK_HZ[i], TICK_AMP))
                last = now
            t += step
        for n in range(frames(dur)):
            envelope[n] += min(1.0, speed(n / SR) / ROLL_SPEED) / REELS
        # Thock as it snaps back into place.
        mix(x, 0.93 * dur - LATENCY,
            reel_thock(rng, STOP_NOTES[i], 0.62 + 0.03 * i))
    hum = whir(rng, len(x) / SR)
    x = [s + h * WHIR_AMP * e for s, h, e in zip(x, hum, envelope)]
    x = reverb(x, 0.16)
    fade_tail(x, 0.2)
    return x


def bell(rng, f, amp, length=1.6):
    """A clean glassy bell: a few slightly inharmonic partials and a
    detuned twin for shimmer."""
    parts = [(1.0, 1.05, 1.0), (1.0035, 0.95, 0.35), (2.0, 0.5, 0.3),
             (3.0, 0.26, 0.11), (4.16, 0.15, 0.07), (5.43, 0.08, 0.035)]
    return layered(*[
        tone(f * r, tau, length, amp * a, attack=0.0025,
             phase=rng.random() * 6.28)
        for r, tau, a in parts])


def flip_swish(rng, amp, length=0.11):
    """A tile flicking over: a quick airy swish rising through the band."""
    out = []
    bp = Biquad('bp', 1500, 1.4)
    for n in range(frames(length)):
        u = n / frames(length)
        if n % 32 == 0:  # retune as it rises
            bp = _retuned(bp, 1300 + 2600 * u, 1.4)
        env = math.sin(math.pi * u) ** 1.6
        out.append(amp * env * bp(rng.uniform(-1, 1)) * 2.2)
    return out


def _retuned(old, f0, q):
    new = Biquad('bp', f0, q)
    new.x1, new.x2, new.y1, new.y2 = old.x1, old.x2, old.y1, old.y2
    return new


def lock_plink(rng, note, amp):
    """A tile seating into the row: a short glassy plink with a soft tap."""
    return layered(
        tone(note, 0.06, 0.3, amp, attack=0.0015),
        tone(note * 2.76, 0.02, 0.1, amp * 0.25, attack=0.0015),
        noise_hit(rng, 0.0012, 0.01, amp * 0.3, band=3800, q=1.5),
    )


def ufo_whoosh(rng, start, end, amp):
    """Air around the saucer's loop: louder and brighter on the near side."""
    n = frames(end - start + 0.2)
    lo = Biquad('bp', 700, 0.8)
    out = []
    for k in range(n):
        s = min(1.0, k / frames(end - start))
        theta = -math.pi / 2 + 2 * math.pi * (0.5 - 0.5 * math.cos(math.pi * s))
        near = 0.5 + 0.5 * math.sin(theta)  # 1 in front, 0 behind
        speed = math.sin(math.pi * s)
        fade = 1.0 if k < frames(end - start) else 1 - (k - frames(end - start)) / frames(0.2)
        if k % 64 == 0:
            lo = _retuned(lo, 500 + 1500 * near, 0.8)
        out.append(amp * speed * (0.35 + 0.65 * near) * fade
                   * lo(rng.uniform(-1, 1)) * 2.2)
    return out


def code_reveal(rng):
    x = [0.0] * frames(2.3)
    # The code is found: the chime, with a soft whoomp as the shockwave goes.
    for k, (f, a) in enumerate(zip(CHIME_NOTES, [0.42, 0.36, 0.36, 0.26])):
        mix(x, 0.055 * k, bell(rng, f, a))
    mix(x, 0.0, layered(
        tone(150, 0.12, 0.5, 0.35, attack=0.012, glide=(1.6, 0.05)),
        noise_hit(rng, 0.09, 0.35, 0.16, band=420, q=0.7, attack=0.01),
    ))
    # Each tile flicks over mid-flight, then seats into the row.
    for i in range(6):
        launch = REVEAL_TILE_LAUNCH + REVEAL_TILE_STAGGER * i
        mix(x, launch + REVEAL_TILE_FLIGHT * 0.35 - LATENCY,
            flip_swish(rng, 0.16))
        mix(x, launch + REVEAL_TILE_FLIGHT * 0.86 - LATENCY,
            lock_plink(rng, LOCK_NOTES[i], 0.2 + 0.015 * i))
    # The saucer's loop.
    mix(x, REVEAL_UFO_LOOP[0], ufo_whoosh(rng, *REVEAL_UFO_LOOP, 0.07))
    # The sheen: a little run of glints sweeping across.
    s0, s1 = REVEAL_SHEEN
    for k in range(9):
        at = s0 + (s1 - s0) * k / 8
        mix(x, at, tone(3200 + 450 * k, 0.03, 0.12, 0.05 - 0.003 * k,
                        attack=0.002, phase=rng.random() * 6.28))
    x = reverb(x, 0.28)
    fade_tail(x, 0.35)
    return x


# ---------------------------------------------------------------------------

def main():
    out_dir = Path(__file__).resolve().parent.parent / 'assets' / 'sounds'
    out_dir.mkdir(parents=True, exist_ok=True)
    rng = random.Random(20261104)

    lever, _ = master(lever_pull(rng), -1.0)
    land, gains = master(reels_land(rng), -1.5)
    # Same gains as the landing track, so the hand-off is level.
    spin, _ = master(reels_spin(rng), 0, gains=gains, circular=True)
    reveal, _ = master(code_reveal(rng), -6.0)

    files = {
        'lever_pull.wav': lever,
        'reels_spin.wav': spin,
        'reels_land.wav': land,
        'code_reveal.wav': reveal,
    }
    for name, x in files.items():
        write(out_dir / name, x)
        print(f'{name:16} {len(x) / SR:4.2f} s   peak {20 * math.log10(peak(x)):6.1f} dBFS'
              f'   rms {20 * math.log10(rms(x)):6.1f} dBFS')

    if '--preview' in sys.argv:
        # The usual run: the code is ready, so the reels roll for the craft
        # screen's minimum 700 ms before landing.
        land_at = 0.7
        reveal_at = land_at + SPIN_S + STAGGER_S * (REELS - 1)
        seq = [0.0] * frames(reveal_at + len(reveal) / SR + 0.1)
        mix(seq, 0.0, lever)
        loop_len = land_at + HANDOFF - SPIN_DELAY
        looped = [spin[n % len(spin)]
                  * [v for at, v in SPIN_FADE_IN if at <= n / SR][-1]
                  for n in range(frames(loop_len))]
        mix(seq, SPIN_DELAY, looped)
        mix(seq, land_at, land)
        mix(seq, reveal_at, reveal)
        p = peak(seq)
        if p > 0.98:
            seq = [s * 0.98 / p for s in seq]
        write(sys.argv[sys.argv.index('--preview') + 1], seq)


if __name__ == '__main__':
    main()

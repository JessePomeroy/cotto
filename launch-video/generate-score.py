from pathlib import Path
import json
import math
import re
import subprocess
import wave
import numpy as np

ROOT = Path(__file__).resolve().parent
ASSETS = ROOT / 'assets'
ASSETS.mkdir(parents=True, exist_ok=True)
SR = 48000
DURATION = 56
N = SR * DURATION
mix = np.zeros((N, 2), dtype=np.float64)
rng = np.random.default_rng(8092026)


def hz(midi):
    return 440 * 2 ** ((midi - 69) / 12)


def place(sound, when, level=1.0, pan=0.0):
    start = int(when * SR)
    end = min(N, start + len(sound))
    if end <= start:
        return
    # Constant-power stereo with a little source crossfeed.
    angle = (pan + 1) * np.pi / 4
    gains = np.array([np.cos(angle), np.sin(angle)])
    mix[start:end] += sound[:end-start, None] * gains * level


def pluck(midi, when, amp=0.06, pan=0.0, length=3.6):
    t = np.arange(int(length * SR)) / SR
    f = hz(midi)
    attack = 1 - np.exp(-t / 0.008)
    body = np.sin(2*np.pi*f*t) * np.exp(-t/0.72)
    body += 0.25 * np.sin(2*np.pi*f*2.002*t + 0.22) * np.exp(-t/0.25)
    body += 0.09 * np.sin(2*np.pi*f*3.005*t + 0.45) * np.exp(-t/0.13)
    sound = body * attack
    place(sound, when, amp, pan)
    for delay, gain, side in [(0.19,0.14,-pan),(0.39,0.12,-0.65),(0.61,0.09,0.65),(0.89,0.07,0.0)]:
        place(sound, when+delay, amp*gain, side)


def pad(notes, when, duration, amp=0.018):
    t = np.arange(int((duration+1.5)*SR)) / SR
    env = np.minimum(t/1.3, 1) * np.minimum(np.maximum(duration+1.5-t,0)/2.0,1)
    env = np.sin(np.pi/2*np.clip(env,0,1)) ** 2
    for j, midi in enumerate(notes):
        f=hz(midi)
        slow=0.95+0.05*np.sin(2*np.pi*0.11*t+j)
        sound=(np.sin(2*np.pi*f*t+j*0.2) + 0.22*np.sin(2*np.pi*2*f*t+j*0.2))
        sound += 0.45*np.sin(2*np.pi*f*1.0015*t+j*0.2)
        sound *= env * slow / 1.6
        place(sound,when,amp,(-0.65+1.3*j/max(len(notes)-1,1)))


def bass(midi, when, duration, amp=0.052):
    t=np.arange(int(duration*SR))/SR
    env=(1-np.exp(-t/0.09))*np.minimum(np.maximum(duration-t,0)/0.4,1)
    f=hz(midi)
    body=np.sin(2*np.pi*f*t) + 0.14*np.sin(2*np.pi*2*f*t)
    place(body*env,when,amp,0)


def tap(when, amp=0.0035):
    t=np.arange(int(0.08*SR))/SR
    noise=rng.normal(0,1,len(t))
    # A mellow brushed pulse, never a sharp hi-hat.
    for _ in range(3):
        noise=np.convolve(noise,np.ones(18)/18,mode='same')
    sound=noise*np.exp(-t/0.026)*(1-np.exp(-t/0.003))
    place(sound,when,amp,0.15)

# Gentle harmonic movement follows the visual scene timing.
scenes = [
    (0,5,[50,57,61,64,69],38,[74,78,81,76]),
    (5,14,[45,52,59,61,64],33,[73,76,81,83]),
    (14,21,[47,54,57,62,66],35,[74,78,81,85]),
    (21,29,[43,50,54,59,62],31,[74,78,79,83]),
    (29,36,[42,50,57,61,64],30,[73,76,78,81]),
    (36,43,[40,47,54,55,62],28,[74,78,79,83]),
    (43,50,[45,52,57,59,61],33,[73,76,81,83]),
    (50,56,[50,57,61,64,69],38,[74,78,81,86]),
]
beat=60/84
for idx,(start,end,chord,root,melody) in enumerate(scenes):
    pad(chord,start,end-start,amp=0.019 if idx<7 else 0.016)
    # Bass has a relaxed, breathing two-beat pulse.
    for at in np.arange(start+0.12,end-0.6,beat*2):
        bass(root,at,min(beat*1.62,end-at),0.043)
    # Familiar four-note motif, with space around the final logo.
    steps=[0.55,1.98,3.4,4.82] if idx!=7 else [0.4,1.7,3.0]
    for j,offset in enumerate(steps):
        if start+offset < end-0.7:
            pluck(melody[j%len(melody)],start+offset,0.082 if idx<7 else 0.068,(-0.28,0.24,-0.14,0.2)[j%4])
    if idx in [1,2,3,4,5,6]:
        # A quiet second voice suggests fluid, productive motion.
        for j,at in enumerate(np.arange(start+0.88,end-0.4,beat)):
            pluck(chord[(j*2)%len(chord)]+12,at,0.026,(-0.4,0.4)[j%2],2.7)
        for at in np.arange(start+0.12,end-0.1,beat):
            tap(at,0.012)

# A soft air swell joins scene boundaries without overt impact effects.
for boundary in [5,14,21,29,36,43,50]:
    length=1.5
    t=np.arange(int(length*SR))/SR
    noise=rng.normal(0,1,len(t))
    for _ in range(4):
        noise=np.convolve(noise,np.ones(32)/32,mode='same')
    envelope=np.sin(np.pi*t/length)**2
    place(noise*envelope,boundary-1.1,0.021,-0.12)

# A few long, quiet room reflections soften the dry synthesized sources.
dry=mix.copy()
for seconds,level in [(0.137,0.11),(0.281,0.10),(0.433,0.075),(0.677,0.055),(1.019,0.035)]:
    delay=int(seconds*SR)
    mix[delay:] += dry[:-delay,::-1]*level

# Seamless opening and a musical, unhurried close.
t=np.arange(N)/SR
fade_in=np.sin(np.minimum(t/0.85,1)*np.pi/2)**2
fade_out=np.sin(np.minimum(np.maximum(DURATION-t,0)/3.0,1)*np.pi/2)**2
mix *= (fade_in*fade_out)[:,None]
peak=np.max(np.abs(mix))
mix *= 0.78/max(peak,1e-9)
raw=ASSETS/'score-raw.wav'
with wave.open(str(raw),'wb') as f:
    f.setnchannels(2)
    f.setsampwidth(2)
    f.setframerate(SR)
    f.writeframes((np.clip(mix,-1,1)*32767).astype('<i2').tobytes())

# Loudness normalization leaves room for clean, comfortable playback.
base=['ffmpeg','-hide_banner','-nostats','-i',str(raw)]
measure=subprocess.run(base+['-af','loudnorm=I=-18:TP=-2:LRA=8:print_format=json','-f','null','-'],capture_output=True,text=True,check=True)
stats=json.loads(re.search(r'\{[^{}]+\}',measure.stderr).group())
filter_expr=('loudnorm=I=-18:TP=-2:LRA=8:linear=true:'
             f"measured_I={stats['input_i']}:measured_TP={stats['input_tp']}:"
             f"measured_LRA={stats['input_lra']}:measured_thresh={stats['input_thresh']}:"
             f"offset={stats['target_offset']}")
output=ASSETS/'score.m4a'
subprocess.run(base+['-af',filter_expr+',atrim=start=5,asetpts=PTS-STARTPTS,afade=t=in:d=0.35','-ar',str(SR),'-c:a','aac','-b:a','256k','-y',str(output)],capture_output=True,text=True,check=True)
raw.unlink()
probe=subprocess.run(['ffprobe','-v','error','-show_entries','format=duration,size:stream=codec_name,sample_rate,channels','-of','json',str(output)],capture_output=True,text=True,check=True)
verify=subprocess.run(['ffmpeg','-hide_banner','-nostats','-i',str(output),'-af','loudnorm=I=-18:TP=-2:LRA=8:print_format=json','-f','null','-'],capture_output=True,text=True,check=True)
print(probe.stdout)
print(re.search(r'\{[^{}]+\}',verify.stderr).group())

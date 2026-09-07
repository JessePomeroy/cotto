#!/bin/bash
set -euo pipefail
project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"
app_binary="$project_dir/build/Sotto.app/Contents/MacOS/Sotto"
if [[ ! -x "$app_binary" ]]; then
    printf 'Build the app first: ./scripts/build-app.sh\n' >&2
    exit 1
fi
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/Sotto-smoke.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
say -o "$test_dir/speech.aiff" 'This is a local dictation test. The meeting starts at nine tomorrow morning.'
say -o "$test_dir/list.aiff" "Sorry, I wanted that screenshot. Go ahead. My voice to text was just ruined. Let me go back to where I was with that list. Three, oranges. Four, a trip to the beach. Seven, more syrup. That's the end of the list."

for scenario in speech list
do
    afconvert -f WAVE -d LEI16@16000 -c 1 "$test_dir/$scenario.aiff" "$test_dir/$scenario.wav"
    "$app_binary" --transcribe "$test_dir/$scenario.wav" --json --archive-root "$test_dir/history" > "$test_dir/$scenario.json"
    python3 - "$scenario" "$test_dir/$scenario.json" "$test_dir/$scenario.wav" "$test_dir/history" <<'PY'
from datetime import datetime
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import time
import uuid
import wave

scenario, result_path, source_path, archive_root = sys.argv[1:]
with open(result_path) as handle:
    result = json.load(handle)
text = result.get('text', '').casefold()
if scenario == 'speech':
    assert 'meeting' in text and 'tomorrow' in text, result
else:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    items = [re.fullmatch(r'(\d+)[.)]\s+(.+)', line) for line in lines]
    assert len(items) == 3 and all(items), ('Expected three distinct numbered lines', result)
    assert [int(item.group(1)) for item in items] == [3, 4, 7], ('Spoken numbering was not preserved', result)
    for item, expected in zip(items, ['orange', 'beach', 'syrup']):
        assert expected in item.group(2), ('List content was lost', result)
    assert not any(chatter in text for chatter in ['screenshot', 'voice to text', 'go ahead', 'let me', 'back to', 'list']), ('List directives or resume chatter leaked into output', result)

archive = Path(result['archivePath'])
root = Path(archive_root)
assert archive.is_relative_to(root / 'transcripts'), ('Archive escaped the temporary test directory', result)
assert set(path.name for path in archive.iterdir()) == {
    'metadata.json', 'transcript.txt', 'audio.wav', 'transcription.wav'
}, ('Unexpected archive artifacts', result)
metadata = json.loads((archive / 'metadata.json').read_text())
assert metadata['schemaVersion'] == 1 and metadata['mode'] == 'file'
assert metadata['outcome'] == 'transcribed'
uuid.UUID(metadata['id'])
assert metadata['rawText'].strip(), ('Raw recognition text was not saved', metadata)
assert metadata['transcriptText'] == result['text'] == (archive / 'transcript.txt').read_text()
assert metadata['model']['id'] == 'whisper-large-v3-turbo'
assert metadata['model']['sha256'] == '1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69'
assert metadata['model']['engine'] == 'whisper.cpp' and metadata['model']['engineVersion'] == '1.9.3-dev'
assert metadata['options'] == {
    'requestedLanguage': 'en', 'detectedLanguage': result['language'],
    'removeFillers': True, 'vocabularyPrompt': ''
}
assert metadata['microphone'] == {}, ('File transcription must not pretend to use a microphone', metadata)
started = datetime.fromisoformat(metadata['startedAt'].replace('Z', '+00:00'))
released = datetime.fromisoformat(metadata['releasedAt'].replace('Z', '+00:00'))
completed = datetime.fromisoformat(metadata['completedAt'].replace('Z', '+00:00'))
assert started == released <= completed and started.tzinfo is not None
timing = metadata['timing']
assert timing['engineProcessingSeconds'] == result['transcriptionSeconds']
assert 0 < timing['transcriptionWallSeconds'] <= timing['releaseToResultSeconds']
assert metadata['appVersion'] and metadata['appVersion'] != 'development'
assert metadata['appBuild']

source = Path(source_path).read_bytes()
for filename in ['audio.wav', 'transcription.wav']:
    assert (archive / filename).read_bytes() == source, ('Archived audio differs from supplied WAV', filename)
with wave.open(source_path) as audio:
    expected_format = {
        'sampleRate': audio.getframerate(), 'channels': audio.getnchannels(),
        'frameCount': audio.getnframes(), 'sampleFormat': 'pcm_s16le'
    }
    expected_duration = audio.getnframes() / audio.getframerate()
    assert audio.getsampwidth() == 2
for key, filename in [('original', 'audio.wav'), ('transcription', 'transcription.wav')]:
    assert metadata['audio'][f'{key}Filename'] == filename
    actual = metadata['audio'][key]
    for field, expected in expected_format.items():
        assert actual[field] == expected, ('Incorrect source WAV metadata', field, actual)
    assert math.isclose(actual['durationSeconds'], expected_duration)
for directory in [root, root / 'transcripts', archive.parent, archive]:
    assert stat.S_IMODE(directory.stat().st_mode) == 0o700, ('History directory is not private', directory)
for artifact in archive.iterdir():
    assert stat.S_IMODE(artifact.stat().st_mode) == 0o600, ('History file is not private', artifact)
assert not list((root / 'transcripts').rglob('.pending-*')), 'Archive staging files were left behind'
expected_takes = 1 if scenario == 'speech' else 2
assert len(list((root / 'transcripts').rglob('metadata.json'))) == expected_takes

pid = result.get('enginePID')
assert isinstance(pid, int) and pid > 1, ('Missing helper process identifier', result)
for _ in range(40):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        break
    time.sleep(0.05)
else:
    raise AssertionError(f'{scenario}: engine process survived app shutdown')
print(json.dumps(result, indent=2))
print(f'PASS: {scenario} → packaged app → native engine → formatted transcript + private local archive; engine exited.')
PY
done
printf 'PASS: sentence and resumed-list dictation and temporary archives passed; both helpers exited.\n'

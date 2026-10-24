"""AssemblyAI async transcription, cached by audio hash. Posts the file once; a rerun
with the same audio, model and speaker_labels reads the cache. The reference is Universal-3.5
Pro; ASSEMBLYAI_SPEECH_MODEL=universal reads the Universal-2 references made before 2026-10-17."""
import hashlib, json, os, time
import requests
import store

API = 'https://api.assemblyai.com/v2'
POLL_S = 5
TIMEOUT_S = 3600
MODEL = os.environ.get('ASSEMBLYAI_SPEECH_MODEL', 'universal-3-5-pro')
# Universal-3 models write audio events ("[laughter]") into the text unless asked not to.
STRIPS_AUDIO_TAGS = MODEL.startswith('universal-3')
# Universal-3 decodes with a language model and tidies the text unless prompted: no fillers, repeats or
# false starts. The models under test write what was said, so the reference is asked for verbatim.
# ASSEMBLYAI_PROMPT='' reads the unprompted references.
VERBATIM_PROMPT = ('Transcribe verbatim, exactly as spoken. Keep filler words such as um and uh, '
                   'repeated words, false starts and self-corrections. Do not tidy or rephrase.')
PROMPT = os.environ.get('ASSEMBLYAI_PROMPT', VERBATIM_PROMPT) if STRIPS_AUDIO_TAGS else ''

def cache_path(audio_path, speaker_labels):
    prompted = f"-p{hashlib.sha1(PROMPT.encode()).hexdigest()[:8]}" if PROMPT else ''
    return store.sub('aai') / f"{store.audio_sha(audio_path)}-{MODEL}{prompted}-{int(speaker_labels)}.json"

def transcribe(audio_path, speaker_labels):
    cached = cache_path(audio_path, speaker_labels)
    hit = store.read_json(cached)
    if hit:
        return hit
    key = os.environ.get('ASSEMBLYAI_API_KEY')
    if not key:
        raise SystemExit('ASSEMBLYAI_API_KEY is not set; build needs it to call AssemblyAI')
    headers = {'authorization': key}
    with open(audio_path, 'rb') as f:
        up = requests.post(f'{API}/upload', headers=headers, data=f, timeout=600)
    up.raise_for_status()
    body = {'audio_url': up.json()['upload_url'], 'speech_models': [MODEL],
            'speaker_labels': speaker_labels, 'language_code': 'en'}
    if STRIPS_AUDIO_TAGS:
        body['remove_audio_tags'] = 'all'
    if PROMPT:
        body['prompt'] = PROMPT
    job = requests.post(f'{API}/transcript', headers=headers, json=body, timeout=60)
    if job.status_code != 200:
        raise SystemExit(f'AssemblyAI HTTP {job.status_code}: {job.text[:300]}')
    job_id = job.json()['id']
    deadline = time.monotonic() + TIMEOUT_S
    while time.monotonic() < deadline:
        poll = requests.get(f'{API}/transcript/{job_id}', headers=headers, timeout=60)
        poll.raise_for_status()
        result = poll.json()
        if result['status'] == 'completed':
            # AssemblyAI can fall back to Universal-2 without an error; a reference from another
            # model must not be cached under this one's name.
            used = result.get('speech_model_used')
            if MODEL != 'universal' and used != MODEL:
                raise SystemExit(f'AssemblyAI transcribed with {used}, not {MODEL}')
            store.write_json(cached, result)
            return result
        if result['status'] == 'error':
            raise SystemExit(f"AssemblyAI failed: {result.get('error')}")
        time.sleep(POLL_S)
    raise SystemExit('AssemblyAI timed out')

def words(result):
    """[{text, startMs, endMs, speaker}] from a completed response."""
    return [{'text': w['text'], 'startMs': w['start'], 'endMs': w['end'], 'speaker': w.get('speaker') or 'A'}
            for w in result.get('words') or []]

"""Where things live. Nothing here is inside the repo: audio links, AssemblyAI JSON,
system outputs, review spans and decisions all sit under the reference directory."""
import hashlib, json, os, pathlib

def data_dir():
    return pathlib.Path(os.environ.get('TYPEMEIT_SUPPORT_DIR') or pathlib.Path.home() / 'Library/Application Support/TypeMeIt')

def root():
    path = pathlib.Path(os.environ.get('ASR_EVAL_DIR') or data_dir() / 'asr-reference')
    path.mkdir(parents=True, exist_ok=True)
    return path

def sub(name):
    path = root() / name
    path.mkdir(parents=True, exist_ok=True)
    return path

def read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default

def write_json(path, value):
    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
    tmp = str(path) + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(value, f)
    os.replace(tmp, path)

def read_jsonl(path):
    try:
        with open(path) as f:
            return [json.loads(line) for line in f if line.strip()]
    except FileNotFoundError:
        return []

def clips():
    return read_json(root() / 'clips.json', [])

def audio_sha(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()[:24]

def clip_audio(clip):
    return str(root() / 'audio' / clip['file'])

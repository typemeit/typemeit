"""Encrypted backup of the truths given by ear and the audio they were judged on, kept in the repo so the
listening work survives a lost Mac or a changed reference. One file, AES-256-GCM over a tar.gz of
truths.jsonl and one Opus snippet per truth. The key is 32 random bytes, base64, in ASR_EVAL_VAULT_KEY;
it lives in 1Password ("type me it eval vault key", Personal) and never in the repo.

A save merges with the vault already in the repo: a truth or snippet the vault holds and this Mac lacks
(its recording deleted, say) is kept."""
import base64, io, json, os, pathlib, secrets, subprocess, tarfile, tempfile
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

VAULT_PATH = pathlib.Path(__file__).resolve().parent / 'vault' / 'truths.tmv'
MAGIC = b'TMI-ASR-VAULT-1\n'
NONCE_BYTES = 12
KEY_ENV = 'ASR_EVAL_VAULT_KEY'
SNIPPET_CONTEXT_MS = 2000
SNIPPET_BITRATE = '24k'

def key():
    encoded = os.environ.get(KEY_ENV)
    if not encoded:
        raise SystemExit(f'{KEY_ENV} is not set; read it from 1Password ("type me it eval vault key")')
    raw = base64.b64decode(encoded)
    if len(raw) != 32:
        raise SystemExit(f'{KEY_ENV} must be 32 bytes, base64')
    return raw

def seal(plain, secret):
    nonce = secrets.token_bytes(NONCE_BYTES)
    return MAGIC + nonce + AESGCM(secret).encrypt(nonce, plain, MAGIC)

def open_sealed(sealed, secret):
    if not sealed.startswith(MAGIC):
        raise SystemExit(f'{VAULT_PATH} is not a vault file')
    body = sealed[len(MAGIC):]
    return AESGCM(secret).decrypt(body[:NONCE_BYTES], body[NONCE_BYTES:], MAGIC)

def unpack(secret):
    """(truths by id, snippet bytes by truth id) from the vault in the repo; empty when there is none."""
    if not VAULT_PATH.exists():
        return {}, {}
    archive = tarfile.open(fileobj=io.BytesIO(open_sealed(VAULT_PATH.read_bytes(), secret)), mode='r:gz')
    truths, snippets = {}, {}
    for member in archive.getmembers():
        content = archive.extractfile(member).read() if member.isfile() else None
        if member.name == 'truths.jsonl':
            truths = {t['id']: t for t in map(json.loads, content.decode().splitlines()) if t}
        elif member.name.startswith('snippets/') and content is not None:
            snippets[pathlib.Path(member.name).stem] = content
    return truths, snippets

def cut_snippet(truth, audio_path):
    begin_s = max(0, truth['startMs'] - SNIPPET_CONTEXT_MS) / 1000
    length_s = (truth['endMs'] - truth['startMs'] + 2 * SNIPPET_CONTEXT_MS) / 1000
    with tempfile.TemporaryDirectory() as tmp:
        target = os.path.join(tmp, 'snippet.opus')
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', f'{begin_s:.2f}', '-t', f'{length_s:.2f}', '-i', audio_path,
                        '-ac', '1', '-ar', '16000', '-c:a', 'libopus', '-b:a', SNIPPET_BITRATE, target], check=True)
        return pathlib.Path(target).read_bytes()

def save(local_truths, clip_files):
    secret = key()
    truths, snippets = unpack(secret)
    truths.update({t['id']: t for t in local_truths})
    cut = 0
    for truth_id, truth in truths.items():
        audio = clip_files.get(truth['clip'])
        if truth_id not in snippets and audio and os.path.exists(audio):
            snippets[truth_id] = cut_snippet(truth, audio)
            cut += 1
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
        for name, content in [('truths.jsonl', ''.join(json.dumps(t) + '\n' for t in truths.values()).encode())] + \
                             [(f'snippets/{truth_id}.opus', data) for truth_id, data in sorted(snippets.items())]:
            info = tarfile.TarInfo(name)
            info.size = len(content)
            archive.addfile(info, io.BytesIO(content))
    VAULT_PATH.parent.mkdir(parents=True, exist_ok=True)
    VAULT_PATH.write_bytes(seal(buffer.getvalue(), secret))
    print(f"vault: {len(truths)} truths, {len(snippets)} snippets ({cut} new), {VAULT_PATH.stat().st_size / 1e6:.1f} MB at {VAULT_PATH}")

def load(truths_path, snippet_dir):
    truths, snippets = unpack(key())
    known = {json.loads(line)['id'] for line in pathlib.Path(truths_path).read_text().splitlines() if line.strip()} if pathlib.Path(truths_path).exists() else set()
    missing = [t for truth_id, t in truths.items() if truth_id not in known]
    with open(truths_path, 'a') as f:
        f.writelines(json.dumps(t) + '\n' for t in missing)
    pathlib.Path(snippet_dir).mkdir(parents=True, exist_ok=True)
    for truth_id, data in snippets.items():
        (pathlib.Path(snippet_dir) / f'{truth_id}.opus').write_bytes(data)
    print(f"vault: {len(missing)} truths added, {len(snippets)} snippets in {snippet_dir}")

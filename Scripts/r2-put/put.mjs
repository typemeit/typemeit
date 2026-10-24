// Puts one file in the typemeit-releases R2 bucket as a multipart upload, so
// it has no size cap: `wrangler r2 object put` refuses files over 300 MiB,
// and the speech model is 697 MiB.
//
//   node Scripts/r2-put/put.mjs <key> <file> <content-type> <cache-control>
import { open, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { getPlatformProxy } from "wrangler";

// R2 wants every part but the last the same size, and at least 5 MiB. Each
// part is one request through the remote binding, which caps request bodies
// at 100 MB.
const PART_BYTES = 64 * 1024 * 1024;
const PART_ATTEMPTS = 3;

async function uploadPart(upload, number, buffer) {
  for (let attempt = 1; ; attempt++) {
    try {
      return await upload.uploadPart(number, buffer);
    } catch (error) {
      if (attempt === PART_ATTEMPTS) throw error;
      console.log(`part ${number} failed (${error.message}); retrying`);
    }
  }
}

const [key, file, contentType, cacheControl] = process.argv.slice(2);
if (!key || !file || !contentType || !cacheControl) {
  console.error("usage: put.mjs <key> <file> <content-type> <cache-control>");
  process.exit(1);
}

const { size } = await stat(file);
const { env, dispose } = await getPlatformProxy({
  configPath: fileURLToPath(new URL("wrangler.toml", import.meta.url)),
});
const upload = await env.RELEASES.createMultipartUpload(key, { httpMetadata: { contentType, cacheControl } });
const handle = await open(file);
try {
  const parts = [];
  for (let offset = 0, number = 1; offset < size; offset += PART_BYTES, number++) {
    const buffer = Buffer.alloc(Math.min(PART_BYTES, size - offset));
    await handle.read(buffer, 0, buffer.length, offset);
    parts.push(await uploadPart(upload, number, buffer));
    console.log(`${key}: ${Math.min(offset + buffer.length, size)} of ${size} bytes`);
  }
  const object = await upload.complete(parts);
  if (object.size !== size) throw new Error(`${key} landed as ${object.size} bytes, not ${size}`);
  console.log(`${key}: done, etag ${object.httpEtag}`);
} catch (error) {
  await upload.abort();
  throw error;
} finally {
  await handle.close();
  await dispose();
}

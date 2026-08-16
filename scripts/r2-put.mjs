// Uploads one file to Cloudflare R2 (via the S3 API) at an exact key, refusing to overwrite.
//
// WHY R2 RATHER THAN VERCEL BLOB
// This replaces blob-put.mjs. R2 charges nothing for egress, and serving an installer is almost
// entirely egress: every download of a ~30 MB file is bandwidth. On Vercel Blob that came out of
// a metered Pro allowance; on R2 it is free, and the storage sits inside R2's standing free tier.
// The public URL is served from the bucket's custom domain (dl.keepthediff.com), which is a
// direct, non-redirecting, permanent link, exactly what Partner Center requires.
//
// THE ONE OPTION THAT IS NOT A DEFAULT, AND WHY
//   no overwrite: publishing the same commit sha twice FAILS rather than silently replacing a
//                 package that may already be submitted. Partner Center caches what it fetched,
//                 so the same URL quietly meaning something different later is the failure mode
//                 worth refusing outright. Matches blob-put's allowOverwrite:false.
//
// The URL is NOT printed here. It is deterministic (custom domain + key), so the caller composes
// it from the same key rather than parsing it back out of an upload log.
//
// Usage: node r2-put.mjs <file> <key>

import { readFileSync } from "node:fs";
import { S3Client, PutObjectCommand, HeadObjectCommand } from "@aws-sdk/client-s3";

const [file, key] = process.argv.slice(2);
if (!file || !key) {
  console.error("usage: node r2-put.mjs <file> <key>");
  process.exit(1);
}

const { R2_ACCOUNT_ID, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY } = process.env;
for (const [name, value] of Object.entries({ R2_ACCOUNT_ID, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY })) {
  if (!value) {
    console.error(`${name} is not set, so there is nothing to authenticate or upload with.`);
    process.exit(1);
  }
}

const s3 = new S3Client({
  region: "auto",
  endpoint: `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  credentials: { accessKeyId: R2_ACCESS_KEY_ID, secretAccessKey: R2_SECRET_ACCESS_KEY },
});

// Immutability. A HEAD that succeeds means this sha was already published, and re-publishing it
// would replace bytes a Partner Center submission may already point at.
try {
  await s3.send(new HeadObjectCommand({ Bucket: R2_BUCKET, Key: key }));
  console.error(`refusing to overwrite: an object already exists at ${key}`);
  process.exit(2);
} catch (error) {
  const status = error?.$metadata?.httpStatusCode;
  if (status !== 404 && error?.name !== "NotFound") {
    console.error(`could not check for an existing object: ${error?.name || error}`);
    process.exit(1);
  }
}

const body = readFileSync(file);
await s3.send(new PutObjectCommand({
  Bucket: R2_BUCKET,
  Key: key,
  Body: body,
  ContentType: "application/octet-stream",
}));

console.log(`uploaded ${body.length} bytes to ${key}`);

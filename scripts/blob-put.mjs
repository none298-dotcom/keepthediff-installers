// Uploads one file to Vercel Blob at an exact pathname, and prints the URL.
//
// WHY NOT THE VERCEL CLI
// `vercel blob put` is the obvious way and it does not work here. CLI 58 answers
// "No existing credentials found. Please run `vercel login` or pass --token" even with
// BLOB_READ_WRITE_TOKEN in the environment, and even when the blob token is passed as
// --rw-token: it wants an account login for the CLI itself, which is a human-shaped credential
// this workflow deliberately does not have. The SDK wants only the blob token, which is the one
// credential that actually describes what is being done.
//
// That surfaced on the first publish that mattered, with a signed installer already built and
// verified, which is the worst possible moment to discover the last step needs a login.
//
// THE TWO OPTIONS THAT ARE NOT DEFAULTS, AND WHY
//   addRandomSuffix: false   the URL has to be predictable, because it is written down and pasted
//                            into Partner Center.
//   allowOverwrite: false    publishing the same sha twice FAILS rather than silently replacing a
//                            package that may already be submitted. Partner Center caches what it
//                            fetched, so the same URL quietly meaning something different later is
//                            the failure mode worth refusing outright.
//
// Usage: node blob-put.mjs <file> <pathname>

import { readFileSync } from "node:fs";
import { put } from "@vercel/blob";

const [file, pathname] = process.argv.slice(2);
if (!file || !pathname) {
  console.error("usage: node blob-put.mjs <file> <pathname>");
  process.exit(1);
}

const token = process.env.BLOB_READ_WRITE_TOKEN;
if (!token) {
  console.error("BLOB_READ_WRITE_TOKEN is not set, so there is nothing to authenticate with.");
  process.exit(1);
}

const body = readFileSync(file);
const blob = await put(pathname, body, {
  access: "public",
  token,
  addRandomSuffix: false,
  allowOverwrite: false,
  contentType: "application/octet-stream",
});

console.log(`uploaded ${body.length} bytes`);
console.log(`url=${blob.url}`);

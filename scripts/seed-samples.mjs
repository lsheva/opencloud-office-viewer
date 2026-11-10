#!/usr/bin/env node
// Uploads the fixtures in ./samples into an OpenCloud instance over WebDAV so
// they show up in Files and can be opened with the office-viewer app.
//
// Mounting the folder into the OpenCloud container is *not* enough: files only
// become space resources after they pass through the storage/WebDAV layer.
//
//   node scripts/seed-samples.mjs                     # against the dev stack
//   OC_URL=https://cloud.example node scripts/seed-samples.mjs
//
// Environment:
//   OC_URL            default https://localhost:9200
//   OC_USER           default admin
//   OC_PASSWORD       default admin
//   OC_SPACE_ID       default: resolved from the Graph API (see below)
//   OC_FOLDER         default office-viewer-samples
//   SAMPLES_DIR       default <repo>/samples
//   NODE_TLS_REJECT_UNAUTHORIZED=0   for the self-signed dev certificate

import { readdir, readFile, stat } from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const base = (process.env.OC_URL || "https://localhost:9200").replace(
  /\/+$/,
  "",
);
const user = process.env.OC_USER || "admin";
const password = process.env.OC_PASSWORD || "admin";
const folder = process.env.OC_FOLDER || "office-viewer-samples";
const samplesDir =
  process.env.SAMPLES_DIR ||
  resolve(fileURLToPath(new URL(".", import.meta.url)), "..", "samples");

const CONTENT_TYPES = {
  doc: "application/msword",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xls: "application/vnd.ms-excel",
  xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ppt: "application/vnd.ms-powerpoint",
  pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  odt: "application/vnd.oasis.opendocument.text",
  ods: "application/vnd.oasis.opendocument.spreadsheet",
  odp: "application/vnd.oasis.opendocument.presentation",
};

const authorization =
  "Basic " + Buffer.from(`${user}:${password}`).toString("base64");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const extensionOf = (name) => name.split(".").pop()?.toLowerCase() ?? "";
const humanSize = (bytes) =>
  bytes < 1024 ? `${bytes} B` : `${(bytes / 1024).toFixed(1)} kB`;

const davUrl = (spaceId, relativePath = "") =>
  `${base}/dav/spaces/${spaceId.replace(/\$/g, "%24")}` +
  (relativePath
    ? "/" + relativePath.split("/").map(encodeURIComponent).join("/")
    : "/");

const davRequest = (spaceId, relativePath, init = {}) =>
  fetch(davUrl(spaceId, relativePath), {
    ...init,
    headers: { authorization, ...(init.headers ?? {}) },
  });

// Personal spaces are named "<storage-provider-id>$<space-id>" — the space part
// is a random UUID, so it cannot be derived from the user name. Ask Graph.
async function resolveSpaceId() {
  if (process.env.OC_SPACE_ID) return process.env.OC_SPACE_ID;

  const res = await fetch(`${base}/graph/v1.0/me/drives`, {
    headers: { authorization },
  });
  if (!res.ok)
    throw new Error(
      `graph/v1.0/me/drives returned HTTP ${res.status}: ${await res.text()}`,
    );

  const { value = [] } = await res.json();
  const personal = value.filter((drive) => drive.driveType === "personal");
  const drive =
    personal.find((candidate) => candidate.driveAlias === `personal/${user}`) ??
    personal[0];
  if (!drive?.id) throw new Error(`no personal drive found for ${user}`);
  return drive.id;
}

async function waitForServer(timeoutMs = 300_000) {
  const deadline = Date.now() + timeoutMs;
  let last = "no response";
  let unauthorized = 0;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${base}/graph/v1.0/me/drives`, {
        headers: { authorization },
      });
      if (res.ok) return;
      if (res.status === 401 && ++unauthorized >= 3) {
        throw new Error(
          "authentication failed — check OC_USER/OC_PASSWORD and PROXY_ENABLE_BASIC_AUTH",
        );
      }
      last = `HTTP ${res.status}`;
    } catch (err) {
      if (err.message.startsWith("authentication failed")) throw err;
      last = err.message;
    }
    await sleep(3_000);
  }
  throw new Error(`server not reachable after ${timeoutMs / 1000}s (${last})`);
}

async function ensureFolder(spaceId) {
  const res = await davRequest(spaceId, `${folder}/`, { method: "MKCOL" });
  if (res.status === 201) return console.log(`  folder created: ${folder}`);
  // OpenCloud answers 405 when the collection already exists.
  if (res.status === 405 || res.status === 409)
    return console.log(`  folder exists:  ${folder}`);
  throw new Error(
    `MKCOL ${folder} failed with HTTP ${res.status}: ${await res.text()}`,
  );
}

async function main() {
  const names = (await readdir(samplesDir)).filter(
    (name) => extensionOf(name) in CONTENT_TYPES,
  );
  if (!names.length)
    throw new Error(`no sample documents found in ${samplesDir}`);

  console.log(`→ ${base} as ${user}`);
  await waitForServer();

  const spaceId = await resolveSpaceId();
  console.log(`  space: ${spaceId}`);
  await ensureFolder(spaceId);

  const failures = [];
  for (const name of names.sort()) {
    const file = join(samplesDir, name);
    const { size } = await stat(file);
    const res = await fetch(davUrl(spaceId, `${folder}/${name}`), {
      method: "PUT",
      headers: {
        authorization,
        "content-type": CONTENT_TYPES[extensionOf(name)],
      },
      body: await readFile(file),
    });
    if (res.ok) {
      console.log(`  ✓ ${name} (${humanSize(size)})`);
    } else {
      failures.push(name);
      console.log(`  ✗ ${name} — HTTP ${res.status} ${await res.text()}`);
    }
  }

  console.log(
    `\n${names.length - failures.length}/${names.length} uploaded to "${folder}".`,
  );
  if (failures.length) process.exitCode = 1;
}

main().catch((err) => {
  console.error(`\nseed failed: ${err.message}`);
  process.exitCode = 1;
});

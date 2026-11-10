# Sample documents

One real file per supported extension, used to check that `office-viewer` renders
each format. Nothing here is generated — all files are unmodified fixtures from
Apache-licensed projects, so a failure means the viewer broke, not the fixture.

| File          | Format                    | What it exercises                         | Expected in the app                    |
| ------------- | ------------------------- | ----------------------------------------- | -------------------------------------- |
| `sample.docx` | Word 2007+                | headings, body text, lists                | rendered by `DocxScrollViewer`         |
| `sample.xlsx` | Excel 2007+               | multiple sheets, formulas, number formats | rendered by `XlsxViewer`               |
| `sample.pptx` | PowerPoint 2007+          | slides with text and images               | rendered by `PptxScrollViewer`         |
| `sample.doc`  | Word 97-2003              | legacy CFB, text + metadata               | rendered via `legacyDoc`               |
| `sample.xls`  | Excel 97-2003             | legacy CFB, formulas                      | rendered via `legacyXls`               |
| `sample.ppt`  | PowerPoint 97-2003        | legacy CFB, slides + images               | rendered via `legacyPpt`               |
| `sample.odt`  | OpenDocument Text         | ODF text                                  | **fallback message** — no ODF renderer |
| `sample.ods`  | OpenDocument Spreadsheet  | ODF sheet                                 | **fallback message** — no ODF renderer |
| `sample.odp`  | OpenDocument Presentation | ODF slides                                | **fallback message** — no ODF renderer |

The three ODF files are deliberate: those extensions are registered, so the app must
degrade to its "download instead" state instead of throwing a parse error.

## Provenance

Both sources are Apache License 2.0; files are copied verbatim.

| File          | Source                                                                     |
| ------------- | -------------------------------------------------------------------------- |
| `sample.docx` | `apache/poi` → `test-data/document/SampleDoc.docx`                         |
| `sample.doc`  | `apache/poi` → `test-data/document/SampleDoc.doc`                          |
| `sample.xlsx` | `apache/poi` → `test-data/spreadsheet/SampleSS.xlsx`                       |
| `sample.xls`  | `apache/poi` → `test-data/spreadsheet/SampleSS.xls`                        |
| `sample.pptx` | `apache/poi` → `test-data/slideshow/SampleShow.pptx`                       |
| `sample.ppt`  | `apache/poi` → `test-data/slideshow/SampleShow.ppt`                        |
| `sample.odt`  | `tdf/odftoolkit` → `odfdom/src/main/resources/OdfTextDocument.odt`         |
| `sample.ods`  | `tdf/odftoolkit` → `odfdom/src/main/resources/OdfSpreadsheetDocument.ods`  |
| `sample.odp`  | `tdf/odftoolkit` → `odfdom/src/main/resources/OdfPresentationDocument.odp` |

Originals were fetched from `https://raw.githubusercontent.com/apache/poi/trunk/…` and
`https://raw.githubusercontent.com/tdf/odftoolkit/master/…`.

```
717585c0a88f20862c86220163dd03da87cd743970354c6b29add32725f2e833  sample.doc
ea2c517bd7be4628887eb97f630334b93b894f4522d2c0adae263e602d76df92  sample.docx
53c9bd7337aa79fedf29cef8d81ec47fff39f80e25da9d74bc354cfdf1c43b73  sample.xls
44f1b6ef310c370d4902ee3452e6174da25a67bdb09f47850d51b3287cb3db71  sample.xlsx
64275a6685b8f267827178037dcc59de927475e56385725916f4c6039c7ce7f6  sample.ppt
bfb4b2f07c9233afd2f32aa5781d849d0c7d225bf03721a10becf487b481d828  sample.pptx
9e2cf4332458d2d3670be9343e9d0ff1c9c98fcad785d34bec0e0e3c9fb6b4a5  sample.odt
693e9ab162c1d6ff88e02011d5e1898e85c1a9be79fff213a9db3f2822923c83  sample.ods
1efb69139d406b7568864f4647fd80821507b370da5f395ad33d1624a59aed20  sample.odp
```

## Getting them into an instance

`docker-compose.yml` runs a one-shot `seed` service that uploads this folder into
the admin's personal space (`office-viewer-samples`). After `docker compose up` the files
are in **Files → Personal**. Re-run with:

```bash
docker compose run --rm seed
```

Against any other instance, from the repo root:

```bash
NODE_TLS_REJECT_UNAUTHORIZED=0 node scripts/seed-samples.mjs
# OC_URL=https://cloud.example OC_USER=admin OC_PASSWORD=… to point elsewhere
```

### Why an upload and not a bind mount?

Docker can mount anything; the constraint is OpenCloud's storage contract. Mounting the
folder into the _web assets_ path works (that is how `./dist` is mounted) because those are
plain files. Space content is different: OpenCloud 9 uses the **PosixFS** driver, which
keeps per-file metadata in **extended attributes** and only picks up out-of-band changes
through _assimilation_ — at startup in the default (non-collaborative) mode, or live when
`STORAGE_USERS_POSIX_WATCH_FS=true`. A read-only mount cannot store those attributes, so a
`:ro` bind mount into `storage/users` breaks assimilation. Uploading over WebDAV lets the
server write metadata itself, works while it is running, and is idempotent.

For a bare-metal instance the equivalent manual route is to copy the files into the
admin's space directory while OpenCloud is stopped (writable, owned by the OpenCloud
user), then start the service so the new files are assimilated.

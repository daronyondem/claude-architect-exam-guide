# Repository Instructions

## Project Shape

- `exam-preparation-guide.md` is the source of truth for the guide content.
- `scripts/build-release-assets.sh` builds the PDF and EPUB from the Markdown source.
- `publishing/` contains booklet metadata, styles, cover art, and Pandoc support files.
- `dist/` contains generated release artifacts and is intentionally ignored by Git.

## Editing Guidance

- Keep content changes focused on `exam-preparation-guide.md` unless the publishing pipeline or repository documentation also needs to change.
- Do not commit generated files under `dist/`.
- Run `git diff --check` before committing Markdown changes.
- If validating release assets locally, run:

```bash
./scripts/build-release-assets.sh
```

Pandoc is required. PDF generation also requires `xelatex`. If only EPUB validation is needed on a machine without TeX, use:

```bash
SKIP_PDF_ON_MISSING_ENGINE=1 ./scripts/build-release-assets.sh
```

## Pushing a New Release

The GitHub Actions release workflow does not increment the version number. The release version is the Git tag that triggers the workflow.

Use this process for a versioned release:

1. Make sure the intended changes are merged into `main`.
2. Start from an up-to-date and clean `main` branch:

```bash
git switch main
git pull --ff-only origin main
git status --short --branch
```

3. Inspect existing release tags and choose the next semantic version manually:

```bash
git tag --sort=-v:refname | head
```

For example, if the latest tag is `v1.0.0`, choose `v1.0.1` for a patch release, `v1.1.0` for a minor release, or `v2.0.0` for a major release.

4. Create and push an annotated tag:

```bash
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin vX.Y.Z
```

5. The `.github/workflows/release.yml` workflow runs on pushed tags matching `v*`. It builds `dist/claude-architect-exam-guide.pdf` and `dist/claude-architect-exam-guide.epub`, then creates or updates the GitHub Release for that tag.

6. Verify the workflow and release:

```bash
gh run list --workflow release.yml --limit 5
gh release view vX.Y.Z
```

Do not use the manual `workflow_dispatch` run for an official release. It builds workflow artifacts, but it does not create a GitHub Release, and the generated booklet version may be `dev` unless a release version is supplied explicitly.

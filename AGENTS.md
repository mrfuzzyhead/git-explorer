# Project agent instructions

## Deploying GitExplorer to Applications

When the user asks to deploy or install GitExplorer in `/Applications`, always
build a signed copy. Do not deploy an app produced with
`CODE_SIGNING_ALLOWED=NO`; an unsigned or ad-hoc-signed rebuild has an unstable
code identity and causes macOS Files & Folders permissions to be requested
again.

Build the deployable app with the project's configured Apple Development team:

```bash
xcodebuild \
  -project GitExplorer.xcodeproj \
  -scheme GitExplorer \
  -configuration Release \
  -derivedDataPath .build/SignedDerivedData \
  -destination 'platform=macOS' \
  build
```

Before copying it, verify the signature:

```bash
codesign --verify --deep --strict --verbose=2 \
  .build/SignedDerivedData/Build/Products/Release/GitExplorer.app
codesign -dv --verbose=4 \
  .build/SignedDerivedData/Build/Products/Release/GitExplorer.app
```

The deployed app must retain the bundle/signing identity
`net.fuzzyhead.git` with Team Identifier `VD7DMST4GD`. Replace only
`/Applications/GitExplorer.app`, request any required filesystem approval,
then verify the installed copy's signature and launch that installed copy.

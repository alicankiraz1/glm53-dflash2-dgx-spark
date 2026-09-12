# Third-Party Notices

This repository does not distribute model weights or prebuilt container
images. It is designed to carry an SGLang-derived source patch and to reproduce
a runtime image from pinned upstream inputs. Users must obtain all undistributed
third-party artifacts from their upstream sources and review the terms that
apply to their use.

## SGLang source and runtime image

- Project: SGLang
- Copyright: 2023-2024 SGLang Team
- License: Apache License 2.0
- Source: <https://github.com/sgl-project/sglang>

The TileLang patch carried by this repository is derived from SGLang source and
remains subject to SGLang's Apache License 2.0 terms and attribution
requirements. The package uses an SGLang base container image as a build input,
but the image itself is not committed or distributed by this repository.

SGLang's license covers SGLang; it does not relicense operating-system
packages, accelerator libraries, Python packages, or other components that may
be assembled into the upstream image. The container image contents are not
exhaustively licensed by this notice. The pinned image's own notices,
manifests, and component licenses remain authoritative for those contents.

## Target model

- Repository: `LibertAIDAI/GLM-5.3-Flash-NVFP4`
- License: MIT License

The target model is a separately licensed work. Its license does not change
the Apache License 2.0 terms for this repository's original code.

## Draft model

- Repository: `incoai/GLM-5.3-Flash-DFlash2`
- License: Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International

The draft model is a separately licensed, non-commercial/research-evaluation
only dependency. This project does not redistribute or modify its weights.
Users are responsible for reviewing and complying with the upstream terms.

## Contributor Covenant

`CODE_OF_CONDUCT.md` is adapted from the Contributor Covenant, version 2.1,
which is distributed under the Creative Commons Attribution 4.0 International
Public License.

This notice is informational and is not legal advice.

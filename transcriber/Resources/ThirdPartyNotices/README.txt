Transcriber third-party software and model sources

Runtime: whisper.cpp 1.9.4 (MIT), ggml 0.25.3 (MIT),
FluidAudio 04e363c29d9a754022d602d6fe1468ab80a0f705 (Apache-2.0).
Apple frameworks and Swift system runtime are supplied by macOS.
ONNX Runtime 1.28.2 (MIT) is linked for forced alignment.
Legacy sherpa inference libraries are not linked; their retained notices
apply only to earlier releases. See Alignment-NOTICE.txt for alignment model details.

Model weights download separately. models.json and community-1.lock.json pin
source revisions, files and SHA-256 checksums.
Whisper: https://huggingface.co/ggerganov/whisper.cpp (MIT).
Silero: https://github.com/snakers4/silero-vad (MIT).
Community-1 Core ML conversion: https://huggingface.co/FluidInference/speaker-diarization-coreml
Revision df2625ac79a7ac6b65ad868fee6d80f320da4232.
Only Segmentation, FBank, Embedding, PldaRho and plda-parameters assets are used.
Their scoped CC-BY-4.0 license, attribution and conversion provenance are in
Community-1/. The conversion changes numeric precision; official PyTorch
benchmark results are not measurements of this application.

# Verb · models and runtimes

## MLX speech models

Verb downloads the speech model you choose from Hugging Face, at a pinned revision. A build can also carry the weights inside the app, unchanged.

- **Parakeet TDT 0.6B v3**, by NVIDIA, converted to MLX by the MLX community. Source: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 ; conversion: https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3 at revision `ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15`. Licensed CC BY 4.0: https://creativecommons.org/licenses/by/4.0/ . The MLX conversion is an upstream modification; Verb uses those weights unchanged and casts them to bfloat16 in memory. Attribution does not imply endorsement.
- **Qwen3-ASR 0.6B**, by the Qwen team, MLX 4-bit conversion by the MLX community. Original: https://huggingface.co/Qwen/Qwen3-ASR-0.6B ; conversion: https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-4bit at revision `313d850181767edf09f00a9c289becca70e58cd0`. Apache 2.0. Verb uses the upstream quantized weights unchanged; MLX Audio Swift generates a compatible tokenizer JSON from the supplied vocabulary assets.

## Runtime

[MLX Audio Swift](https://github.com/Blaizzy/mlx-audio-swift), MIT, revision `01dec7c9bdce3088a6b6b7ab9f2e403458195efb`, and [MLX Swift](https://github.com/ml-explore/mlx-swift), MIT, with what they build in: MLX and MLX C (MIT), metal-cpp (Apache 2.0), PocketFFT (BSD 3-Clause), nlohmann/json (MIT), {fmt} (MIT) and SmartTurn (BSD 2-Clause). Each notice is in this folder, beside the notices of the Swift packages Verb links. Exact dependency revisions are in Package.resolved; model file manifests and checksums are in SpeechCatalog.swift.

## Optional writing model

The local writing model is downloaded separately: Qwen3-4B-Instruct-2507 (Apache 2.0), https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507 , served by the user's installed Ollama, https://github.com/ollama/ollama . Default registry tag: `qwen3:4b-instruct-2507-q4_K_M`.

SQLite and Apple frameworks are supplied by macOS.

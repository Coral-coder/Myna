"""The models offered in the server's window. Any other GGUF model can be
named by hand. Sizes are the download; a model needs about that much memory,
on the graphics card (12 GB), in ordinary memory for the processor, or split
across both."""

from __future__ import annotations

# Transcribers that aren't Whisper, run by sherpa-onnx on the processor (they
# are small and far faster than real time there). The same models the phone
# offers. key -> (family, Hugging Face repo, files in the order the family
# needs them, longest stretch of audio per pass in seconds)
SHERPA = {
    "parakeet-v2": ("nemo_transducer", "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8",
                    ("encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"), 24),
    "parakeet-v3": ("nemo_transducer", "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
                    ("encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"), 24),
    "parakeet-ultra": ("nemo_transducer", "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-ultra-int8",
                       ("encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"), 24),
    "canary": ("canary", "csukuangfj/sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8",
               ("encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt"), 24),
    "moonshine-base": ("moonshine", "csukuangfj/sherpa-onnx-moonshine-base-en-int8",
                       ("preprocess.onnx", "encode.int8.onnx", "uncached_decode.int8.onnx", "cached_decode.int8.onnx", "tokens.txt"), 12),
    "moonshine-tiny": ("moonshine", "csukuangfj/sherpa-onnx-moonshine-tiny-en-int8",
                       ("preprocess.onnx", "encode.int8.onnx", "uncached_decode.int8.onnx", "cached_decode.int8.onnx", "tokens.txt"), 12),
    "sensevoice": ("sense_voice", "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
                   ("model.int8.onnx", "tokens.txt"), 24),
    "zipformer": ("transducer", "csukuangfj/sherpa-onnx-zipformer-en-libriheavy-20230830-medium-punct-case",
                  ("encoder-epoch-50-avg-15.int8.onnx", "decoder-epoch-50-avg-15.int8.onnx",
                   "joiner-epoch-50-avg-15.int8.onnx", "tokens.txt"), 24),
}

# (id, name shown, note). Ids starting "sherpa:" are the models above; the
# rest are Whisper sizes for faster-whisper.
SPEECH = (
    ("sherpa:parakeet-v2", "Parakeet TDT 0.6b v2", "NVIDIA, English. What Omi runs on device. Very accurate and very fast; processor."),
    ("sherpa:parakeet-v3", "Parakeet TDT 0.6b v3", "NVIDIA, 25 languages. What Omi's servers run. Processor."),
    ("sherpa:parakeet-ultra", "Parakeet TDT 0.6b ultra", "A newer post-training of v3. Processor."),
    ("sherpa:canary", "Canary 180m flash", "NVIDIA. English, Spanish, German, French. Processor."),
    ("sherpa:moonshine-base", "Moonshine base", "Small English model built for speed. Processor."),
    ("sherpa:moonshine-tiny", "Moonshine tiny", "The smallest. Processor."),
    ("sherpa:sensevoice", "SenseVoice small", "Alibaba. Very fast; English, Chinese, Japanese, Korean. Processor."),
    ("sherpa:zipformer", "Zipformer (Libriheavy)", "Next-gen Kaldi, with punctuation and case. Tiny. Processor."),
    ("turbo", "Whisper large-v3 turbo", "Best balance: near the largest model's accuracy, several times faster."),
    ("large-v3", "Whisper large-v3", "Most accurate, slowest. About 3 GB of graphics memory."),
    ("large-v2", "Whisper large-v2", "The previous large model; some find it steadier on noisy audio."),
    ("distil-large-v3", "Distil-Whisper large-v3", "English only. Very fast, close to large-v3."),
    ("distil-medium.en", "Distil-Whisper medium (English)", "Small and fast; fine on the processor."),
    ("medium.en", "Whisper medium (English)", "Older mid-size model."),
    ("small.en", "Whisper small (English)", "Light and quick; comfortable on the processor."),
    ("base.en", "Whisper base (English)", "Very light; real-time on the processor."),
    ("tiny.en", "Whisper tiny (English)", "Smallest; for a quick check only."),
)

# (Hugging Face repo, file, name shown, size in GB, note)
WRITING = (
    ("unsloth/Qwen3.6-35B-A3B-MTP-GGUF", "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf", "Qwen 3.6 35B (A3B, MTP)", 22.9,
     "Recommended. Big and fast: only 3B of it works on each word, and it drafts ahead with its own MTP head. "
     "Shared: what every word uses on the card, the experts in memory."),
    ("google/gemma-4-12B-it-qat-q4_0-gguf", "gemma-4-12b-it-qat-q4_0.gguf", "Gemma 4 12B", 7.0, "Default. Fits the graphics card with Whisper beside it."),
    ("bartowski/google_gemma-3-12b-it-GGUF", "google_gemma-3-12b-it-Q4_K_M.gguf", "Gemma 3 12B", 7.3, "Fits the graphics card."),
    ("bartowski/google_gemma-3-4b-it-GGUF", "google_gemma-3-4b-it-Q4_K_M.gguf", "Gemma 3 4B", 2.5, "Small; quick anywhere, including the processor."),
    ("bartowski/gemma-2-9b-it-GGUF", "gemma-2-9b-it-Q4_K_M.gguf", "Gemma 2 9B", 5.8, "Fits the graphics card."),
    ("bartowski/Qwen_Qwen3-14B-GGUF", "Qwen_Qwen3-14B-Q4_K_M.gguf", "Qwen 3 14B", 9.0, "Strong; just fits the graphics card."),
    ("bartowski/Qwen_Qwen3-8B-GGUF", "Qwen_Qwen3-8B-Q4_K_M.gguf", "Qwen 3 8B", 5.0, "Fast on the graphics card."),
    ("bartowski/Qwen_Qwen3-4B-GGUF", "Qwen_Qwen3-4B-Q4_K_M.gguf", "Qwen 3 4B", 2.5, "Small; quick anywhere."),
    ("bartowski/Qwen_Qwen3-1.7B-GGUF", "Qwen_Qwen3-1.7B-Q4_K_M.gguf", "Qwen 3 1.7B", 1.3, "Tiny; instant on the processor."),
    ("bartowski/Qwen2.5-14B-Instruct-GGUF", "Qwen2.5-14B-Instruct-Q4_K_M.gguf", "Qwen 2.5 14B", 9.0, "Just fits the graphics card."),
    ("bartowski/Qwen2.5-7B-Instruct-GGUF", "Qwen2.5-7B-Instruct-Q4_K_M.gguf", "Qwen 2.5 7B", 4.7, "Fits the graphics card."),
    ("bartowski/Mistral-Nemo-Instruct-2407-GGUF", "Mistral-Nemo-Instruct-2407-Q4_K_M.gguf", "Mistral Nemo 12B", 7.5, "Fits the graphics card."),
    ("bartowski/Mistral-7B-Instruct-v0.3-GGUF", "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf", "Mistral 7B", 4.4, "Fits the graphics card."),
    ("bartowski/phi-4-GGUF", "phi-4-Q4_K_M.gguf", "Phi-4 14B", 9.1, "Just fits the graphics card."),
    ("bartowski/microsoft_Phi-4-mini-instruct-GGUF", "microsoft_Phi-4-mini-instruct-Q4_K_M.gguf", "Phi-4 mini", 2.5, "Small; quick anywhere."),
    ("bartowski/Meta-Llama-3.1-8B-Instruct-GGUF", "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf", "Llama 3.1 8B", 4.9, "Fits the graphics card."),
    ("bartowski/Llama-3.2-3B-Instruct-GGUF", "Llama-3.2-3B-Instruct-Q4_K_M.gguf", "Llama 3.2 3B", 2.0, "Small; quick anywhere."),
    ("bartowski/ibm-granite_granite-3.3-8b-instruct-GGUF", "ibm-granite_granite-3.3-8b-instruct-Q4_K_M.gguf", "Granite 3.3 8B", 4.9, "Fits the graphics card."),
    ("bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF", "DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf", "DeepSeek R1 distill 14B", 9.0, "Reasons before answering; slower."),
    ("bartowski/openai_gpt-oss-20b-GGUF", "openai_gpt-oss-20b-Q4_K_M.gguf", "GPT-OSS 20B", 11.7, "Bigger than the card: run shared or on the processor."),
    ("bartowski/mistralai_Mistral-Small-3.2-24B-Instruct-2506-GGUF", "mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf", "Mistral Small 3.2 24B", 14.3, "Bigger than the card: run shared or on the processor."),
    ("bartowski/google_gemma-3-27b-it-GGUF", "google_gemma-3-27b-it-Q4_K_M.gguf", "Gemma 3 27B", 16.5, "Bigger than the card: run shared or on the processor."),
    ("bartowski/Qwen_Qwen3-30B-A3B-GGUF", "Qwen_Qwen3-30B-A3B-Q4_K_M.gguf", "Qwen 3 30B (A3B)", 18.6, "Large but light to run: a good one for the processor."),
    ("bartowski/Qwen_Qwen3-32B-GGUF", "Qwen_Qwen3-32B-Q4_K_M.gguf", "Qwen 3 32B", 19.8, "Bigger than the card: run shared or on the processor."),
    ("bartowski/Qwen2.5-32B-Instruct-GGUF", "Qwen2.5-32B-Instruct-Q4_K_M.gguf", "Qwen 2.5 32B", 19.9, "Bigger than the card: run shared or on the processor."),
    ("bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF", "DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf", "DeepSeek R1 distill 32B", 19.9, "Reasons before answering; shared or processor."),
    ("bartowski/Llama-3.3-70B-Instruct-GGUF", "Llama-3.3-70B-Instruct-Q4_K_M.gguf", "Llama 3.3 70B", 42.5, "The largest here. Your 128 GB of memory holds it; slow but thorough."),
)

# Where a model runs.
LLM_DEVICES = (
    ("gpu", "Graphics card", "Fastest. The whole model must fit in the card's 12 GB."),
    ("shared", "Shared", "As much as fits on the graphics card, the rest on the processor. For models bigger than the card."),
    ("cpu", "Processor", "Leaves the graphics card alone. Any size that fits in memory; slower."),
)
STT_DEVICES = (
    ("auto", "Graphics card", "Fastest."),
    ("cpu", "Processor", "Leaves the graphics card free for a bigger writing model."),
)

# Largest download that still fits the 12 GB card beside Whisper.
FITS_CARD_GB = 10.5

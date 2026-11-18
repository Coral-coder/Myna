"""The models offered in the server's window. Any other GGUF model can be
named by hand. Sizes are the download; a model needs about that much memory,
on the graphics card (12 GB), in ordinary memory for the processor, or split
across both."""

from __future__ import annotations

# (id for faster-whisper, name shown, note)
SPEECH = (
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

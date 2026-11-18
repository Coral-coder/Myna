"""The models offered in the server's window. Any other GGUF model can be
named by hand; these are ones that fit a 12 GB graphics card."""

from __future__ import annotations

# (id for faster-whisper, name shown, note)
SPEECH = (
    ("turbo", "Whisper large-v3 turbo", "Best balance: near the largest model's accuracy, several times faster."),
    ("large-v3", "Whisper large-v3", "Most accurate, slowest. About 3 GB of graphics memory."),
    ("distil-large-v3", "Distil-Whisper large-v3", "English only. Very fast, close to large-v3."),
    ("medium.en", "Whisper medium (English)", "Older mid-size model."),
    ("small.en", "Whisper small (English)", "Light and quick; misses more."),
    ("base.en", "Whisper base (English)", "Very light; for a quick check only."),
)

# (Hugging Face repo, file, name shown, note)
WRITING = (
    ("google/gemma-4-12B-it-qat-q4_0-gguf", "gemma-4-12b-it-qat-q4_0.gguf", "Gemma 4 12B", "Default. About 7 GB; leaves room for Whisper beside it."),
    ("bartowski/google_gemma-3-12b-it-GGUF", "google_gemma-3-12b-it-Q4_K_M.gguf", "Gemma 3 12B", "About 7.3 GB."),
    ("bartowski/Qwen_Qwen3-14B-GGUF", "Qwen_Qwen3-14B-Q4_K_M.gguf", "Qwen 3 14B", "About 9 GB. Strongest here; tight beside the larger Whisper models."),
    ("bartowski/Qwen_Qwen3-8B-GGUF", "Qwen_Qwen3-8B-Q4_K_M.gguf", "Qwen 3 8B", "About 5 GB. Fast."),
    ("bartowski/Qwen_Qwen3-4B-GGUF", "Qwen_Qwen3-4B-Q4_K_M.gguf", "Qwen 3 4B", "About 2.5 GB. Fastest."),
    ("bartowski/Mistral-Nemo-Instruct-2407-GGUF", "Mistral-Nemo-Instruct-2407-Q4_K_M.gguf", "Mistral Nemo 12B", "About 7.5 GB."),
    ("bartowski/phi-4-GGUF", "phi-4-Q4_K_M.gguf", "Phi-4 14B", "About 9 GB."),
    ("bartowski/Meta-Llama-3.1-8B-Instruct-GGUF", "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf", "Llama 3.1 8B", "About 5 GB."),
)

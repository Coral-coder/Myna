"""Taking out what speech recognizers make up.

Given quiet, noise or the end of a clip, recognizers trained on video
subtitles produce stock lines ("I'm going to go to the next video", "Thank
you very much", "Bye-bye") and get stuck repeating a word ("I Am, I Am, I
Am..."). Real speech is left alone: a line is only dropped when it is
nothing but one of these stock lines."""

from __future__ import annotations

import re

# Never real in a day of conversation: dropped wherever they appear in a line.
_ANYWHERE = (
    "thanks for watching", "thank you for watching", "next video", "subscribe to", "please subscribe",
    "like and subscribe", "subtitles by", "subtitled by", "transcribed by", "captions by", "amara org",
    "see you in the next", "www ", " com slash",
)
# Dropped when they are the whole line.
_WHOLE_LINE = {
    "", "you", "the", "a", "i", "so", "and", "oh", "uh", "um", "ah", "hmm", "mm", "mhm", "huh", "ahem", "grr",
    "thank you", "thank you very much", "thank you so much", "thanks", "thanks a lot", "thank you thank you",
    "bye", "bye bye", "goodbye", "good bye", "see you next time", "ill see you next time",
    "and ill see you next time", "see you later", "see you", "the end", "publisher", "beep", "bump",
    "im going to go to the next stage", "and the rest of the day", "music", "applause", "laughter", "silence",
}


def bare(text: str) -> str:
    """Lower case, letters only, single spaces ("Bye-bye!" → "bye bye")."""
    return " ".join(re.sub(r"[^a-z' ]+", " ", text.lower()).replace("'", "").split())


def collapse_repeats(text: str) -> str:
    """One copy of a word or phrase the recognizer got stuck repeating.

    A single word repeated four times or more ("no no no" is real speech), a
    two- or three-word phrase three times or more, or a longer phrase twice or
    more in a row, is kept once; so is a sentence that nearly repeats one
    just before it in the same line."""
    tokens = text.split()
    if len(tokens) < 3:
        return text
    keys = [bare(token) for token in tokens]
    out: list[int] = []  # indexes of kept tokens
    i = 0
    while i < len(tokens):
        collapsed = False
        for size in range(1, min(8, (len(tokens) - i) // 2) + 1):
            phrase = keys[i:i + size]
            if not any(phrase):
                continue
            count = 1
            while keys[i + count * size:i + (count + 1) * size] == phrase:
                count += 1
            if count >= (4 if size == 1 else 3 if size <= 3 else 2):
                out.extend(range(i, i + size))
                i += count * size
                collapsed = True
                break
        if not collapsed:
            out.append(i)
            i += 1
    kept = " ".join(tokens[j] for j in out)
    kept = kept.rstrip(",;") if kept != text else text
    sentences = re.split(r"(?<=[.!?])\s+", kept)
    if len(sentences) > 1:
        unique: list[str] = []
        for sentence in sentences:
            if len(bare(sentence).split()) >= 4 and any(similar(sentence, earlier) >= 0.85 for earlier in unique):
                continue
            unique.append(sentence)
        kept = " ".join(unique)
    return kept


def is_made_up(text: str) -> bool:
    plain = bare(text)
    if plain in _WHOLE_LINE or (len(set(plain.split())) == 1 and plain.split()[0] in _WHOLE_LINE):
        return True
    padded = f" {plain} "
    return any(f" {phrase.strip()} " in padded if phrase.endswith(" ") or phrase.startswith(" ") else phrase in plain
               for phrase in _ANYWHERE)


def clean(text: str) -> str:
    """The text with stuck repeats collapsed, or "" when it is all made up."""
    text = collapse_repeats((text or "").strip())
    return "" if is_made_up(text) else text


def similar(a: str, b: str) -> float:
    """How much of the shorter line's words the other line has (0..1)."""
    first, second = bare(a).split(), bare(b).split()
    if not first or not second:
        return 0.0
    shorter, longer = sorted((first, second), key=len)
    pool = list(longer)
    hits = 0
    for word in shorter:
        if word in pool:
            pool.remove(word)
            hits += 1
    return hits / len(shorter)
